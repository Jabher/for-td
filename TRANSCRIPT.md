*Sadly, Antigravity does not allow exports of the conversation. The following transcript is full copy-paste from the original conversation (with tool calls and edits omitted). For better reconstruction, commits were done after each prompt and called out explicitly.*

Harness: Antigravity

Model: Gemini 4 Carbon, Low

*Note on reasoning choice: low reasoning was chosen specifically to keep aligned with large, detailed prompt, and reduce the extras produced by the model. Since Carbon was released few days ago, it's still hard to predict the behavior on High reasoning.* 

# Prompt 1

> Need your expertise in Ruby/RoR.
> 
> Initialize the git repo, install all dependencies needed such as Ruby (prefer brew where available), set up PostgreSQL 18 in Docker (create a docker-compose file for that), and implement the service that will provide the functionality I'll describe below. Use latest Ruby (4.x) and Rails (8.1.x) in API mode. Target repo state must be a docker-compose setup that is runnable without anything but Docker and Compose in the environment. Follow typical Ruby conventions: thin controllers, version pinning, reliable SQL, bound parameters, meaningful errors (prefer errors-as-doors pattern); use Puma. Where appropriate, prefer defaults; the generated baseline must be the initial commit in this repo.
> 
> No need for frontend tooling, Redis, jobs, auth, Kafka - we only need RoR and PG in this setup. All we need here is the minimal repo that proves this specific chunk of functionality.
> 
> The functionality:
> 
> Implement POST /bulk_payments (this is the only endpoint that will exist in this project) accepting exactly this input shape:
> 
> ```
> {
>   "payer_firm_uuid": "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
>   "payments": [
>     {
>       "amount": "6250",
>       "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
>       "description": "Overflow returns, August 2026"
>     },
>     {
>       "amount": "5800.5",
>       "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
>       "description": "Amended returns, August 2026"
>     },
>     {
>       "amount": "1200.75",
>       "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10",
>       "description": "Bookkeeping cleanup, 3 clients"
>     }
>   ]
> }
> ```
> 
> If the payer cannot cover the gross sum of every requested payment, return HTTP 422 and persist nothing; otherwise, persist every payment atomically and return HTTP 201 after commit.
> 
> Do NOT implement Idempotency-Key HTTP support; instead, leave an explicit comment that it is intentionally out of scope.
> 
> Repeated items are valid, both the same payee_firm_uuid and a full match. Preserve each item as a separate payment.
> 
> Self-payments should return 422.
> 
> Malformed JSON must return 422 with a detailed explanation.
> 
> payee_firm_uuid and payer_firm_uuid must be valid UUIDs identifying existing firms, otherwise 422. All other error cases must be 422 too, with a stable JSON response explaining what is wrong, why it is wrong, and how it can be fixed. For unexpected internal failures, return a generic explanation and log the details rather than exposing SQL or stack traces.
> 
> amount represents an amount in US dollars, not cents. It must be a positive, non-zero JSON string containing ordinary decimal digits, with either no fractional part, one fractional digit, or two fractional digits. For example, "1", "1.2", "1.23", and "0.01" are valid.
> 
> The whole-dollar part must not have leading zeros: "0.50" is allowed, while "00.50" and "01" are rejected. Reject zero amounts, exponent notation, signs, surrounding whitespace, a missing whole-dollar part such as ".50", a trailing dot such as "1.", and more than two fractional digits. Convert to integer cents exactly, without floating point or rounding.
> 
> Individual payment amounts must fit PostgreSQL INTEGER (int4): explicitly reject amounts above 2,147,483,647 cents. Thus "21474836.47" is within the amount limit and "21474836.48" is above it.
> 
> description must be a string and non-empty after trimming.
> 
> Support 1 to 1000 payments per batch; explicitly reject empty batches and 1001+.
> 
> All constraints described must be covered with both negative and positive tests at the thresholds and the edge cases.
> 
> Database structure (apply appropriate indexes and constraints):
> 
> - firm_descriptions: real table, stable firm ID, unique public UUID (uuid, immutable, indexed), name string, opening_balance_cents (INTEGER, non-negative, immutable after creation).
> - payments: real table, stable ID, payer_firm_id and payee_firm_id referencing firm_descriptions, amount_cents (INTEGER), description. The full row is immutable after creation.
> - firms: read-only view exposing firm_descriptions.id, firm_descriptions.uuid, firm_descriptions.name, and current derived balance_cents.
> 
> Keep this as a raw ledger with the two tables above; do not introduce stored cumulative snapshots. Calculate the balance directly from payment history:
> 
> `balance(a) = opening(a) + SUM(amount_cents of payments whose payee is a) - SUM(amount_cents of payments whose payer is a)`
> 
> Treat an empty sum as zero. Use exact NUMERIC arithmetic for batch totals and balance aggregates, casting payment amounts before summation. Do not cast the derived balance back to INTEGER or impose an INTEGER-sized recipient balance cap; the INTEGER limit applies to individual stored payment amounts and opening funds.
> 
> Treat it as a financial-grade system in miniature.
> 
> Maintain these invariants:
> 
> - The total outgoing amount for each sender equals the total recipient credits originating from that sender.
> - Raw history plus opening funds always reproduces the view's balance.
> - Every payment references an existing payer and payee.
> - Amounts are strictly positive, IDs and firm UUIDs have uniqueness guaranteed, and financial history is append-only.
> - No synchronous shared recipient balance update is hidden anywhere, e.g. in a callback or trigger.
> - Numeric overflow or invalid monetary arithmetic causes the whole posting to fail, rather than wrapping, rounding, or persisting partial results.
> 
> For writes, implement one VOLATILE PL/pgSQL posting function as the runtime entry point. Decide what's better on input - JSONB or a normalized representation are both fine; choose what works better from the Ruby perspective. Keep Rails validating the HTTP contract; PG fully validates the accounting contract and the function's own arguments. No accounting logic should live outside this function.
> 
> Rails owns the outer transaction and runs it at READ COMMITTED. The function does not issue COMMIT or ROLLBACK. The caller's flow is:
> 
> ```
> BEGIN ISOLATION LEVEL READ COMMITTED;
> SELECT post_bulk_payments(...);
> COMMIT;
> ```
> 
> Inside the function, use the following approach as separate SQL commands (variable declarations and argument extraction omitted):
> 
> ```
> -- Serialize spending by this sender using the REAL metadata row.
> SELECT id INTO STRICT v_payer_id
> FROM firm_descriptions
> WHERE uuid = p_payer_uuid
> FOR NO KEY UPDATE;
> 
> -- After acquiring the lock, read the derived balance in a separate command.
> SELECT balance_cents INTO STRICT v_balance
> FROM firms
> WHERE id = v_payer_id;
> 
> -- Reject if balance < full outgoing total.
> -- Reject if other accounting constraints fail.
> INSERT INTO payments (...)
> VALUES (...), (...), (...);
> ```
> 
> A failure must raise an error that rolls back the posting. Rails maps it to HTTP 422 after rollback. Do not return an ordinary error value after partial inserts and then commit those inserts.
> 
> This is a financial system, so we need strict atomicity. We expect the environment to be multi-tenant and need a granular lock. All application instances must coordinate on the same sender row. Every outgoing payment must go through this function and acquire that sender lock; do NOT acquire the recipient's sender lock. Incoming positive payments can proceed because they only increase the recipient's available funds.
> 
> We specifically need READ COMMITTED and lock-then-balance as separate commands; lock-and-sum in a single statement is unacceptable. The function must be VOLATILE, must reject an incompatible transaction isolation level, and must hold the sender lock until the caller commits or rolls back.
> 
> For the client, explicitly set up a runtime role that can add firms with valid initial opening funds, edit only firm names, and invoke this function, with the minimum read permissions needed for those operations. Everything else should be disallowed. Use column-level UPDATE(name) permission rather than table-wide UPDATE so IDs, UUIDs, and opening funds cannot be changed.
> 
> The posting function should use SECURITY DEFINER with a separate appropriate owner, a safe fixed search_path, qualified object references, and restricted EXECUTE permission. The runtime role must not be able to write payments directly or alter database objects.
> 
> Keep the PostgreSQL view and function in migrations and db/structure.sql so a fresh database can be recreated.
> 
> Do not use any other systems outside PG for accounting coordination - no mutexes, no Redis, nothing else. Full accounting logic lives inside PG.
> 
> In Rails, invoke the function with bound parameters; do not interpolate. Do everything within a single connection and transaction; do not use multiple model callbacks.
> 
> Full coverage with tests is required, with negative/positive off-by-one checks, all named failure scenarios, and the invariants above. You can produce specific database states if needed to reproduce errors. Use real PostgreSQL and independent connections for concurrency tests. Explicitly test all named positive edge cases, including fully identical transfers within the same batch.
> 
> When done, create some large-scale setup and benchmark it; then investigate the performance with EXPLAIN and walk me through the implementation you've done.

Installing Rails 8.1.4.1 so I can generate the clean baseline API project and initialize the repository. Waiting for the gem installation to finish.

Waiting for the Docker Compose image build and security/lint checks (rubocop, brakeman, bundler-audit) to finish so I can run final containerized verification, commit the implementation cleanly on top of the baseline commit, and walk you through the solution and EXPLAIN benchmark results.

RuboCop (32 files, 0 offenses), Brakeman (0 warnings), and bundler-audit (0 vulnerabilities) all passed. Still waiting for the initial docker compose build to finish downloading its Debian build packages; I will resume automatically once it completes.

# Prompt 2

> [comments](slashCommand;comments) let's audit the comments (including commented lines - remove not needed, like in seeds.rb); additionally, need you to explicitly clarify the guards across the code. Logic of guards is the following: service is producing the invariant as a shortcut, so the database is not even touched on bad requests; database is producing the safeguards to avoid the risks possibility.
> Also, on errors-as-doors ([errors-as-doors-cross-domain-2026-05-30.md](file;file:///Users/jabher/.codex/skills/errors-as-doors/references/errors-as-doors-cross-domain-2026-05-30.md) [SKILL.md](file;file:///Users/jabher/.codex/skills/errors-as-doors/SKILL.md) ) specifically, and on comments skill - put them both into the repository, too, so that they are clearly visible.

I have added both skills (skills/errors-as-doors/ with its cross-domain research consolidation and skills/comments/ with references/schools.md, registered via .agents/skills.json) into the repository and launched the critical-review pass required by /comments across every file and guard boundary; I will follow up with the full seating chart and guard audit as soon as the reviewer reports back.

All /comments cleanups, Two-Layer Guard clarifications (including the zero-DB self-payment shortcut in PayloadParser paired with PostgreSQL's post_bulk_payments safeguard), and local verification checks (29 runs, 751 assertions, RuboCop, Brakeman, bundler-audit) have passed; waiting a few seconds for the clean docker compose down -v && docker compose up -d --build verification to finish before committing and presenting the full audit and walkthrough.

Completed the /comments audit (including critical-review verification via subagent), clarified and tightened the Two-Layer Guard Architecture across code and SQL, and added both skills directly into the repository.

1. Skills Checked into the Repository

Both skills and their reference docs now live visibly at top-level skills/ and are registered via .agents/skills.json (and linked in README.md):

skills/errors-as-doors/SKILL.md + errors-as-doors-cross-domain-2026-05-30.md
skills/comments/SKILL.md + schools.md
2. Explicit Two-Layer Guard Architecture

Both prose preambles and runtime execution now enforce a clean division between shortcut guards and database safeguards:

Layer 1 — Service Shortcut Guard (Zero-DB Boundary): BulkPayments::PayloadParser
Validates UTF-8 & RFC 8259 JSON syntax, strict object/key allowlists, 1..1000 batch bounds, UUID syntax, exact USD-to-int4-cent arithmetic, non-blank descriptions, and payer_uuid != payee_uuid (reject_self_payment!) strictly in memory.
Bad requests return 422 errors-as-doors payloads immediately without leasing a connection, acquiring row locks, or touching PostgreSQL (verified by BulkPaymentsIntegrationTest).
Transaction Bridge: BulkPayments::Poster
Owns top-level BEGIN ISOLATION LEVEL READ COMMITTED (requires_new: false, joinable: false — no savepoints, sender lock held until commit), invokes public.post_bulk_payments with bound typed arrays (uuid[], int4[], text[]), and translates Layer 2 PostgreSQL exceptions into BulkPayments::Error doors (verified even when Layer 1 is bypassed in LedgerInvariantsAndSecurityTest).
Layer 2 — Database Safeguard Layer: CreateFinancialLedger & db/structure.sql
Even if Layer 1 is bypassed by direct SQL, future endpoints, or a service bug, PostgreSQL independently enforces:
public.post_bulk_payments (VOLATILE SECURITY DEFINER, owned by ledger_definer, SET search_path = pg_catalog, pg_temp): writable READ COMMITTED check, array/item bounds, self-payment check, sender-only FOR NO KEY UPDATE lock, separate-statement NUMERIC balance check on public.firms, and atomic multi-tuple INSERT ... VALUES.
Table CHECK & ON UPDATE/DELETE RESTRICT FOREIGN KEY constraints on firm_descriptions and payments.
Row & statement BEFORE UPDATE/DELETE/TRUNCATE immutability triggers (guard_payments_immutability, guard_firm_descriptions_immutability).
Least-privilege ledger_runtime role ACLs (INSERT(uuid, name, opening_balance_cents), column-level UPDATE(name), zero direct privileges on payments or DDL).
3. /comments Audit Summary
   Product

Financial-grade Rails 8.1 / Ruby 4.0 bulk-payment API backed by an append-only PostgreSQL 18 ledger.

Stance
Outside = PostgreSQL 18 MVCC snapshot/lock semantics (READ COMMITTED + FOR NO KEY UPDATE vs FK FOR KEY SHARE), pg_dump --no-owner --no-privileges, ledger_runtime column ACLs vs ActiveRecord timestamps, ActionDispatch parameter-parser middleware, Docker/PGDG/QEMU platform constraints, and the Two-Layer Guard architecture.
Code/SQL names already show = table/column definitions, GRANT/REVOKE targets, Rails config booleans, gem names, and route definitions.
Seating Highlights
Site	Verdict	Because
db/seeds.rb, cors.rb, inflections.rb	DELETE	Unused Rails generator boilerplate & commented-out MovieGenre / Rack::Cors / inflector code (cors.rb and inflections.rb removed; seeds.rb kept minimal for db:seed:replant).
config/application.rb, config/environments/*, puma.rb, ci.rb, locales/en.yml, bundler-audit.yml, Gemfile, Dockerfile, .gitignore, .dockerignore, .gitattributes	DELETE	Stripped ~160 lines of commented-out rails railties/options, tutorial essays, dummy CVE-THAT-DOES-NOT-APPLY, and # Ignore X restatements.
BulkPaymentsController	LOUDER	Sole canonical home for the Idempotency-Key out-of-scope pin + 2-step guard pipeline summary (removed duplicate Idempotency-Key note from PayloadParser and # POST /bulk_payments restatement).
BulkPayments::PayloadParser	LOUDER + REWRITE	Named Layer 1 — Service Shortcut Guard preamble and added reject_self_payment! so self-payments fail in memory without touching PG.
BulkPayments::Poster	LOUDER	Replaced inaccurate "exclusively in PG" wording and inline pseudo-SQL comment with the READ COMMITTED (requires_new: false, joinable: false) + Layer 2 bridge contract.
CreateFinancialLedger & db/structure.sql	DELETE + LOUDER	Deleted obvious SQL narration (-- 1. firm_descriptions, -- Reject if balance < total, REVOKE/GRANT restatements); elevated MVCC snapshot/locking laws and Layer 2 safeguard laws, then re-dumped db/structure.sql so function bodies match byte-for-byte.
FirmDescription, parameter_parsers.rb, ledger_security.rake, bin/docker-entrypoint	KEEP / LOUDER	Load-bearing outside platform pins (record_timestamps = false vs UPDATE(name) ACL, HTTP 400 vs 422 JSON parser intercept, pg_dump --no-owner --no-privileges, DB_ROLE=admin subprocess scoping).
config/environments/test.rb	MISS → KEEP	Added missing platform pin on maintain_test_schema = false (default true crashes under ledger_runtime due to revoked schema_migrations / DDL access).
4. Verification
   Fresh Docker Compose boot (down -v && up -d --build): PostgreSQL 18 (db) + Rails 8.1.4.1 / Ruby 4.0.9 Puma (web) healthy and serving POST /bulk_payments.
   Test suite (host & inside Docker container): 29 runs, 751 assertions, 0 failures, 0 errors, plus db:seed:replant green.
   Static & security checks: bin/rubocop (30 files, 0 offenses), bin/brakeman (0 warnings), bin/bundler-audit (0 vulnerabilities).

(Changes are left unstaged in the working tree on top of 518e458 so you can inspect git diff — let me know if you'd like me to commit them or walk through the EXPLAIN (ANALYZE, BUFFERS) benchmark findings next.)

# Prompt 3

> Replace the balance view with correlated sums, and replace the generated INSERT with one static statement that returns ids ordered by the source row number. just move the logic inside COALESCE(), like this (for + part): COALESCE((SELECT SUM(p_in.amount_cents::pg_catalog.numeric) FROM public.payments AS p_in WHERE p_in.payee_firm_id = fd.id), 0::pg_catalog.numeric).
> 
> Also, replace SELECT 'WITH inserted AS (INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES '...  - we need MERGE on that. specifically, the following pattern is needed, as it is canonical way to solve this problem since pg17: WITH inserted AS (MERGE INTO public.payments AS p USING (SELECT ... FROM pg_catalog.unnest(p_payee_uuids, p_amounts_cents, p_descriptions) WITH ORDINALITY -- decoupling result order from scan order since array_agg() has no ORDER BY
> AS u(...) JOIN public.firm_descriptions ...) AS src
> ON FALSE -- always add
> WHEN NOT MATCHED THEN INSERT (...) VALUES (...)
> ...
> 
> (also, reflect that in comments too, following the same methodology)

I have replaced public.firms with correlated COALESCE((SELECT SUM(...) ...), 0::pg_catalog.numeric) subqueries and replaced dynamic SQL generation in public.post_bulk_payments with the static PG 17+ WITH inserted AS (MERGE INTO public.payments ... ON FALSE WHEN NOT MATCHED THEN INSERT ... RETURNING p.id, src.ord) statement ordered by WITH ORDINALITY, re-dumped db/structure.sql, and verified all 30 runs, 755 assertions. Now waiting a few seconds for the 10k-firm / 1M-payment EXPLAIN (ANALYZE, BUFFERS) benchmark run to finish so we can verify the updated query plans and Docker container image.

Waiting for the /comments SQL pin reviewer subagent to finish its plan check; I will resume automatically once its message arrives.

Rebuilding the web container image and running the containerized test suite against the updated db/structure.sql; will wrap up in a few seconds once the run finishes.

Replaced both the public.firms view and the public.post_bulk_payments batch insertion with the correlated-sum and static PG 17+ MERGE ... ON FALSE patterns, audited the comments with the critical-review subagent under skills/comments/SKILL.md, synced db/structure.sql, and re-verified the test suite + 1M-row EXPLAIN (ANALYZE, BUFFERS) benchmark.

1. Correlated Sums in public.firms

Updated CreateFinancialLedger (and db/structure.sql):

sql
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
2. Static MERGE ... ON FALSE ... RETURNING Ordered by Source Ordinality

Replaced dynamic string generation (v_insert_sql / EXECUTE) in CreateFinancialLedger (and db/structure.sql) with one static, plan-cached statement:

sql
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
Why this matters in practice (caught immediately by tests): On multi-payee batches, PostgreSQL's Hash Join in USING (...) AS src emits rows in hash/table-scan order rather than u.ord order — meaning even generated p.id sequence values are allocated in join order rather than request order. Passing src.ord out through MERGE ... RETURNING p.id, src.ord and aggregating with array_agg(inserted.id ORDER BY inserted.ord) guarantees payment_ids always matches the caller's exact request index order (explicitly verified by the interleaved-payee regression test in BulkPaymentsIntegrationTest).
3. Updated EXPLAIN (ANALYZE, BUFFERS) & Benchmark Results (10k Firms, 1M Payments)

From script/benchmark_and_explain.rb:

Single-firm derived balance (SELECT balance_cents FROM public.firms WHERE id = $1):
Typical firm (~200 payments): Index Scan on firm_descriptions_pkey + two SubPlan Index Only Scans (Heap Fetches: 0, 11 shared hits) in 0.037 ms (faster than the previous Nested Loop Left Join GroupAggregate at 0.065 ms).
Hot whale firm (~50,000 payments): two SubPlan Index Only Scans (Heap Fetches: 0, 189 shared hits) in 5.22 ms.
Static MERGE ... ON FALSE ... RETURNING (100-item batch):
Merge on payments (Tuples: inserted=100) -> CTE Scan on inserted -> Sort (Sort Key: inserted.ord, Memory: 28kB) -> Aggregate in 1.90 ms (3.26 ms total inside post_bulk_payments including FK triggers, sender lock, balance read, and validation).
End-to-end throughput:
batch_size=1: p50 1.91 ms, 474.8 batches/s
batch_size=100: p50 4.08 ms, 24,035 payments/s
batch_size=1000: p50 21.92 ms, 43,400 payments/s
Global conservation invariant: opening = 10000000000000 == derived = 10000000000000.
Verification: 30 runs, 755 assertions, 0 failures, 0 errors (both host and inside rebuilt Docker web container) and bin/rubocop (30 files, 0 offenses).

# Prompt 4

> [tests-review](slashCommand;tests-review) put this skill in the repo, then review the tests; after review is done, apply the appropriate fixes. translate the domain-specific guidelines to idiomatic Ruby setup (there's no need to follow vitest-specific  guidelines). only follow generalized, conceptual QA approach represented in that skill

Tests-review: test/

Added the tests-review skill to skills/tests-review/SKILL.md and skills/tests-review/references/schools.md (indexed via .agents/skills.json and documented in README.md), audited the suite under its generalized QA laws translated to idiomatic Ruby/Minitest, and applied all fixes.

Product

Single-endpoint (POST /bulk_payments) append-only financial ledger API in Rails 8.1 backed by PostgreSQL 18 SECURITY DEFINER accounting, correlated-sum NUMERIC balances, and sender-only FOR NO KEY UPDATE concurrency.

Catalog
Metric	Before	After
Test files (+ test_helper.rb)	3	3
Cases (test "...")	30 (19 + 8 + 3)	21 (12 + 6 + 3)
Runtime Minitest assertions	755	42
Spray index (assertions / cases)	25.17	2.00
Fail-fast .each { assert_* } loops	11	0
Bare assert_raises dropping error/constraint values	9	0
Monkey-patched collaborators (define_singleton_method)	2	0
Unused/test-only production parameters	1 (Poster.call(..., connection:))	0
Stance
Natural layer: Rack HTTP (ActionDispatch::IntegrationTest through BulkPaymentsController, BulkPayments::PayloadParser, BulkPayments::Poster, and live PostgreSQL 18 as ledger_runtime) for wire and boundary behavior; direct ledger_runtime / ledger_admin PostgreSQL sessions (ActiveSupport::TestCase) for Layer 2 DB safeguards, ACLs, triggers, and multi-session lock schedules.
Visual: No (JSON-only API; wire fixtures are CHARACTERIZE inside the logic cup).
Dialect: Ruby 4.0 / Minitest (Rails 8.1).
Seating (Fused KEEPs)
#	Keep	Was	Failure if untested	Unique because
1	Specification wire payload & multi-payee commit (CHARACTERIZE)	1	Canonical JSON wire contract (payer_firm_uuid, payments_count, payment_ids) or multi-payee balance math drifts	Locks exact specification JSON payload end-to-end
2	MERGE ... WITH ORDINALITY source-order preservation	1	MERGE hash/index join against firm_descriptions returns payment_ids in ID-allocation order instead of request index order	Interleaves early/late payee IDs; identical-leg tests cannot detect join reordering
3	Intra-batch & Idempotency-Key non-deduplication	2	DISTINCT collapses identical items in a batch, or middleware deduplicates repeated Idempotency-Key posts	Covers both intra-batch and inter-request append-only behavior
4	Batch cardinality thresholds (0, 1, 1000, 1001)	2	Off-by-one < vs <= at 1..1000, or bind/escaping truncation at 1,000 items	Hits all four off-by-one edges [0, 1, 1000, 1001] with 0 SQL on 0/1001
5	Balance sufficiency (0 empty-history, -1 cent rollback, exact 0 drain)	2	Missing COALESCE on empty sums returns NULL, < vs <= rejects exact-balance spend, or leg 0 persists when leg 1 overflows balance	Exercises stateful firms.balance_cents comparison and multi-leg rollback
6	Per-payment int4 ceiling (21474836.47 vs .48) & NUMERIC totals (> int4)	2	>= 2^31 cent item crashes PG int4[] bind with 500, or NUMERIC view/gross sum overflows int4 at 6,442,450,941 cents	Crosses 2^31 - 1 boundary in both directions (rejected leg vs accepted 3x sum)
7	Exact USD string-to-cents conversion & prohibited amount table	2	IEEE-754 float drift ("0.29" -> 28), leading zeros ("01"), zero ("0.00"), >2 decimals, signs, exponents, or non-strings pass	Pairs valid decimal/float-trap formats with 33-row 0-SQL rejection collector
8	JSON wire framing & strict request/item envelope table	2	Invalid UTF-8 / malformed JSON returns framework 400/500, or unknown/missing keys silently pass	Exercises raw wire bytes & structural JSON shape across 20 rows (0 SQL)
9	Party UUID syntax & self-payment shortcuts (Layer 1) + unknown firm rollback (Layer 2)	2	Bad UUIDs or mixed-case self-payments hit PG locks, or unknown payee at index 1 leaves leg 0 persisted	Verifies both Layer 1 (0 SQL via sql.active_record) and Layer 2 rollback
10	Payment description validation (type, Unicode whitespace, NUL byte)	1	Blank Unicode whitespace passes, or embedded \u0000 hits PG TEXT and triggers an unhandled 500	Isolates parse_description! edge cases across 10 rows (0 SQL)
11	Sole-endpoint routing surface (POST /bulk_payments only)	1	Resource routing exposes extra HTTP verbs/paths	Full dump equality on Rails.application.routes
12	SQL/stack-trace redaction on unexpected 500 DB failure	1	Unhandled ActiveRecord::StatementInvalid leaks SQL or PG internals to HTTP clients	Triggers a real unmapped PG::InsufficientPrivilege fault without stubbing
13	ledger_runtime least-privilege contract (allowed vs 14 forbidden SQL ops)	2	Over-broad grants allow immutable column edits, direct payments access, firm deletion, or DDL	Pairs allowed onboarding/rename with 14-row SQLSTATE collector
14	Table CHECK, UNIQUE, and RESTRICT FOREIGN KEY constraints	1	Schema constraint regression allows negative opening funds, duplicate UUIDs, <= 0 amounts, self-rows, or dangling FKs	Directly tests all 9 table constraints on firm_descriptions and payments
15	Privileged immutability triggers (UPDATE/DELETE/TRUNCATE)	1	Admin/superuser script mutates or truncates payments or immutable firm_descriptions columns	Runs 9 privileged mutations as ledger_admin, checking ["55000", detail]
16	post_bulk_payments SECURITY DEFINER metadata & READ COMMITTED guard	1	Search-path hijack, wrong owner, or REPEATABLE READ/SERIALIZABLE/READ ONLY snapshot anomaly	Checks pg_proc catalog attributes + transaction mode SQLSTATEs
17	Layer 2 SQL argument safeguards & Poster door translation on bypass	2	Direct SQL / internal callers pass NULLs, 2D/mismatched/1001 arrays, or Poster drops safeguard DETAIL codes	14 direct SQL rows + 4 bypassed ParsedBatch translations
18	Multi-party double-entry conservation & trigger purity	1	Correlated view sign/join error or hidden trigger breaks SUM(balances) == SUM(opening)	5-firm transfer graph cross-checked against raw payments and pg_trigger
19	Concurrent multi-leg sender serialization (FOR NO KEY UPDATE)	1	Race condition overdrafts sender or commits partial multi-leg batches under contention	10 independent PG sessions racing 2-leg batches (3 commit, 7 fail)
20	READ COMMITTED separate-statement lock-then-balance visibility	1	Combining lock + sum in one SQL query reads pre-lock snapshot and falsely rejects funded sender	Deterministic 3-session lock-wait + concurrent incoming top-up schedule
21	Deadlock-free mutual transfers (A -> B while B -> A uncommitted)	1	Locking recipient rows deadlocks concurrent cross-transfers	Deterministic 2-session cross-transfer holding uncommitted sender lock

Fused count: 21 KEEPs (42 assertions). Visual frames: 0. Merged: 9 split cases fused into workflow lifecycle KEEPs.

Fusion Notes
Fair fuses applied:
Intra-batch identical items + repeated Idempotency-Key requests -> Keep 3 (2 -> 1).
Batch cardinality 0/1001 rejected + 1/1000 accepted -> Keep 4 (2 -> 1).
Balance 1 cent short rollback + exact balance drain to 0 (+ zero-opening empty-history spend) -> Keep 5 (2 -> 1).
Single-leg 21474836.48 rejected + 21474836.47 accepted and summed 3x above int4 -> Keep 6 (2 -> 1).
Valid USD decimal strings + 33-row prohibited amount table -> Keep 7 (2 -> 1).
Malformed JSON/UTF-8 + invalid root/item JSON object shapes -> Keep 8 (2 -> 1).
Layer 1 UUID syntax / self-payment shortcuts + Layer 2 unknown firm rollback -> Keep 9 (2 -> 1).
ledger_runtime allowed operations + forbidden ACL/DDL table -> Keep 13 (2 -> 1).
Direct SQL Layer 2 argument safeguards + Poster safeguard door translation -> Keep 17 (2 -> 1).
Cheats refused:
Kept sole-endpoint route check (Keep 11) separate from HTTP 500 SQL-redaction barrier (Keep 12): config/routes.rb drift and ApplicationController#render_unexpected_error redaction are unrelated incidents.
Kept the 3 concurrency cases (Keeps 19, 20, 21) separate: overdraft race safety, post-lock READ COMMITTED fresh-snapshot liveness, and cross-party deadlock freedom fail for opposite reasons in SQL locking.
Key QA Fixes Applied
1. Oracle Collapse & Non-Aborting Row Collectors (test/test_helper.rb)
   Replaced 11 fail-fast .each { assert_* } loops (which previously aborted on row 0 and inflated runtime assertions to 755) with LedgerTestHelpers#assert_table: evaluates every row via Enumerable#filter_map, collects all [row_index, label, expected, actual] mismatches, and asserts assert_empty failures, failures.join("\n") once per table.
   Collapsed multi-line field-by-field assertion chains into single whole-hash assert_equal(expected_state, actual_state) checks per workflow phase in BulkPaymentsIntegrationTest, LedgerInvariantsAndSecurityTest, and ConcurrencyAndLockingTest.
2. Exact Error & Constraint Value Assertions (LedgerTestHelpers#capture_pg_error)
   Eliminated all 9 bare assert_raises blocks that dropped the exception value. Every DB error check now asserts [sqlstate, constraint_name_or_detail] (or exact sqlstate for ACL checks).
   Bug caught in the old test suite during conversion: the previous UpdateIdDenied check wrote UPDATE public.firm_descriptions OVERRIDING SYSTEM VALUE SET id = 999 (invalid PostgreSQL syntax — OVERRIDING SYSTEM VALUE is INSERT-only) and masked the 42601 PG::SyntaxError inside assert_includes [PG::InsufficientPrivilege, PG::GeneratedAlways, PG::SyntaxError]. Fixed to valid UPDATE public.firm_descriptions SET id = 999 WHERE id = $1, asserting exact SQLSTATE "428C9" (generated_always).
3. Natural Layer & Zero Test-Only Production Surface
   Removed the unused connection: parameter seam from BulkPayments::Poster.call (and updated script/benchmark_and_explain.rb to rely on connection_pool.with_connection).
   Eliminated both BulkPayments::Poster.define_singleton_method(:call) monkey-patches in BulkPaymentsIntegrationTest:
   Layer 1 zero-DB shortcut behavior is now proven via LedgerTestHelpers#count_sql_queries (sql_queries: 0 on sql.active_record) across all Layer 1 rejection tables (malformed JSON, envelope shape, batch bounds 0/1001, int4 ceiling, invalid amounts, invalid descriptions, invalid UUIDs, and self-payments).
   HTTP 500 internal-fault redaction (Keep 12, bulk_payments_integration_test.rb) now triggers a real unmapped PostgreSQL PG::InsufficientPrivilege via temporary REVOKE EXECUTE on post_bulk_payments (restored in ensure), testing genuine ActiveRecord::StatementInvalid SQL redaction and logging.
4. Misses Seated in Freed Headroom
   Empty-history zero-opening sender (opening_balance_cents = 0 with zero incoming/outgoing rows, exercising COALESCE(NULL, 0) - COALESCE(NULL, 0) = 0) attempting a \$0.01 transfer (bulk_payments_integration_test.rb).
   Case-folded self-payment shortcut (PAYER_UUID.upcase -> PAYER_UUID.downcase) rejected at Layer 1 with 0 SQL queries (bulk_payments_integration_test.rb).
   Direct public.payments & public.firm_descriptions table constraints: chk_payments_positive_amount, chk_payments_no_self_transfer, chk_payments_description_not_blank, fk_payments_payer_firm, fk_payments_payee_firm, and idx_firm_descriptions_uuid_covering verified by exact [sqlstate, constraint_name] (ledger_invariants_and_security_test.rb).
   Privileged TRUNCATE public.firm_descriptions & UPDATE uuid/created_at triggers verified by ["55000", "firm_immutable"] and ["55000", "firm_immutable_columns"] (ledger_invariants_and_security_test.rb).
   Layer 2 1001-element SQL array guard & all 4 Poster safeguard door translations (self_payment, invalid_batch_size, invalid_amount, blank_description) (ledger_invariants_and_security_test.rb).
   Multi-leg atomic rollback under FOR NO KEY UPDATE contention ([2_000, 1_000] 2-leg racing batches in concurrency_and_locking_test.rb).
   CI
   Logic cup (default, ~1.0s in Docker): docker compose run --rm -e RAILS_ENV=test web ./bin/rails test
   Large / scale & query-plan quarantine (10k firms, 1M payments, EXPLAIN (ANALYZE, BUFFERS)): docker compose run --rm -e DB_ROLE=admin web ./bin/rails runner script/benchmark_and_explain.rb