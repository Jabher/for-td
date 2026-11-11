# Bulk Payments Ledger (`POST /bulk_payments`)

Minimal financial ledger on Ruby 4.0, Rails 8.1 (API mode, Puma), and PostgreSQL 18. Design inspired by typical distributed ledger and transaction databases like TigerBeetle.

> Time spent: ~4-5 hours
> 
> How proud: fairly proud for SQL part, good enough for Ruby part.
> 
> Also, very proud of not forgetting Ruby & Rails after a decade of not writing it.

## 1. Architecture, Ledger Model, and Design Choices

**All-or-nothing posting.** `POST /bulk_payments` is the sole endpoint. `BulkPayments::Poster` opens one `READ COMMITTED` transaction and calls `public.post_bulk_payments`. PostgreSQL locks only the sender row in `public.firm_descriptions` (`FOR NO KEY UPDATE`), reads the sender's balance from `public.firms` in a separate query, checks invariants, and inserts the batch via one static `MERGE ... WITH ORDINALITY` statement. Either the sender covers the gross sum and all payments commit (`201 Created`), or PostgreSQL raises an error, rolls back the batch, and Rails returns `422`.

**Ledger storage and safeguards.** Like a blockchain ledger, balances are never stored as mutable counters that can drift from history. `public.firm_descriptions` stores metadata and immutable `opening_balance_cents`; `public.payments` is an append-only log of immutable transfers; and `public.firms` derives `balance_cents` live (`opening + incoming - outgoing`) via correlated `NUMERIC` sums over covering indexes. Safeguards run in two layers:
- **Service shortcut (`BulkPayments::PayloadParser`)**: rejects malformed JSON, bad shapes, invalid USD strings or UUIDs, and self-transfers in memory before leasing a DB connection.
- **Database safeguards (`CreateFinancialLedger`)**: `ledger_runtime` can only insert firms, `UPDATE (name)` on `firm_descriptions`, read `firms`, and `EXECUTE` `SECURITY DEFINER` `public.post_bulk_payments` (owned by `ledger_definer`). Direct `payments` access is revoked, and `CHECK`/`FOREIGN KEY` constraints plus `BEFORE UPDATE/DELETE/TRUNCATE` triggers block mutation even by admin roles.

**Design narrowings and seeding three firms.** Compared to the challenge's mutable `firms` table: `public.firms` is a read-only view; batches are capped at `1..1000`; and self-transfers (`payer == payee`) are prohibited (`Idempotency-Key` is out of scope). Because `public.firms` is a view and `id` is `GENERATED ALWAYS AS IDENTITY`, replace `INSERT INTO firms (id, name, balance_cents, uuid)` with `public.firm_descriptions (name, opening_balance_cents, uuid)`. **Pinecrest CPA Group**, **Lopez Bookkeeping**, and **Nair Tax Services** are seeded automatically via `db/seeds.rb`; for manual SQL (`ledger_runtime` or admin):

```sql
INSERT INTO public.firm_descriptions (name, opening_balance_cents, uuid)
VALUES ('Pinecrest CPA Group', 5000000, '3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41'),
       ('Lopez Bookkeeping', 50000, '8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10'),
       ('Nair Tax Services', 200000, 'e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25');
```

Also, **idempotence was intentionally omitted** since it was outside the scope of original task. Idempotence key processing was not required by the original task scope, so it was omitted explicitly to keep the code smaller (since there's a lot of invariants enforced already, producing quite large SQL migrations).

## 2. How to Run

Boot PostgreSQL 18 (`:5434`), run migrations + seeds, and start Puma (`:3001`):

```bash
docker compose up -d --build
```

Re-run idempotent seeds anytime:

```bash
docker compose run --rm -e DB_ROLE=admin web ./bin/rails db:seed
```

Run tests (`21 runs, 43 assertions, 0 failures` in ~1s):

```bash
docker compose run --rm -e RAILS_ENV=test -e DB_ROLE=admin web ./bin/rails db:purge db:schema:load
docker compose run --rm -e RAILS_ENV=test web ./bin/rails test
```

Run benchmarks and `EXPLAIN (ANALYZE, BUFFERS)` (`script/benchmark_and_explain.rb`):

```bash
docker compose run --rm -e DB_ROLE=admin web ./bin/rails runner script/benchmark_and_explain.rb
```

Expect an isolated 10k-firm / 1M-payment DB, plans confirming `Heap Fetches: 0` Index-Only Scans and static `MERGE` inserts, p50/p95/p99 latency across 1–1,000 item batches, a 50k-row hot sender, and 8-thread contention, conservation check, and cleanup.

## 3. Guarantees, Invariants, and Test Enforcement

- **Conservation and exactness**: `public.firms` balances sum to total opening funds; sender debits equal recipient credits; USD strings map to exact `int4` cents (`$0.01`–`$21,474,836.47`) while balances and batch totals use uncapped `NUMERIC`.
- **Immutability and safe errors**: Committed rows and opening funds are immutable; bad inputs return `422` (`what`, `why`, `how_to_fix`), and unexpected faults return SQL-redacted `500` JSON.
- **Deadlock-free concurrency**: Sender-only locks serialize debits without blocking incoming credits.

Enforced by three Minitest suites:
- `BulkPaymentsIntegrationTest`: `201`/`422` contracts, threshold edges (`0/1/1000/1001`, `int4` cap, exact drain vs 1-cent-short rollback), `0`-SQL Layer 1 rejections, source-ordered `payment_ids`, and `500` redaction.
- `LedgerInvariantsAndSecurityTest`: `ledger_runtime` ACLs and seeds, table constraints, superuser triggers, `READ COMMITTED` checks, bypassed-parser SQL safeguards, and conservation.
- `ConcurrencyAndLockingTest`: 10-way sender contention, post-lock `READ COMMITTED` top-up visibility, and deadlock-free `A -> B` / `B -> A` transfers.
