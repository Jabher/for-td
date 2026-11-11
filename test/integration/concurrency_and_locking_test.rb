# frozen_string_literal: true

require "test_helper"

class ConcurrencyAndLockingTest < ActiveSupport::TestCase
  test "concurrent outgoing batches from the same sender serialize via FOR NO KEY UPDATE and never overdraft" do
    # Payer starts with $100.00 (10,000 cents).
    # 10 concurrent independent PostgreSQL connections each try to spend $30.00 (3,000 cents).
    # Exactly 3 must commit (spending 9,000 cents total, leaving 1,000 cents); 7 must fail with insufficient_funds.
    payer = create_firm!(name: "Concurrent Sender", opening_balance_cents: 10_000)
    payee = create_firm!(name: "Concurrent Recipient", opening_balance_cents: 0)

    worker_count = 10
    barrier = Queue.new
    ready = Queue.new

    results = Array.new(worker_count)
    threads = worker_count.times.map do |i|
      Thread.new do
        conn = open_independent_runtime_pg_connection
        begin
          ready << true
          barrier.pop

          conn.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
          conn.exec_params(
            "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[$3::int4], ARRAY[$4::text])",
            [ payer.uuid, payee.uuid, 3_000, "Concurrent transfer #{i}" ]
          )
          conn.exec("COMMIT")
          results[i] = :committed
        rescue PG::RaiseException => e
          conn.exec("ROLLBACK") rescue nil
          results[i] = e.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL).to_sym
        ensure
          conn&.close
        end
      end
    end

    worker_count.times { ready.pop }
    worker_count.times { barrier << true }
    threads.each(&:join)

    assert_equal 3, results.count(:committed)
    assert_equal 7, results.count(:insufficient_funds)
    assert_equal 1_000, firm_balance_cents(payer.uuid)
    assert_equal 9_000, firm_balance_cents(payee.uuid)
    assert_equal 3, fetch_all_payments.size
  end

  test "lock-then-balance under READ COMMITTED sees newly committed funds after waiting on sender lock" do
    # Payer starts with $50.00 (5,000 cents).
    # Tx1 (outgoing $40.00) acquires payer's FOR NO KEY UPDATE lock and holds its transaction open.
    # Tx2 (outgoing $40.00) attempts to spend from the same payer -> blocks on payer's FOR NO KEY UPDATE lock.
    # While Tx2 is blocked on the lock, Tx3 (incoming $35.00 from another firm) commits!
    # When Tx1 commits (reducing balance 5,000 + 3,500 - 4,000 = 4,500 cents), Tx2 wakes up,
    # executes the SEPARATE balance SELECT under READ COMMITTED, sees 4,500 cents, and succeeds!
    # (If lock-and-sum had been a single statement or REPEATABLE READ, Tx2 would either fail or use a stale snapshot.)
    payer  = create_firm!(name: "Sender Lock Target", opening_balance_cents: 5_000)
    payee  = create_firm!(name: "Recipient", opening_balance_cents: 0)
    funder = create_firm!(name: "External Funder", opening_balance_cents: 10_000)

    conn1 = open_independent_runtime_pg_connection
    conn2 = open_independent_runtime_pg_connection
    conn3 = open_independent_runtime_pg_connection

    tx2_result = nil
    tx2_thread = nil

    begin
      # 1. Tx1 acquires sender lock on payer and posts $40.00, but has NOT committed yet.
      conn1.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn1.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[4000]::int4[], ARRAY['Tx1 spend']::text[])",
        [ payer.uuid, payee.uuid ]
      )
      conn1_pid = conn1.backend_pid

      # Verify sender lock is held until caller commits
      held_locks = admin_connection.exec_params(
        "SELECT mode FROM pg_locks WHERE pid = $1 AND relation = 'public.firm_descriptions'::regclass AND granted",
        [ conn1_pid ]
      ).map { |r| r["mode"] }
      assert_includes held_locks, "RowShareLock"

      # 2. Tx2 starts in another connection and tries to post $40.00 from payer -> blocks on payer's row lock.
      conn2_pid = conn2.backend_pid
      tx2_thread = Thread.new do
        conn2.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
        conn2.exec_params(
          "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[4000]::int4[], ARRAY['Tx2 spend']::text[])",
          [ payer.uuid, payee.uuid ]
        )
        conn2.exec("COMMIT")
        tx2_result = :committed
      end

      wait_until_backend_waiting_on_lock!(conn2_pid)

      # 3. While Tx1 holds payer's sender lock AND Tx2 is waiting on it, Tx3 sends $35.00 TO payer!
      # Because incoming payments do NOT acquire the recipient's sender lock, Tx3 completes immediately without blocking!
      conn3.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn3.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[3500]::int4[], ARRAY['Incoming top-up']::text[])",
        [ funder.uuid, payer.uuid ]
      )
      conn3.exec("COMMIT")

      # 4. Now commit Tx1. Tx2 unblocks, reads fresh READ COMMITTED balance (5000 + 3500 - 4000 = 4500 >= 4000), and commits!
      conn1.exec("COMMIT")
      tx2_thread.join(5)

      assert_equal :committed, tx2_result
      assert_equal 500, firm_balance_cents(payer.uuid)
      assert_equal 8_000, firm_balance_cents(payee.uuid)
      assert_equal 6_500, firm_balance_cents(funder.uuid)
    ensure
      conn1&.close
      conn2&.close
      conn3&.close
    end
  end

  test "posting to a recipient does NOT acquire the recipient's sender lock (mutual A->B and B->A transfers do not deadlock)" do
    firm_a = create_firm!(name: "Firm A", opening_balance_cents: 10_000)
    firm_b = create_firm!(name: "Firm B", opening_balance_cents: 10_000)

    conn_a = open_independent_runtime_pg_connection
    conn_b = open_independent_runtime_pg_connection

    begin
      # Firm A sends to Firm B and holds transaction open.
      conn_a.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn_a.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[2500]::int4[], ARRAY['A to B']::text[])",
        [ firm_a.uuid, firm_b.uuid ]
      )

      # Simultaneously, Firm B sends to Firm A while conn_a is still uncommitted!
      # If post_bulk_payments locked recipients with FOR NO KEY UPDATE, this would block or deadlock.
      # Because only the sender row is locked with FOR NO KEY UPDATE (and FK check uses FOR KEY SHARE),
      # Firm B's outgoing transfer proceeds and commits without waiting on conn_a!
      conn_b.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn_b.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[4000]::int4[], ARRAY['B to A']::text[])",
        [ firm_b.uuid, firm_a.uuid ]
      )
      conn_b.exec("COMMIT")

      conn_a.exec("COMMIT")

      assert_equal 11_500, firm_balance_cents(firm_a.uuid)
      assert_equal 8_500, firm_balance_cents(firm_b.uuid)
    ensure
      conn_a&.close
      conn_b&.close
    end
  end

  private

    def open_independent_runtime_pg_connection
      cfg = ActiveRecord::Base.connection_db_config.configuration_hash
      PG.connect(
        host: cfg[:host],
        port: cfg[:port],
        dbname: cfg[:database],
        user: cfg[:username],
        password: cfg[:password]
      )
    end

    def wait_until_backend_waiting_on_lock!(backend_pid, timeout_seconds: 5.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      loop do
        row = admin_connection.exec_params(
          "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
          [ backend_pid ]
        ).first
        return true if row && row["wait_event_type"] == "Lock"

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "Backend PID #{backend_pid} did not enter Lock wait state within #{timeout_seconds}s (got #{row.inspect})"
        end
        sleep 0.01
      end
    end
end
