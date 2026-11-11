---
name: tests-review
description: >
  Review a test suite's seating. Use when the user says "review the
  tests", "test architecture", "too many tests", "excuse to exist",
  "fuse tests", "visual vs logic tests", or /tests-review, including a
  Rust or Vitest suite. Complements ponytail-review (product
  complexity) and /review (correctness of a diff). Not for writing a
  first test, taking screenshots as the task, reviewing a production
  diff, or a Rust type review (rust-guidelines).
---

# Tests-review

A test exists only if it names a **unique production failure** an operator, model, or replica would notice. Coverage, "documents the class", and field-by-field assertion spray are not excuses. A red that is not a unique failure trains the team to ignore reds.

Uniqueness is the floor. A count the user names is a **ceiling, not a quota**. Fusion that drops the count is the better suite. Empty headroom is success. Filling a ceiling by un-fusing a lifecycle, or by packing unrelated concepts into one case, is cheating.

Default mode is **review** (seating chart, do not edit). **Apply** only when the user says to cut / rework / implement.

Stance, citations, rejected alternatives: [references/schools.md](references/schools.md). Do not re-litigate the schools unless the user challenges the stance.

Read **Dialects** for the suite in front of you. JavaScript, then Vitest when the runner is Vitest. Rust when the crate is Rust. The laws below do not change.

## Laws

**Excuse.** Form: *if this broke, X happens to Y; nothing else catches it because Z.* Unique is empty → DELETE. Unique is "the code does what the code does" → DELETE.

**Fusion.** One workflow is one test. A fused test is one story a reviewer can hold: setup, the walk, one oracle per *phase*. Phases of the same lifecycle belong together. Two questions you would debug as different incidents stay two tests. A parameterized table of isomorphic rows counts as one test.

| Fair | Cheat |
|---|---|
| Login park + exchange + logout | Path sandbox + vote lattice |
| Parser table of isomorphic rows | UI primary verb + compact fold |
| Control loop: mint, tools, fail-seal | Handshake + executor timeout |
| Spawn: env, cwd, child death | Auth grant + write-budget |
| Enter fires + empty does not | One assertion of the whole process |

Sequential phases with a **named** oracle per phase (`parked`, then `secrets.json`, then `adopted.id`) is fusion of a workflow. One assertion that mixes those phases hides which step died — also cheating.

**Visual split.** Logic asserts decisions. Visual *approves* appearance. Never mix in one file. The visual oracle is a stable structural dump (bands, roles, draft, annotation, picker). Painted-string search is neither a decision nor an approval. A protocol fixture the other side locks is CHARACTERIZE and stays with logic. Logic CI must not import the paint stack.

**Oracle collapse.** The oracle is one structured value. Field-spray dies on the first assertion and hides the rest — a diagnostic defect. Survivors still collapse; fusion without collapse is a long test that fails on field one.

Prefer one equality of the whole value. A named row collector that reports every miss, then one assertion that the collector is empty, when the table is long. A file snapshot of a structural dump after that. Equality of a primitive or of identity stays a single-value check. Do not collapse when the field *is* the spec (secrets must not appear in config; `closed` before vs after).

**Natural layer.** Test at the layer the product *is*. A daemon + CRDT is tested with a live daemon and real document, not an isolated orchestrator behind a seam invented for the test. Mock the network. Do not extract a seam so a test can stub time, paint, or the replica. Neighboring tests failing together is acceptable (Chicago). Isolating the product from its substrate recreates test-only surface (London as backbone — rejected; see schools).

**Honeycomb edges, not slices.** Hit the component's edges. Implementation-detail tests only for isolated combinatorial guts (lattice, pair-safety, path-escape). Do not grow 20 provider copies of one adopt. Integrated tests whose pass/fail depends on another system: rewrite onto an owned server, or quarantine as Large.

**Property collapse.** Example farms are accidental quality. One property + 1–2 named regressions, not 40 copies of "throws HTTP status".

**Size is CI, not taxonomy.** Smallest possible test that still hits the natural layer. Default job is the logic cup. Visual is a second job. Large (second process, real socket, `lsof`) is one fused smoke, quarantined, not the suite.

**No test-only production.** Do not keep extra exports, helpers, or modules so tests can poke internals. If the suite requires a shadow path, that is a different cut: delete the shadow, rewrite tests onto the live consumer, or delete the tests. This skill seats *behaviors*, not APIs.

## Verdicts

| Verdict | Means |
|---|---|
| **KEEP** | Unique failure; one case after fusion |
| **FUSE** | Same workflow, currently split; name the surviving KEEP |
| **MOVE-VISUAL** | Appearance; goes to the visual job |
| **CHARACTERIZE** | Golden of a dump the host must keep stable (strategy card, wire vocabulary). File snapshot or a byte fixture. Sits with logic |
| **DELETE** | No unique failure: happy-path tautology, type-tag check, help-string, source-grep, farm copy, anemic graph dump |

A parameterized table is one KEEP. The runner's expanded count is not the seating count.

## Procedure

1. **Dialect.** JavaScript, then Vitest if that is the runner. Rust if the suite is Rust. Count that dialect's assertions. A catalog that counts another dialect's tokens and records zero has not looked at the suite.

2. **Catalog.** Files, cases, assertion count, spray index = assertions / cases. Name the product in one sentence (daemon, library, TUI, …).

3. **Cluster by workflow**, not by file. A feature split across three files is still one story. Two executions of one body are one story.

4. **Seat.** For each cluster, write KEEP rows in excuse form. Fuse split workflows. Move paint. Delete farms. Do not invent a numeric target. If the user named a ceiling, stop adding when unique failures are seated; leftover ceiling stays empty.

5. **Misses.** Name unique production failures the current suite never hits. They sit down in empty headroom. They do not displace a KEEP unless the user named a *hard* ceiling.

6. **Oracle card** on survivors only. Worst spray files first.

7. **CI shape.** Default command is logic. Visual is opt-in / TUI-touching. Large is quarantined.

8. **Apply** (only if asked). Disjoint file ownership if paralleling. Do not add test-only exports. Do not touch unrelated dirty production. Fusion + collapse together. Visual files live outside the logic job (whitelist include, no exclude-list rot).

## Output (review)

```
# Tests-review: <package or tree>

## Product
<one sentence: what the suite is for>

## Catalog
<files / cases / assertion counts / spray, using the dialect's tokens>

## Stance
Natural layer = <…>. Cup = <the few wiring tests>. Visual = <yes/no>. Dialect = <js | vitest | rust>.

## Seating (fused KEEPs)
| # | Keep | Was | Failure if untested | Unique because |
|---|---|---:|---|---|
| 1 | … | n | … | … |

Fused count: N. Visual frames: M. Deleted/merged: ~K.

## Fusion notes
Fair fuses (workflow → one case). Cheats refused.

## Visual
<scenarios, oracle shape, job include>

## Oracle collapse
<worst spray; 2–3 before/after oracles>

## Misses (headroom)
<named unique failures not yet seated>

## CI
<logic command / visual command / Large quarantine>
```

Do not apply in the same turn as the review unless the user said to.

## Dialects

Tokens and watched misses. The laws are already in force.

### JavaScript

| Law | Shape |
|---|---|
| Case | `it` / `test`. A `describe` does not seat |
| Table | One function, many `{ in, out }` rows = 1 KEEP |
| Spray | Successive `expect` or `node:assert` calls. They stop at the first miss |
| Collapse | `toEqual` / `assert.deepEqual` of one value. `toBe` / `assert.equal` for a primitive or for identity |
| Paint | `toContain`, `includes`, or `toMatch` on a painted string |
| Error | Assert the value. `toBeInstanceOf`, and a throw check that drops the value, are DELETE |
| Test-only | An `export` added so a test can import it. A `*Deps` bag. `resetXForTests` |
| Shadow | A second entry point the product never calls (`regenerateMessages` beside `complete()`) |

### Vitest

On top of JavaScript.

- `it.each` / `test.each` is the row table.
- Collapse order: `toEqual` → `toMatchObject` → `toMatchInlineSnapshot` → `toMatchFileSnapshot`.
- `toHaveLength` plus `arr[0].x` plus `arr[1].x` collapses to `toEqual([...])`.
- Logic and visual are two projects. The logic job's `include` is a whitelist. An exclude list rots. Visual is opt-in.
- `vi.mock` of the filesystem, the clock, paint, or the replica is the seam **Natural layer** forbids. Mock the network.
- A file that imports the paint stack is visual, including when every assertion is `expect`.

### Rust

`#[test]` is a case. `rstest` is the row table.

| Law | Shape |
|---|---|
| Spray | `assert_eq!`, `assert!`, `assert_ne!`. They abort on the first miss. Counting `expect(` records zero |
| Collapse | `assert_eq!` of one value. A `failures` vec that names every row, then one `assert!(failures.is_empty(), …)`. `insta` for a file snapshot. Do not ask this dialect for `toMatchObject` |
| Paint | `assert!(s.contains(…))` and `format!("{x:?}").contains(…)`. A glyph search |
| Wire | `assert_eq!` of the bytes the other process locks. CHARACTERIZE. It stays in the logic cup. Do not open a screenshot job to hold it |
| Error | `is_ok()`, `is_err()`, `is_some()`, `is_none()` without the value are DELETE. So is `matches!` that drops the actual. `assert_eq!` the value |
| Test-only | `#[cfg(test)]` on a method, or a field widened so a test can poke it |
| Layer | `tests/*.rs` that `use` the public door. An in-module test is for a private lattice. The integration `use` failing to compile is the export check |
| Large | `#[ignore]` for a timing median and for a PTY or a second process. A timing assert in the default `cargo test` flakes the logic cup |
| Env | Spawn the child with the variable already set. `std::env::set_var` in the test process is the wrong door |

Watched: `include!` of one body from `#[cfg(test)]` and from `tests/` runs the oracle twice. A pasted copy is two sources of that body. `cargo test` counts both executions.

## What this is not

- Not a coverage gate. Not a quota.
- Not a correctness review of a diff (`/review`).
- Not over-engineering of production (`/ponytail-review`).
- Not a Rust type review (`rust-guidelines`). That skill points here for seating.
