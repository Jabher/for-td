SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: apply_ledger_security(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_ledger_security() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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
$$;


--
-- Name: guard_firm_descriptions_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_firm_descriptions_immutability() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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
$$;


--
-- Name: guard_payments_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_payments_immutability() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = '55000',
    MESSAGE = 'Payment rows are strictly append-only and immutable after creation.',
    DETAIL = 'payment_immutable',
    HINT = 'Record a compensating transfer rather than updating or deleting existing payments.';
END;
$$;


--
-- Name: post_bulk_payments(uuid, uuid[], integer[], text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_bulk_payments(p_payer_uuid uuid, p_payee_uuids uuid[], p_amounts_cents integer[], p_descriptions text[]) RETURNS bigint[]
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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
  WHERE u.description IS NULL OR pg_catalog.btrim(u.description, E' \t\r\n\v\f') = ''
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
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: firm_descriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.firm_descriptions (
    id bigint NOT NULL,
    uuid uuid DEFAULT uuidv7() NOT NULL,
    name character varying(255) NOT NULL,
    opening_balance_cents integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_firm_descriptions_name_not_blank CHECK ((btrim((name)::text, ' 	
'::text) <> ''::text)),
    CONSTRAINT chk_firm_descriptions_opening_balance_non_negative CHECK ((opening_balance_cents >= 0))
);


--
-- Name: firm_descriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.firm_descriptions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.firm_descriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id bigint NOT NULL,
    payer_firm_id bigint NOT NULL,
    payee_firm_id bigint NOT NULL,
    amount_cents integer NOT NULL,
    description text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_payments_description_not_blank CHECK ((btrim(description, ' 	
'::text) <> ''::text)),
    CONSTRAINT chk_payments_no_self_transfer CHECK ((payer_firm_id <> payee_firm_id)),
    CONSTRAINT chk_payments_positive_amount CHECK ((amount_cents > 0))
);


--
-- Name: firms; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.firms AS
 SELECT id,
    uuid,
    name,
    (((opening_balance_cents)::numeric + COALESCE(( SELECT sum((p_in.amount_cents)::numeric) AS sum
           FROM public.payments p_in
          WHERE (p_in.payee_firm_id = fd.id)), (0)::numeric)) - COALESCE(( SELECT sum((p_out.amount_cents)::numeric) AS sum
           FROM public.payments p_out
          WHERE (p_out.payer_firm_id = fd.id)), (0)::numeric)) AS balance_cents
   FROM public.firm_descriptions fd;


--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: firm_descriptions firm_descriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.firm_descriptions
    ADD CONSTRAINT firm_descriptions_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: idx_firm_descriptions_uuid_covering; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_firm_descriptions_uuid_covering ON public.firm_descriptions USING btree (uuid) INCLUDE (id);


--
-- Name: idx_payments_payee_firm_id_amount; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_payee_firm_id_amount ON public.payments USING btree (payee_firm_id) INCLUDE (amount_cents);


--
-- Name: idx_payments_payer_firm_id_amount; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_payer_firm_id_amount ON public.payments USING btree (payer_firm_id) INCLUDE (amount_cents);


--
-- Name: firm_descriptions trg_firm_descriptions_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_firm_descriptions_immutability BEFORE DELETE OR UPDATE ON public.firm_descriptions FOR EACH ROW EXECUTE FUNCTION public.guard_firm_descriptions_immutability();


--
-- Name: firm_descriptions trg_firm_descriptions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_firm_descriptions_no_truncate BEFORE TRUNCATE ON public.firm_descriptions FOR EACH STATEMENT EXECUTE FUNCTION public.guard_firm_descriptions_immutability();


--
-- Name: payments trg_payments_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payments_immutability BEFORE DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.guard_payments_immutability();


--
-- Name: payments trg_payments_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payments_no_truncate BEFORE TRUNCATE ON public.payments FOR EACH STATEMENT EXECUTE FUNCTION public.guard_payments_immutability();


--
-- Name: payments fk_payments_payee_firm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT fk_payments_payee_firm FOREIGN KEY (payee_firm_id) REFERENCES public.firm_descriptions(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: payments fk_payments_payer_firm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT fk_payments_payer_firm FOREIGN KEY (payer_firm_id) REFERENCES public.firm_descriptions(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261111170000');

SELECT public.apply_ledger_security();
REVOKE ALL ON FUNCTION public.apply_ledger_security() FROM PUBLIC, ledger_runtime;

