# frozen_string_literal: true

# Large-scale benchmark & PostgreSQL 18 EXPLAIN (ANALYZE, BUFFERS) investigation.
#
# Run via:
#   DB_ROLE=admin bin/rails runner script/benchmark_and_explain.rb
#
# Uses a dedicated scratch database (`taxdome_ledger_benchmark`) so development/test/production
# databases remain clean. Automatically drops the scratch database unless KEEP_BENCH_DB=1.

require "json"

def measure_seconds
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
end

BENCH_DB = ENV.fetch("BENCH_DB", "taxdome_ledger_benchmark")
FIRM_COUNT = Integer(ENV.fetch("FIRM_COUNT", 10_000))
HISTORICAL_PAYMENT_COUNT = Integer(ENV.fetch("HISTORICAL_PAYMENT_COUNT", 1_000_000))

base_cfg = ActiveRecord::Base.connection_db_config.configuration_hash
admin_user = ENV.fetch("DB_ADMIN_USER", "ledger_admin")
admin_pass = ENV.fetch("DB_ADMIN_PASSWORD", "ledger_admin_secret")
runtime_user = ENV.fetch("DB_RUNTIME_USER", "ledger_runtime")
runtime_pass = ENV.fetch("DB_RUNTIME_PASSWORD", "ledger_runtime_secret")

puts "=== 1. Creating isolated benchmark database: #{BENCH_DB} ==="
maint_conn = PG.connect(
  host: base_cfg[:host],
  port: base_cfg[:port],
  dbname: "postgres",
  user: admin_user,
  password: admin_pass
)
maint_conn.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(BENCH_DB)} WITH (FORCE)")
maint_conn.exec("CREATE DATABASE #{PG::Connection.quote_ident(BENCH_DB)} OWNER #{PG::Connection.quote_ident(admin_user)}")
maint_conn.close

begin
  structure_sql = Rails.root.join("db/structure.sql").read
  admin_conn = PG.connect(
    host: base_cfg[:host],
    port: base_cfg[:port],
    dbname: BENCH_DB,
    user: admin_user,
    password: admin_pass
  )
  admin_conn.exec(structure_sql)

  puts "=== 2. Seeding #{FIRM_COUNT} firms and #{HISTORICAL_PAYMENT_COUNT} historical payments ==="
  seed_time = measure_seconds do
    # Disable user triggers only for bulk synthetic fixture load, then re-enable immediately.
    admin_conn.exec("ALTER TABLE public.payments DISABLE TRIGGER USER")
    admin_conn.exec("ALTER TABLE public.firm_descriptions DISABLE TRIGGER USER")

    admin_conn.exec_params(<<~SQL, [ FIRM_COUNT ])
      INSERT INTO public.firm_descriptions (uuid, name, opening_balance_cents)
      SELECT
        pg_catalog.uuidv7(),
        'Firm #' || g,
        1_000_000_000
      FROM generate_series(1, $1::int) AS g
    SQL

    # Skewed distribution + uniform baseline:
    # Firm #1 ("hot whale firm") has ~25,000 outgoing and ~25,000 incoming historical payments,
    # while the remaining 950,000 payments are distributed across all 10,000 firms.
    admin_conn.exec_params(<<~SQL, [ FIRM_COUNT, HISTORICAL_PAYMENT_COUNT ])
      INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description)
      SELECT
        CASE
          WHEN g <= 25000 THEN 1
          ELSE ((g * 7919::bigint) % ($1::bigint - 1)) + 2
        END AS payer_firm_id,
        CASE
          WHEN g <= 25000 THEN ((g % ($1::bigint - 1)) + 2)
          WHEN g <= 50000 THEN 1
          ELSE (((g * 7919::bigint + 17) % ($1::bigint - 1)) + 2)
        END AS payee_firm_id,
        ((g % 5000) + 100)::int4 AS amount_cents,
        'Historical ledger entry #' || g
      FROM generate_series(1::bigint, $2::bigint) AS g
      WHERE (
        CASE
          WHEN g <= 25000 THEN 1
          ELSE ((g * 7919::bigint) % ($1::bigint - 1)) + 2
        END
      ) <> (
        CASE
          WHEN g <= 25000 THEN ((g % ($1::bigint - 1)) + 2)
          WHEN g <= 50000 THEN 1
          ELSE (((g * 7919::bigint + 17) % ($1::bigint - 1)) + 2)
        END
      )
    SQL

    admin_conn.exec("ALTER TABLE public.firm_descriptions ENABLE TRIGGER USER")
    admin_conn.exec("ALTER TABLE public.payments ENABLE TRIGGER USER")
    admin_conn.exec("VACUUM (ANALYZE) public.firm_descriptions")
    admin_conn.exec("VACUUM (ANALYZE) public.payments")
  end
  printf("Seeded & VACUUM ANALYZED in %.2f s\n\n", seed_time)

  sizes = admin_conn.exec(<<~SQL).first
    SELECT
      pg_size_pretty(pg_relation_size('public.payments')) AS payments_heap,
      pg_size_pretty(pg_indexes_size('public.payments')) AS payments_indexes,
      pg_size_pretty(pg_total_relation_size('public.firm_descriptions')) AS firms_total,
      (SELECT count(*) FROM public.payments) AS payment_rows,
      (SELECT count(*) FROM public.firm_descriptions) AS firm_rows
  SQL
  puts "Dataset footprint: #{sizes.inspect}\n\n"

  firms = admin_conn.exec("SELECT id, uuid FROM public.firm_descriptions ORDER BY id ASC LIMIT 2000").to_a
  hot_firm_id = firms[0]["id"].to_i
  hot_firm_uuid = firms[0]["uuid"]
  normal_firm_id = firms[10]["id"].to_i
  normal_firm_uuid = firms[10]["uuid"]
  payee_pool = firms[500..1500].map { |r| r["uuid"] }

  puts "=== 3. EXPLAIN (ANALYZE, BUFFERS) Investigation ==="

  puts "\n--- 3a. Step 1 inside post_bulk_payments: Sender row lock (FOR NO KEY UPDATE on firm_descriptions) ---"
  admin_conn.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
  plan_lock = admin_conn.exec_params(<<~SQL, [ hot_firm_uuid ]).map { |r| r["QUERY PLAN"] }.join("\n")
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT fd.id
    FROM public.firm_descriptions AS fd
    WHERE fd.uuid = $1::uuid
    FOR NO KEY UPDATE
  SQL
  admin_conn.exec("COMMIT")
  puts plan_lock

  puts "\n--- 3b. Step 2 inside post_bulk_payments: Derived balance read for typical firm (~100 payments) ---"
  admin_conn.exec("PREPARE explain_balance_normal(bigint) AS SELECT f.balance_cents FROM public.firms AS f WHERE f.id = $1")
  # Warm buffer cache once then capture steady-state execution
  admin_conn.exec("EXECUTE explain_balance_normal(#{normal_firm_id})")
  plan_bal_normal = admin_conn.exec("EXPLAIN (ANALYZE, BUFFERS) EXECUTE explain_balance_normal(#{normal_firm_id})").map { |r| r["QUERY PLAN"] }.join("\n")
  puts plan_bal_normal

  puts "\n--- 3c. Step 2 inside post_bulk_payments: Derived balance read for hot whale firm (~50,000 payments) ---"
  admin_conn.exec("EXECUTE explain_balance_hot(#{hot_firm_id})") rescue nil
  admin_conn.exec("PREPARE explain_balance_hot(bigint) AS SELECT f.balance_cents FROM public.firms AS f WHERE f.id = $1")
  admin_conn.exec("EXECUTE explain_balance_hot(#{hot_firm_id})")
  plan_bal_hot = admin_conn.exec("EXPLAIN (ANALYZE, BUFFERS) EXECUTE explain_balance_hot(#{hot_firm_id})").map { |r| r["QUERY PLAN"] }.join("\n")
  puts plan_bal_hot

  puts "\n--- 3d. Full read-only `firms` view scan across all #{FIRM_COUNT} firms and #{HISTORICAL_PAYMENT_COUNT} payments ---"
  plan_full_view = admin_conn.exec(<<~SQL).map { |r| r["QUERY PLAN"] }.join("\n")
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT COUNT(*), SUM(balance_cents) FROM public.firms
  SQL
  puts plan_full_view

  puts "\n--- 3e. Payee validation & batch VALUES lookup plan inside post_bulk_payments (100-item batch) ---"
  sample_payees_100 = payee_pool.first(100)
  sample_amounts_100 = Array.new(100, 125)
  sample_descs_100 = Array.new(100) { |i| "Explain batch item ##{i}" }

  plan_join_100 = admin_conn.exec_params(<<~SQL, [ "{#{sample_payees_100.join(',')}}", "{#{sample_amounts_100.join(',')}}", "{#{sample_descs_100.map { |s| "\"#{s}\"" }.join(',')}}" ]).map { |r| r["QUERY PLAN"] }.join("\n")
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT resolved.payee_id, u.amount_cents, u.description, u.ord
    FROM ROWS FROM (
      pg_catalog.unnest($1::uuid[]),
      pg_catalog.unnest($2::int4[]),
      pg_catalog.unnest($3::text[])
    ) WITH ORDINALITY AS u(payee_uuid, amount_cents, description, ord)
    JOIN (
      SELECT d.payee_uuid, fd.id AS payee_id
      FROM (
        SELECT DISTINCT items.payee_uuid
        FROM pg_catalog.unnest($1::uuid[]) AS items(payee_uuid)
      ) AS d
      JOIN public.firm_descriptions AS fd ON fd.uuid = d.payee_uuid
    ) AS resolved ON resolved.payee_uuid = u.payee_uuid
    ORDER BY u.ord
  SQL
  puts plan_join_100

  puts "\n--- 3f. Full post_bulk_payments(...) execution plan (100-item batch) ---"
  admin_conn.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
  plan_post_fn = admin_conn.exec_params(
    "EXPLAIN (ANALYZE, BUFFERS) SELECT public.post_bulk_payments($1::uuid, $2::uuid[], $3::int4[], $4::text[])",
    [
      normal_firm_uuid,
      "{#{sample_payees_100.join(',')}}",
      "{#{sample_amounts_100.join(',')}}",
      "{#{sample_descs_100.map { |s| "\"#{s}\"" }.join(',')}}"
    ]
  ).map { |r| r["QUERY PLAN"] }.join("\n")
  admin_conn.exec("ROLLBACK")
  puts plan_post_fn

  puts "\n=== 4. End-to-End Ruby BulkPayments::Poster + PayloadParser Latency & Throughput Benchmarks ==="
  ActiveRecord::Base.establish_connection(
    adapter: "postgresql",
    host: base_cfg[:host],
    port: base_cfg[:port],
    database: BENCH_DB,
    username: runtime_user,
    password: runtime_pass,
    pool: 20
  )

  [ 1, 10, 100, 1_000 ].each do |batch_size|
    iterations = batch_size == 1_000 ? 30 : 100
    sender_pool = firms[20..70].map { |r| r["uuid"] }
    raw_payloads = Array.new(iterations) do |iter|
      JSON.generate(
        payer_firm_uuid: sender_pool[iter % sender_pool.size],
        payments: Array.new(batch_size) do |j|
          {
            amount: "#{((j % 50) + 1)}.25",
            payee_firm_uuid: payee_pool[(iter + j) % payee_pool.size],
            description: "Bench payment iter=#{iter} item=#{j}"
          }
        end
      )
    end

    # Warmup
    warm_batch = BulkPayments::PayloadParser.parse(raw_payloads.first)
    BulkPayments::Poster.call(warm_batch)

    latencies_ms = []
    total_wall = measure_seconds do
      raw_payloads.each do |raw_json|
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        parsed = BulkPayments::PayloadParser.parse(raw_json)
        BulkPayments::Poster.call(parsed)
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        latencies_ms << ((t1 - t0) * 1_000.0)
      end
    end

    sorted = latencies_ms.sort
    p50 = sorted[(sorted.size * 0.50).floor]
    p95 = sorted[(sorted.size * 0.95).floor]
    p99 = sorted[[ (sorted.size * 0.99).floor, sorted.size - 1 ].min]
    batches_per_sec = iterations / total_wall
    payments_per_sec = (iterations * batch_size) / total_wall

    printf(
      "Sequential | batch_size=%-4d | runs=%-3d | p50=%6.2f ms | p95=%6.2f ms | p99=%6.2f ms | %6.1f batches/s (%8.1f payments/s)\n",
      batch_size, iterations, p50, p95, p99, batches_per_sec, payments_per_sec
    )
  end

  # Hot whale sender latency (50,000 historical rows)
  whale_latencies = []
  whale_json = JSON.generate(
    payer_firm_uuid: hot_firm_uuid,
    payments: Array.new(10) do |j|
      { amount: "5.50", payee_firm_uuid: payee_pool[j], description: "Whale transfer #{j}" }
    end
  )
  50.times do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    BulkPayments::Poster.call(BulkPayments::PayloadParser.parse(whale_json))
    whale_latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000.0)
  end
  whale_sorted = whale_latencies.sort
  printf(
    "Hot Sender (~50k history) | batch_size=10   | runs=50  | p50=%6.2f ms | p95=%6.2f ms | p99=%6.2f ms\n",
    whale_sorted[25], whale_sorted[47], whale_sorted[49]
  )

  # Concurrent multi-tenant throughput (8 threads across distinct senders vs same-sender contention)
  [ :distinct_senders, :same_sender_contention ].each do |mode|
    threads_count = 8
    batches_per_thread = 25
    batch_size = 20
    latencies_mutex = Mutex.new
    all_latencies = []

    wall = measure_seconds do
      workers = threads_count.times.map do |tid|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            batches_per_thread.times do |iter|
              sender_uuid = mode == :distinct_senders ? firms[200 + tid]["uuid"] : firms[300]["uuid"]
              raw_json = JSON.generate(
                payer_firm_uuid: sender_uuid,
                payments: Array.new(batch_size) do |j|
                  { amount: "1.00", payee_firm_uuid: payee_pool[(tid * 31 + j) % payee_pool.size], description: "Conc #{tid}-#{iter}-#{j}" }
                end
              )
              t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              parsed = BulkPayments::PayloadParser.parse(raw_json)
              BulkPayments::Poster.call(parsed, connection: conn)
              dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000.0
              latencies_mutex.synchronize { all_latencies << dt }
            end
          end
        end
      end
      workers.each(&:join)
    end

    sorted = all_latencies.sort
    total_batches = threads_count * batches_per_thread
    printf(
      "Concurrent (%-22s, 8 threads) | batch_size=%-2d | p50=%6.2f ms | p95=%6.2f ms | %6.1f batches/s (%8.1f payments/s)\n",
      mode,
      batch_size,
      sorted[(sorted.size * 0.50).floor],
      sorted[(sorted.size * 0.95).floor],
      total_batches / wall,
      (total_batches * batch_size) / wall
    )
  end

  # Final conservation check on the 1M+ benchmark database
  conservation = admin_conn.exec(<<~SQL).first
    SELECT
      (SELECT SUM(opening_balance_cents::numeric) FROM public.firm_descriptions) AS total_opening,
      (SELECT SUM(balance_cents) FROM public.firms) AS total_derived
  SQL
  puts "\nGlobal conservation check on benchmark DB: opening=#{conservation['total_opening']} == derived=#{conservation['total_derived']}"
  raise "Conservation invariant violated!" unless conservation["total_opening"] == conservation["total_derived"]
ensure
  ActiveRecord::Base.connection_handler.clear_all_connections!
  admin_conn&.close
  unless ENV["KEEP_BENCH_DB"] == "1"
    cleanup_conn = PG.connect(
      host: base_cfg[:host],
      port: base_cfg[:port],
      dbname: "postgres",
      user: admin_user,
      password: admin_pass
    )
    cleanup_conn.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(BENCH_DB)} WITH (FORCE)")
    cleanup_conn.close
  end
end
