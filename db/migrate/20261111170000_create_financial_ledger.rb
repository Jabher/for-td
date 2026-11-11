# frozen_string_literal: true

# Layer 2 — Database Safeguard Layer (complements `BulkPayments::PayloadParser` Layer 1 shortcuts).
#
# Even if Layer 1 is bypassed (direct SQL callers, future endpoints, or a Ruby bug), PostgreSQL
# makes invalid states, race overdrafts, and ledger mutation impossible by construction:
# 1. `public.post_bulk_payments`: `VOLATILE SECURITY DEFINER` owned by `ledger_definer` (`NOLOGIN`)
#    with fixed `search_path = pg_catalog, pg_temp`. Independently re-verifies writable
#    `READ COMMITTED` isolation, array/item bounds, self-payment prohibition, sender-only
#    `FOR NO KEY UPDATE` serialization, separate-statement `NUMERIC` balance check, and static
#    `MERGE ... ON FALSE ... RETURNING` batch insertion ordered by source ordinality.
# 2. Table `CHECK` & `ON UPDATE/DELETE RESTRICT` `FOREIGN KEY` constraints on `firm_descriptions` and `payments`.
# 3. `BEFORE UPDATE/DELETE/TRUNCATE` triggers enforcing append-only `payments` and immutable firm columns.
# 4. Least-privilege grants (`apply_ledger_security`) restricting `ledger_runtime` to `INSERT` +
#    column-level `UPDATE(name)` on `firm_descriptions`, `SELECT` on `firm_descriptions`/`firms`,
#    and `EXECUTE` on `post_bulk_payments` (zero direct access to `payments` or DDL).
class CreateFinancialLedger < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DO $bootstrap_roles$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_definer') THEN
          CREATE ROLE ledger_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_runtime') THEN
          CREATE ROLE ledger_runtime LOGIN PASSWORD 'ledger_runtime_secret' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
        END IF;
      END
      $bootstrap_roles$;

      CREATE TABLE public.firm_descriptions (
        id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        uuid UUID NOT NULL DEFAULT pg_catalog.uuidv7(),
        name VARCHAR(255) NOT NULL,
        opening_balance_cents INTEGER NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT chk_firm_descriptions_opening_balance_non_negative CHECK (opening_balance_cents >= 0),
        CONSTRAINT chk_firm_descriptions_name_not_blank CHECK (pg_catalog.btrim(name, E' \\t\\r\\n\\v\\f') <> '')
      );

      CREATE TABLE public.payments (
        id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        payer_firm_id BIGINT NOT NULL,
        payee_firm_id BIGINT NOT NULL,
        amount_cents INTEGER NOT NULL,
        description TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT fk_payments_payer_firm
          FOREIGN KEY (payer_firm_id) REFERENCES public.firm_descriptions (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
        CONSTRAINT fk_payments_payee_firm
          FOREIGN KEY (payee_firm_id) REFERENCES public.firm_descriptions (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
        CONSTRAINT chk_payments_positive_amount CHECK (amount_cents > 0),
        CONSTRAINT chk_payments_no_self_transfer CHECK (payer_firm_id <> payee_firm_id),
        CONSTRAINT chk_payments_description_not_blank CHECK (pg_catalog.btrim(description, E' \\t\\r\\n\\v\\f') <> '')
      );

      -- `INCLUDE` columns enable heap-free Index-Only Scans (`Heap Fetches: 0`) for sender lookup and balance sums.
      CREATE UNIQUE INDEX idx_firm_descriptions_uuid_covering
        ON public.firm_descriptions (uuid) INCLUDE (id);

      CREATE INDEX idx_payments_payee_firm_id_amount
        ON public.payments (payee_firm_id) INCLUDE (amount_cents);

      CREATE INDEX idx_payments_payer_firm_id_amount
        ON public.payments (payer_firm_id) INCLUDE (amount_cents);

      -- Defense-in-depth immutability safeguard: blocks mutation/deletion even by privileged DB roles.
      CREATE OR REPLACE FUNCTION public.guard_firm_descriptions_immutability()
      RETURNS TRIGGER
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'Firm records cannot be deleted or truncated.',
            DETAIL = 'firm_immutable',
            HINT = 'Do not delete or truncate rows in firm_descriptions.';
        END IF;

        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.uuid IS DISTINCT FROM OLD.uuid
           OR NEW.opening_balance_cents IS DISTINCT FROM OLD.opening_balance_cents
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
          RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'Only firm name may be updated after creation; id, uuid, opening_balance_cents, and created_at are immutable.',
            DETAIL = 'firm_immutable_columns',
            HINT = 'Update only the name column on firm_descriptions.';
        END IF;

        NEW.updated_at := CURRENT_TIMESTAMP;
        RETURN NEW;
      END;
      $fn$;

      CREATE TRIGGER trg_firm_descriptions_immutability
      BEFORE UPDATE OR DELETE ON public.firm_descriptions
      FOR EACH ROW
      EXECUTE FUNCTION public.guard_firm_descriptions_immutability();

      CREATE OR REPLACE FUNCTION public.guard_payments_immutability()
      RETURNS TRIGGER
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      BEGIN
        RAISE EXCEPTION USING
          ERRCODE = '55000',
          MESSAGE = 'Payment rows are strictly append-only and immutable after creation.',
          DETAIL = 'payment_immutable',
          HINT = 'Record a compensating transfer rather than updating or deleting existing payments.';
      END;
      $fn$;

      CREATE TRIGGER trg_payments_immutability
      BEFORE UPDATE OR DELETE ON public.payments
      FOR EACH ROW
      EXECUTE FUNCTION public.guard_payments_immutability();

      CREATE TRIGGER trg_payments_no_truncate
      BEFORE TRUNCATE ON public.payments
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.guard_payments_immutability();

      CREATE TRIGGER trg_firm_descriptions_no_truncate
      BEFORE TRUNCATE ON public.firm_descriptions
      FOR EACH STATEMENT
      EXECUTE FUNCTION public.guard_firm_descriptions_immutability();

      -- Correlated scalar aggregates bind `fd.id` directly into the covering `(payee_firm_id)` /
      -- `(payer_firm_id)` Index-Only Scans without materializing or grouping unrelated firms.
      CREATE VIEW public.firms AS
      SELECT
        fd.id,
        fd.uuid,
        fd.name,
        (
          fd.opening_balance_cents::pg_catalog.numeric
          + COALESCE(
            (
              SELECT SUM(p_in.amount_cents::pg_catalog.numeric)
              FROM public.payments AS p_in
              WHERE p_in.payee_firm_id = fd.id
            ),
            0::pg_catalog.numeric
          )
          - COALESCE(
            (
              SELECT SUM(p_out.amount_cents::pg_catalog.numeric)
              FROM public.payments AS p_out
              WHERE p_out.payer_firm_id = fd.id
            ),
            0::pg_catalog.numeric
          )
        ) AS balance_cents
      FROM public.firm_descriptions AS fd;

      CREATE OR REPLACE FUNCTION public.post_bulk_payments(
        p_payer_uuid UUID,
        p_payee_uuids UUID[],
        p_amounts_cents INTEGER[],
        p_descriptions TEXT[]
      )
      RETURNS BIGINT[]
      LANGUAGE plpgsql
      VOLATILE
      SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      AS $fn$
      DECLARE
        v_isolation TEXT;
        v_read_only TEXT;
        v_batch_size INTEGER;
        v_payer_id BIGINT;
        v_balance NUMERIC;
        v_gross_total NUMERIC;
        v_bad_ord BIGINT;
        v_bad_uuid UUID;
        v_inserted_ids BIGINT[];
      BEGIN
        -- `REPEATABLE READ` / `SERIALIZABLE` would read a transaction-start snapshot instead of
        -- post-lock committed credits; `READ COMMITTED` is mandatory for lock-then-balance correctness.
        v_isolation := pg_catalog.current_setting('transaction_isolation');
        IF v_isolation <> 'read committed' THEN
          RAISE EXCEPTION USING
            ERRCODE = '25001',
            MESSAGE = pg_catalog.format('Incompatible transaction isolation level %L; READ COMMITTED is required.', v_isolation),
            DETAIL = 'invalid_transaction_isolation',
            HINT = 'Run post_bulk_payments inside BEGIN ISOLATION LEVEL READ COMMITTED.';
        END IF;

        v_read_only := pg_catalog.current_setting('transaction_read_only');
        IF v_read_only <> 'off' THEN
          RAISE EXCEPTION USING
            ERRCODE = '25006',
            MESSAGE = 'Cannot post bulk payments in a read-only transaction.',
            DETAIL = 'read_only_transaction',
            HINT = 'Start a read-write READ COMMITTED transaction before calling post_bulk_payments.';
        END IF;

        -- Database safeguard guards: re-enforce every input invariant independently of Ruby Layer 1
        -- so direct SQL callers or future service paths cannot bypass batch/item validation.
        IF p_payer_uuid IS NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = '22004',
            MESSAGE = 'payer_firm_uuid must not be null.',
            DETAIL = 'null_payer_firm_uuid',
            HINT = 'Provide a valid UUID identifying an existing payer firm.';
        END IF;

        IF p_payee_uuids IS NULL OR p_amounts_cents IS NULL OR p_descriptions IS NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = '22004',
            MESSAGE = 'Payment arrays (payee_uuids, amounts_cents, descriptions) must not be null.',
            DETAIL = 'null_payment_arrays',
            HINT = 'Provide parallel non-null 1-D arrays of 1 to 1000 elements.';
        END IF;

        IF COALESCE(pg_catalog.array_ndims(p_payee_uuids), 0) > 1
           OR COALESCE(pg_catalog.array_ndims(p_amounts_cents), 0) > 1
           OR COALESCE(pg_catalog.array_ndims(p_descriptions), 0) > 1
           OR (pg_catalog.array_ndims(p_payee_uuids) = 1 AND pg_catalog.array_lower(p_payee_uuids, 1) <> 1)
           OR (pg_catalog.array_ndims(p_amounts_cents) = 1 AND pg_catalog.array_lower(p_amounts_cents, 1) <> 1)
           OR (pg_catalog.array_ndims(p_descriptions) = 1 AND pg_catalog.array_lower(p_descriptions, 1) <> 1) THEN
          RAISE EXCEPTION USING
            ERRCODE = '2202E',
            MESSAGE = 'Payment argument arrays must be standard 1-dimensional 1-based arrays.',
            DETAIL = 'invalid_array_dimensions',
            HINT = 'Pass 1-dimensional arrays starting at index 1.';
        END IF;

        v_batch_size := pg_catalog.cardinality(p_payee_uuids);

        IF v_batch_size <> pg_catalog.cardinality(p_amounts_cents)
           OR v_batch_size <> pg_catalog.cardinality(p_descriptions) THEN
          RAISE EXCEPTION USING
            ERRCODE = '2202E',
            MESSAGE = 'Payment argument arrays must all have the exact same length.',
            DETAIL = 'mismatched_array_lengths',
            HINT = 'Ensure payee_uuids, amounts_cents, and descriptions contain one entry per payment.';
        END IF;

        IF v_batch_size < 1 OR v_batch_size > 1000 THEN
          RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = pg_catalog.format('Batch size must be between 1 and 1000 payments; received %s.', v_batch_size),
            DETAIL = 'invalid_batch_size',
            HINT = 'Submit between 1 and 1000 payment items per request.';
        END IF;

        SELECT u.ord
        INTO v_bad_ord
        FROM ROWS FROM (
          pg_catalog.unnest(p_payee_uuids),
          pg_catalog.unnest(p_amounts_cents),
          pg_catalog.unnest(p_descriptions)
        ) WITH ORDINALITY AS u(payee_uuid, amount_cents, description, ord)
        WHERE u.payee_uuid IS NULL
        ORDER BY u.ord
        LIMIT 1;

        IF v_bad_ord IS NOT NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = '22004',
            MESSAGE = pg_catalog.format('Payment at index %s has a null payee_firm_uuid.', v_bad_ord - 1),
            DETAIL = 'null_payee_firm_uuid',
            HINT = 'Provide a valid UUID for every payee_firm_uuid.';
        END IF;

        SELECT u.ord
        INTO v_bad_ord
        FROM ROWS FROM (
          pg_catalog.unnest(p_amounts_cents)
        ) WITH ORDINALITY AS u(amount_cents, ord)
        WHERE u.amount_cents IS NULL OR u.amount_cents <= 0
        ORDER BY u.ord
        LIMIT 1;

        IF v_bad_ord IS NOT NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = pg_catalog.format('Payment at index %s must have a strictly positive integer cent amount.', v_bad_ord - 1),
            DETAIL = 'invalid_amount_cents',
            HINT = 'Provide a positive USD amount between "0.01" and "21474836.47".';
        END IF;

        SELECT u.ord
        INTO v_bad_ord
        FROM ROWS FROM (
          pg_catalog.unnest(p_descriptions)
        ) WITH ORDINALITY AS u(description, ord)
        WHERE u.description IS NULL OR pg_catalog.btrim(u.description, E' \\t\\r\\n\\v\\f') = ''
        ORDER BY u.ord
        LIMIT 1;

        IF v_bad_ord IS NOT NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = pg_catalog.format('Payment at index %s must have a non-empty description after trimming whitespace.', v_bad_ord - 1),
            DETAIL = 'blank_description',
            HINT = 'Provide a non-empty string description containing at least one non-whitespace character.';
        END IF;

        SELECT u.ord
        INTO v_bad_ord
        FROM ROWS FROM (
          pg_catalog.unnest(p_payee_uuids)
        ) WITH ORDINALITY AS u(payee_uuid, ord)
        WHERE u.payee_uuid = p_payer_uuid
        ORDER BY u.ord
        LIMIT 1;

        IF v_bad_ord IS NOT NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = 'P0001',
            MESSAGE = pg_catalog.format('Self-payment is not permitted (payment at index %s targets payer firm %s).', v_bad_ord - 1, p_payer_uuid),
            DETAIL = 'self_payment',
            HINT = 'Ensure every payee_firm_uuid differs from payer_firm_uuid.';
        END IF;

        -- Sender-only serialization law: lock ONLY the sender's `firm_descriptions` row (`FOR NO KEY UPDATE`),
        -- never recipients. Incoming transfers take only FK `FOR KEY SHARE`, preventing cross-firm deadlocks.
        BEGIN
          SELECT fd.id INTO STRICT v_payer_id
          FROM public.firm_descriptions AS fd
          WHERE fd.uuid = p_payer_uuid
          FOR NO KEY UPDATE;
        EXCEPTION
          WHEN NO_DATA_FOUND THEN
            RAISE EXCEPTION USING
              ERRCODE = 'P0001',
              MESSAGE = pg_catalog.format('Payer firm with UUID %s does not exist.', p_payer_uuid),
              DETAIL = 'unknown_payer_firm',
              HINT = 'Verify payer_firm_uuid refers to an existing firm.';
        END;

        -- Separate-statement balance law: under `READ COMMITTED`, a new SQL command acquires a fresh
        -- snapshot AFTER `FOR NO KEY UPDATE` grants, observing all transfers committed while waiting.
        -- Combining lock + sum in one query would evaluate against a pre-lock snapshot and overdraft!
        SELECT f.balance_cents INTO STRICT v_balance
        FROM public.firms AS f
        WHERE f.id = v_payer_id;

        SELECT SUM(u.amount_cents::pg_catalog.numeric)
        INTO STRICT v_gross_total
        FROM pg_catalog.unnest(p_amounts_cents) AS u(amount_cents);

        -- Read-only payee existence check (acquires zero row locks on recipients).
        SELECT u.ord, u.payee_uuid
        INTO v_bad_ord, v_bad_uuid
        FROM (
          SELECT DISTINCT ON (items.payee_uuid) items.ord, items.payee_uuid
          FROM ROWS FROM (
            pg_catalog.unnest(p_payee_uuids)
          ) WITH ORDINALITY AS items(payee_uuid, ord)
          ORDER BY items.payee_uuid, items.ord
        ) AS u
        LEFT JOIN public.firm_descriptions AS fd ON fd.uuid = u.payee_uuid
        WHERE fd.id IS NULL
        ORDER BY u.ord
        LIMIT 1;

        IF v_bad_ord IS NOT NULL THEN
          RAISE EXCEPTION USING
            ERRCODE = 'P0001',
            MESSAGE = pg_catalog.format('Payee firm with UUID %s at payment index %s does not exist.', v_bad_uuid, v_bad_ord - 1),
            DETAIL = 'unknown_payee_firm',
            HINT = 'Ensure every payee_firm_uuid refers to an existing firm.';
        END IF;

        IF v_balance < v_gross_total THEN
          RAISE EXCEPTION USING
            ERRCODE = 'P0001',
            MESSAGE = pg_catalog.format(
              'Insufficient funds for payer firm %s: available %s cents, requested batch total %s cents.',
              p_payer_uuid,
              v_balance,
              v_gross_total
            ),
            DETAIL = 'insufficient_funds',
            HINT = 'Reduce the total requested payment amount or wait for incoming funds before retrying.';
        END IF;

        -- PG 17+ `MERGE ... ON FALSE ... RETURNING`: unlike `INSERT ... SELECT ... RETURNING`,
        -- `MERGE RETURNING` exposes `src` columns (`src.ord`) alongside generated `p.id` in one
        -- static plan-cached SQL statement (no dynamic SQL). `array_agg(inserted.id ORDER BY inserted.ord)`
        -- decouples returned IDs from `USING`-join execution/ID-allocation order and bare `array_agg()`'s
        -- unspecified input order. Multi-arg `unnest(...)` is a SQL grammar construct expanding internally
        -- to `ROWS FROM (...)` and cannot carry a schema prefix.
        WITH inserted AS (
          MERGE INTO public.payments AS p
          USING (
            SELECT
              fd.id AS payee_id,
              u.amount_cents,
              u.description,
              u.ord
            FROM unnest(p_payee_uuids, p_amounts_cents, p_descriptions) WITH ORDINALITY
              AS u(payee_uuid, amount_cents, description, ord)
            JOIN public.firm_descriptions AS fd ON fd.uuid = u.payee_uuid
          ) AS src
          ON FALSE
          WHEN NOT MATCHED THEN
            INSERT (payer_firm_id, payee_firm_id, amount_cents, description)
            VALUES (v_payer_id, src.payee_id, src.amount_cents, src.description)
          RETURNING p.id, src.ord
        )
        SELECT COALESCE(pg_catalog.array_agg(inserted.id ORDER BY inserted.ord), ARRAY[]::bigint[])
        INTO STRICT v_inserted_ids
        FROM inserted;

        IF COALESCE(pg_catalog.cardinality(v_inserted_ids), 0) <> v_batch_size THEN
          RAISE EXCEPTION USING
            ERRCODE = 'XX000',
            MESSAGE = 'Unexpected mismatch in persisted payment count.',
            DETAIL = 'persisted_count_mismatch',
            HINT = 'Retry the transaction.';
        END IF;

        RETURN v_inserted_ids;
      END;
      $fn$;

      -- Encapsulated as a callable function because ActiveRecord's `pg_dump --no-owner --no-privileges`
      -- omits `ALTER ... OWNER` and `GRANT`/`REVOKE` statements from `db/structure.sql` (`lib/tasks/ledger_security.rake`).
      CREATE OR REPLACE FUNCTION public.apply_ledger_security()
      RETURNS void
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      AS $sec$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_definer') THEN
          CREATE ROLE ledger_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_runtime') THEN
          CREATE ROLE ledger_runtime LOGIN PASSWORD 'ledger_runtime_secret' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
        END IF;

        ALTER TABLE public.firm_descriptions OWNER TO ledger_definer;
        ALTER TABLE public.payments OWNER TO ledger_definer;
        ALTER VIEW public.firms OWNER TO ledger_definer;
        ALTER FUNCTION public.guard_firm_descriptions_immutability() OWNER TO ledger_definer;
        ALTER FUNCTION public.guard_payments_immutability() OWNER TO ledger_definer;
        ALTER FUNCTION public.post_bulk_payments(UUID, UUID[], INTEGER[], TEXT[]) OWNER TO ledger_definer;

        REVOKE CREATE ON SCHEMA public FROM PUBLIC, ledger_runtime;
        GRANT USAGE ON SCHEMA public TO ledger_definer, ledger_runtime;

        REVOKE ALL ON TABLE public.firm_descriptions FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON TABLE public.payments FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON TABLE public.firms FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON SEQUENCE public.firm_descriptions_id_seq FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON SEQUENCE public.payments_id_seq FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON FUNCTION public.guard_firm_descriptions_immutability() FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON FUNCTION public.guard_payments_immutability() FROM PUBLIC, ledger_runtime;
        REVOKE ALL ON FUNCTION public.post_bulk_payments(UUID, UUID[], INTEGER[], TEXT[]) FROM PUBLIC, ledger_runtime;

        GRANT SELECT (id, uuid, name, opening_balance_cents, created_at, updated_at)
          ON TABLE public.firm_descriptions TO ledger_runtime;
        GRANT INSERT (uuid, name, opening_balance_cents)
          ON TABLE public.firm_descriptions TO ledger_runtime;
        GRANT UPDATE (name)
          ON TABLE public.firm_descriptions TO ledger_runtime;
        GRANT USAGE ON SEQUENCE public.firm_descriptions_id_seq TO ledger_runtime;

        GRANT SELECT ON TABLE public.firms TO ledger_runtime;

        GRANT EXECUTE ON FUNCTION public.post_bulk_payments(UUID, UUID[], INTEGER[], TEXT[])
          TO ledger_runtime;

        IF pg_catalog.to_regclass('public.schema_migrations') IS NOT NULL THEN
          REVOKE ALL ON TABLE public.schema_migrations FROM PUBLIC, ledger_runtime;
        END IF;

        IF pg_catalog.to_regclass('public.ar_internal_metadata') IS NOT NULL THEN
          REVOKE ALL ON TABLE public.ar_internal_metadata FROM PUBLIC, ledger_runtime;
        END IF;
      END;
      $sec$;

      SELECT public.apply_ledger_security();
      REVOKE ALL ON FUNCTION public.apply_ledger_security() FROM PUBLIC, ledger_runtime;
    SQL
  end

  def down
    execute <<~SQL
      DROP FUNCTION IF EXISTS public.apply_ledger_security();
      DROP FUNCTION IF EXISTS public.post_bulk_payments(UUID, UUID[], INTEGER[], TEXT[]);
      DROP VIEW IF EXISTS public.firms;
      DROP TABLE IF EXISTS public.payments;
      DROP TABLE IF EXISTS public.firm_descriptions;
      DROP FUNCTION IF EXISTS public.guard_payments_immutability();
      DROP FUNCTION IF EXISTS public.guard_firm_descriptions_immutability();
    SQL
  end
end
