# frozen_string_literal: true

require "test_helper"

class ConcurrencyAndLockingTest < ActiveSupport::TestCase
  test "concurrent outgoing batches from the same sender serialize via FOR NO KEY UPDATE and never overdraft" do
    # $100.00 (10,000 cents) opening balance vs 10 concurrent $30.00 (3,000 cents) debits ->
    # floor(10,000 / 3,000) = 3 commits (9,000 cents spent, 1,000 remaining) and 7 `insufficient_funds`.
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
    # Schedule proving why lock-and-balance MUST be two separate SQL statements under `READ COMMITTED`:
    # 1. Payer opens at 5,000 cents; Tx1 debits 4,000 and holds `FOR NO KEY UPDATE` uncommitted.
    # 2. Tx2 attempts to debit 4,000 and blocks on payer's `FOR NO KEY UPDATE` lock.
    # 3. While Tx2 waits, Tx3 credits +3,500 TO payer and commits without blocking (recipients are not sender-locked).
    # 4. Tx1 commits -> Tx2 unblocks, takes a fresh statement snapshot for `SELECT balance_cents FROM firms`,
    #    observes 5,000 + 3,500 - 4,000 = 4,500 >= 4,000, and commits (leaving 500 cents).
    payer  = create_firm!(name: "Sender Lock Target", opening_balance_cents: 5_000)
    payee  = create_firm!(name: "Recipient", opening_balance_cents: 0)
    funder = create_firm!(name: "External Funder", opening_balance_cents: 10_000)

    conn1 = open_independent_runtime_pg_connection
    conn2 = open_independent_runtime_pg_connection
    conn3 = open_independent_runtime_pg_connection

    tx2_result = nil
    tx2_thread = nil

    begin
      conn1.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn1.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[4000]::int4[], ARRAY['Tx1 spend']::text[])",
        [ payer.uuid, payee.uuid ]
      )
      conn1_pid = conn1.backend_pid

      held_locks = admin_connection.exec_params(
        "SELECT mode FROM pg_locks WHERE pid = $1 AND relation = 'public.firm_descriptions'::regclass AND granted",
        [ conn1_pid ]
      ).map { |r| r["mode"] }
      assert_includes held_locks, "RowShareLock"

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

      conn3.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn3.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[3500]::int4[], ARRAY['Incoming top-up']::text[])",
        [ funder.uuid, payer.uuid ]
      )
      conn3.exec("COMMIT")

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
      conn_a.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      conn_a.exec_params(
        "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[2500]::int4[], ARRAY['A to B']::text[])",
        [ firm_a.uuid, firm_b.uuid ]
      )

      # PostgreSQL FK checks on `payee_firm_id` acquire `FOR KEY SHARE`, which does NOT conflict
      # with `FOR NO KEY UPDATE` on Firm B's sender row; locking recipients would deadlock here.
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
