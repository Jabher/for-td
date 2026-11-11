---
name: comments
description: >
  Write or review code comments, file preambles, and JSDoc. Use when
  the user says "comment this", "too many comments", "add jsdoc",
  "// why", "comment style", or /comments. Complements
  production-writing (register and placement of survivors) and
  typescript-smells (`as` / proofs): this one is whether a comment
  may exist. Not for READMEs, test-suite seating, or /review.
---

# Comments

**WIP.** This skill is still being calibrated. Findings are hypotheses, not a patch list: **judge and discuss before applying.** After every use (review or rewrite), run a **critical review agent** on the proposed changes and wait for that discussion before landing them. Do not silently apply skill output.

A comment exists only if it names a constraint **this code cannot show**, because the constraint lives **outside this code**. Restating the next line is noise. Explaining a confusing local block is a rewrite ticket. Explaining the platform, the other file, the wire format, the import cycle — that is the job.

Stance and rejected alternatives: [references/schools.md](references/schools.md). Do not re-litigate the schools unless the user challenges the stance.

Default **write** mode: follow the laws; do not emit DELETE comments; if the only way to ship the line is a comment about *this* code, rewrite first. Default **review** mode (when asked to review / audit comments): seating chart, do not edit. **Apply** only when the user says to cut / rework / implement.

## The three-way

Ask, in order:

1. **Recoverable?** If a future reader recovers the fact from names, types, and the next few lines, the comment is obvious. **DELETE.**
2. **Local?** If renaming, extracting, or restructuring *this* code would make the comment unnecessary, the code is the smell. **REWRITE** the code, then delete the comment.
3. **Outside?** If the fact still needs saying after a perfect rewrite — because it lives in the platform, the architecture, or another file — **KEEP**, and make it loud.

The operational test for (2) vs (3): **after a rewrite that makes this code as clear as it can be, would a reader still need the sentence?** If no → REWRITE. If yes, because the platform / the other module / the protocol requires it → KEEP.

## Laws

**Obvious.** Form: *the names already say this; deleting the comment loses nothing.* `// increment the counter` above `count++`. `/** Gets the user name */` on `getUserName`. `/** @param user The user */`. A labeled restatement of a type. DELETE.

**Local smell.** Form: *this block is confusing; the comment is the apology.* A 12-line stretch that needs a paragraph to be followed is a missing name, a missing extract, or a missing inversion — not a documentation problem. Name the phase (`registerEmpty`, not `// first register then assign`). Invert the boolean. Pull the door. Then the comment has nothing left to do.

**Outside.** Form: *the constraint is not in this file, and a correct-looking edit here would break it.* These comments are the product. Write them as named laws, pins, or file preambles — not as whispers.

KEEP kinds — the fact still needs saying after a perfect local rewrite:

- **File preamble** — the file's place in the architecture, the law it defends, the platform it sits on. A reader of preambles understands the system; body comments are footnotes.
- **Platform pin** — the line is simple; the world is not. Cite the dependency at `file:line` or spec § (`set` switches on exact `value.constructor`; a Node `Buffer` is `instanceof Uint8Array` and still throws).
- **Load-bearing math** — show the derivation (`63^14 ≈ 2^84 — fits with margin`), never "large enough".
- **Cross-file pointer** — `see preamble, CHANGE ONLY`. Do not re-teach the rule at every site.
- **Field pin the type cannot show** — units, lifecycle, routing consequence (`NOT forwarded`; `called once, at construction`; `test hook — reset only between tests`).
- **Named law** — a correct-looking "fix" will be proposed. Name the rule and the failure each alternative causes.
- **Import / TDZ / bundler facts** — this module is a runtime leaf; if its closure reaches X, evaluation hits TDZ. Pure module — zero imports of Y.

**Types, not JSDoc.** TypeScript already publishes the signature. Do not add `@param`, `@returns`, `@throws`, or a one-line `/** Does X */` that paraphrases the name. A `/** */` block on a function is legal only when its *body* is KEEP content about the world — the delimiters are incidental; the `@param` tags are not.

**Loud KEEP.** Outside facts that attract "fixes" get a name and a failure mode, not a shy aside. Timid KEEP → **LOUDER**.

| Fair | Cheat |
|---|---|
| Dep `set` switches on exact ctor; a Node `Buffer` fails it | `// increment` / `// check if admin` |
| Library cleanup rerolls this id if `local=false` (`file:line`) | `/** @param owner The owner */` |
| This origin must forward or later writes silently drop | Comment explaining a poorly named 12-line block |
| `63^14 ≈ 2^84 — fits with margin` | `/** Returns the max clock */` on `getMaxClock` |
| Pure module — zero imports of the layer below | File preamble that restates the export list |
| `see preamble, CHANGE ONLY` | Body comment re-teaching the preamble |
| Named law + the failure each alternative causes | `// Helper to format the date` above `formatDate` |
| Labeled `// ── phase 2: apply ──` in a long file | Unlabeled `// --------` |

Machine directives (`eslint-disable`, `@ts-expect-error`) are not comments. Their *reason* is: KEEP iff it names the outside constraint (the runtime has no `Symbol.metadata`; this lint cannot see `#private` accessors); `// lint is wrong` is DELETE.

## Verdicts

| Verdict | Means |
|---|---|
| **DELETE** | Obvious. Restates code, types, or the name. |
| **REWRITE** | Local non-obvious. Restructure / rename / extract; the comment does not survive. |
| **KEEP** | Outside non-obvious. Architecture, platform, other files. Untouchable. |
| **LOUDER** | KEEP content whispered. Rewrite as a named law, preamble, or pin; do not delete. |

A generating rule in the preamble plus body pointers is one KEEP, not N comments.

## Procedure

1. **Catalog.** Count `//`, `/* */`, `/** */`, `@param`/`@returns`, file preambles, labeled section headers. Note JSDoc-on-functions vs field pins vs body pins.

2. **Seat.** For each comment (or generating-rule cluster), run the three-way. Excuse form for KEEP: *lives in … (platform / other file / protocol); a rewrite here would not show it; a "fix" would …* Excuse form for REWRITE: *the code next to it is the smell; name/extract/invert = …; then the comment dies.* Excuse form for DELETE: *names and types already say this.*

3. **Misses.** Outside constraints the file *relies on* and never names (a library cleanup, a sister-module contract, an import-cycle leaf). They sit down as new KEEP / LOUDER. Do not invent comments for obvious code to fill space.

4. **Apply** (only if asked). DELETE and LOUDER first (prose-only). REWRITE is a code change — do not "clarify" a local smell with a longer comment. Do not touch unrelated dirty production. Do not add JSDoc to make a KEEP look official.

## Output (review)

```
# Comments: <package or tree>

## Product
<one sentence: what this code is>

## Catalog
<// / /** / @param / preambles / section headers>

## Stance
Outside = <platform / architecture / sister modules this tree sits on>.
Types already show <signatures / field shapes>.

## Seating
| # | Site | Verdict | Because |
|---|---|---|---|
| 1 | store.ts:29 exact-ctor pin | KEEP | dep switches on constructor; Buffer is instanceof |
| 2 | foo.ts:12 "// increment" | DELETE | names already say it |
| 3 | bar.ts:40 phase comment | REWRITE | extract registerEmpty; comment dies |

Deleted: N. Rewritten (code): R. Kept: K. Louder: L.

## Fair notes
Fair keeps (platform / architecture / other files). Cheats refused (JSDoc-as-types, apology comments, unlabeled dividers).

## Misses
<outside constraints the file relies on and never names>
```

Do not apply in the same turn as the review unless the user said to.

## What this is not

- Not `production-writing`. That skill is the register and placement of prose that *survived* this test (preamble vs body vs `.md`, citation scrub, public docs). This skill is the existence test. Run this first.
- Not `typescript-smells`. That one is `as` / proofs. `@param` / JSDoc-as-API is this skill.
- Not a correctness review of a diff (`/review`).
- Not over-engineering of production (`/ponytail-review`). A REWRITE that extracts a name so the comment can die is the *smaller* surface, not a new abstraction.
- Not a quota on comment volume. Empty obvious-headroom is success. A starved platform pin is a miss.
