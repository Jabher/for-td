# Bulk Payments Financial Ledger API

Minimal, financial-grade bulk payment ledger built with **Ruby 4.0.9**, **Rails 8.1.4.1** (API mode, Puma), and **PostgreSQL 18**.

## Quick Start (Docker & Docker Compose Only)

Nothing is required on the host beyond Docker and Docker Compose:

```bash
docker compose up -d --build
```

- **Rails API (Puma)**: `http://localhost:3001` (override via `WEB_PORT`)
- **PostgreSQL 18**: `localhost:5434` (override via `POSTGRES_PORT`)

Run the full test suite inside Docker (against PostgreSQL 18):

```bash
docker compose run --rm -e RAILS_ENV=test -e DB_ROLE=admin web ./bin/rails db:purge db:schema:load
docker compose run --rm -e RAILS_ENV=test web ./bin/rails test
```

Run the large-scale benchmark & `EXPLAIN (ANALYZE, BUFFERS)` investigation:

```bash
docker compose run --rm -e DB_ROLE=admin web ./bin/rails runner script/benchmark_and_explain.rb
```

## Endpoint Contract

`POST /bulk_payments` is the sole endpoint in this service.
*(Note: HTTP `Idempotency-Key` support is intentionally out of scope.)*

### Request (`201 Created` on commit, `422 Unprocessable Content` on validation/accounting rejection)

```json
{
  "payer_firm_uuid": "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
  "payments": [
    {
      "amount": "6250",
      "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
      "description": "Overflow returns, August 2026"
    },
    {
      "amount": "5800.5",
      "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
      "description": "Amended returns, August 2026"
    },
    {
      "amount": "1200.75",
      "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10",
      "description": "Bookkeeping cleanup, 3 clients"
    }
  ]
}
```

### Error Format (`errors-as-doors`)

Every `422` response returns a stable JSON structure explaining **what** failed, **why** it failed, and **how_to_fix** it:

```json
{
  "error": {
    "code": "insufficient_funds",
    "what": "Insufficient funds for payer firm 3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41: available 10000 cents, requested batch total 10001 cents.",
    "why": "The payer firm's current derived balance cannot cover the gross sum of all requested payments in this batch.",
    "how_to_fix": "Reduce the total requested payment amount or wait for incoming funds before retrying.",
    "field": "payments"
  }
}
```

## Architecture & Database Security

- **`public.firm_descriptions`**: Immutable `id`, immutable indexed `uuid`, mutable `name`, and immutable non-negative `opening_balance_cents` (`INTEGER`).
- **`public.payments`**: Strictly append-only, immutable ledger of transfers (`payer_firm_id`, `payee_firm_id`, `amount_cents` `INTEGER > 0`, non-blank `description`). Indexed with covering B-trees `(payee_firm_id) INCLUDE (amount_cents)` and `(payer_firm_id) INCLUDE (amount_cents)` for heap-free Index-Only Scans.
- **`public.firms`**: Read-only view deriving exact `NUMERIC` `balance_cents` from `opening_balance_cents + incoming - outgoing` with zero stored snapshots or triggers updating balances.
- **`public.post_bulk_payments(...)`**: `VOLATILE` `SECURITY DEFINER` PL/pgSQL function owned by `ledger_definer` with `SET search_path = pg_catalog, pg_temp`. Enforces `READ COMMITTED`, acquires `FOR NO KEY UPDATE` exclusively on the sender row in `firm_descriptions`, reads the fresh derived `NUMERIC` balance from `firms` in a separate SQL command, validates all accounting invariants, and atomically inserts the entire batch.
- **Least-Privilege Runtime Role (`ledger_runtime`)**: Can `INSERT (uuid, name, opening_balance_cents)` and `UPDATE (name)` on `firm_descriptions`, `SELECT` on `firm_descriptions` and `firms`, and `EXECUTE` `post_bulk_payments`. Cannot read or write `payments` directly, cannot update `id`/`uuid`/`opening_balance_cents`, cannot delete rows, and cannot alter database objects.

## Agent Skills Included in Repository

- [`skills/errors-as-doors/`](skills/errors-as-doors/SKILL.md) (with [cross-domain research consolidation](skills/errors-as-doors/references/errors-as-doors-cross-domain-2026-05-30.md)): educational boundary rejection design (`fact -> reason -> action` doors).
- [`skills/comments/`](skills/comments/SKILL.md) (with [adjudicated stance & schools](skills/comments/references/schools.md)): existence test for code comments, file preambles, and named laws.
- Registered for automatic workspace discovery via [`.agents/skills.json`](.agents/skills.json).
