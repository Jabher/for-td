---
name: errors-as-doors
description: "Design educational error / rejection surfaces — validation, diagnostics, MCP tool errors, \"not allowed here\" logic — that teach and route instead of banning. Use when writing or reworking any boundary rejection a human or AI agent will consume: validation schemas, error messages, an `invariant`/throw guard at an input boundary, MCP tool-call error responses, error codes, or a \"this property/action isn't settable here\" redirect. Covers reject-vs-translate (Applicability tiers), collect-all-vs-fail-fast with phase-split transactions, semantic error-code inventories, dual-surface explainers, and follow-rate telemetry. Trigger silently when about to add a terse throw an agent or user will hit, or when designing how a constraint routes the caller to the proper subsystem."
license: MIT
---

# Errors as Doors

Every boundary rejection is a **door**: fact → reason → action. It names *what* collided, *why* (which subsystem owns the concern), and the *action* (the proper channel to use instead). A rejection with no next action is dead weight — the clinical-alert finding is blunt: an alert without an alternative is overridden ~100% of the time.

Our consumers are **two structurally different callers**: AI agents (via MCP) and humans (via studio UI). They are not the same and sometimes want opposite designs — that asymmetry runs through every rule below.

Distilled from an 8-domain cross-industry swarm (2026-05-30): compiler diagnostics, API developer-experience, linters/autofix, clinical decision support, LLM tool-use recovery, HCI error theory, form/a11y validation, authorization-denial explanation. Full evidence + citations: [research and citations](references/errors-as-doors-cross-domain-2026-05-30.md).

## When this applies / doesn't

**Applies** to any *boundary* rejection — input arriving from an agent or human: validation, error messages, MCP tool-call errors, error codes, "not settable here" redirects, an `invariant`/throw guarding user/agent input.

**Does not apply** to internal asserts — see Rule 0, which is the load-bearing distinction.

---

## Rule 0 — Assert internally, validate at the boundary

The same check is two different things depending on who trips it:

- **Internal caller** trips it → it's a **bug**. Throw loud, fail-fast. An invariant violation from your own code should be impossible-by-construction; crashing is correct.
- **Boundary input** (agent/human) trips it → it's a **teaching moment**. Collect, explain, route. Never crash on bad input you invited.

> Most "rude error" smells are an **assert sitting where a validator belongs** — a check authored for internal safety that became the place external input lands. Split it: keep a thin internal assert, add a boundary validator in front (Rules 1–4).

---

## Rule 1 — Reject vs translate: classify by information loss

Three tiers (the rustc/Clippy `Applicability` taxonomy — same enum shipped in two compilers):

| Tier | When | Behavior |
|---|---|---|
| **Translatable** (MachineApplicable) | lossless bijection **and** the owner carries no richer structure | could auto-apply |
| **Suggest-menu** (MaybeIncorrect / HasPlaceholders) | valid but intent ambiguous, or the caller must pick a mode | offer the choices, don't pick one |
| **Explain-route** | the owning subsystem is strictly **richer** than the flat write | reject + teach the channel |

The criterion is *not* "is the translation valid?" — it's "does it discard intent the richer subsystem can hold?" `filter:blur(4px)` → FilterLayer is **not** translatable (FilterLayer carries ordering, stacking, blend modes a flat string can't encode).

**v1, locked:**
- **Default = teach** (reject + route), *even when lossless*, for the agent surface — with follow-rate observability wired. Don't build the translate machinery yet; let data earn the flip. Simpler wins until the numbers say otherwise.
- `display:none` is **not** a clean bijection — it's 1-of-5 `TplVisibility` modes. So it's **suggest-menu** (name all five: visible / invisible / display-none / activity / removed), never a silent pick, never a bare ban.
- The Applicability tier is **typed metadata on the rule**, never prose in docs (so it can't be bypassed). See cohort-research → `machine-fix-safety-classes` (the same four-class shape).

*Proof it matters:* the clinical renal-dose study — when appropriate-override was 2.2% the system that auto-defaulted to the correct dose hit 100% acceptance; the replacement that removed auto-translate hit 100% override. Losslessness, measured.

---

## Rule 2 — Collect-all, never fail-fast — but phase-split the transaction

A boundary validator returns **all** violations in one structured response, not the first. Mechanism: a Zod `.superRefine` accumulating issues (`ZodError.issues[]` → `flatten()`); we already validate MCP input through Zod, so the collect-all seam already exists.

Then transaction semantics differ **by phase**:

- **Mutation / action tools → fill-or-kill (atomic).** Any rejection rolls back the whole batch; the batch shares one context scope. This matches the existing MCP rollback infra.
- **Discovery / REPL tools → continue, dependency-aware.** Independent top-level statements still execute after a failure (REPL semantics). A statement that references a symbol whose definition **failed** is **skipped with explicit attribution** ("not run: depends on `x`, which failed above") — never a silent skip, never a confusing secondary "unbound `x`". Attribute the cascade to its root.

Boundaries:
- Collect-all is for **independent** violations. For **causally-chained** errors surface the *root cause*, not the downstream artifacts (the discovery-phase dependency-skip is this rule applied to a REPL).
- **Collect-all needs prevention-governance or it's just slow whack-a-mole.** Pre-disable controls (UI) and use a typed schema (agent) so most bad input *can't be expressed*. Prevention beats messaging (Nielsen H5; poka-yoke Elimination > Detection). And volume ↔ acceptance are coupled: fewer, sharper rejections get followed more (a CDS governance pass cut alert volume 60% and *tripled* action-taken on what remained).

---

## Rule 3 — Error codes: derive, keep internal, ship first

- **Stable semantic code + mutable human message** — our model-design discipline exactly (`represents` stable / implementation mutable; every field a permanent CRDT commitment).
- **Derive the code from the owner taxonomy** — `owned-by/<subsystem>`, `decompose/longhands`. No central registry to rot; a new owner *auto-creates* its code (Biome's `lint/group/rule` shape). Adding a code = adding an owning subsystem (a rare, model-level event), never incidental drift.
- **Code names the semantic reason/owner, never the implementation.** `owned-by/transform-layer`, not `css_blocked_by_filter_v2`.
- **The code is an internal routing + telemetry key — never surfaced raw.** Agents reason from prose, not codes (Anthropic tool-writing guidance); a bare code shown to a human fails WCAG 3.3.1. The consumer sees the explainer; the *system* branches on the code.
- **Ship the stable code first, then iterate prose forever** (AIP-193: the message is free to change *iff* the machine identity is always present). Land `code` + `owner`, improve wording later as you learn what callers misread.

---

## Rule 4 — Explainers: recovery-script for agents, progressive disclosure for humans

The reframe: **agents ≠ humans.** Build both renderings from one structured payload.

- **Agent door** = a numbered recovery script with **exact tool names** — `call (set-visibility …)`, not "use the visibility subsystem." Parameter-specific messages beat generic ones ~3×; per-error-class corrective actions lifted recovery +57pp in published evals. No raw codes in the text.
- **Human door** = inline at the (pre-disabled) control, plain language, no codes, no blame. Stop-words: *invalid, forbidden, illegal, please, sorry, oops*. Same wording in the summary and inline (GOV.UK dual-display).
- **Verbosity by per-session first-occurrence (locked):** first time a code appears in a session → **verbose** concept-intro (explain the model, why it's owned elsewhere, the related domains); afterwards → **terse** one-liner. Implement as **postprocessing in the MCP output layer** holding a per-session `Set<seen code>` — *not* in the generator (the generator always emits the same structured door; verbosity is a render concern). Humans habituate (collapse repeats — once a person tunes out an alert they re-ignore it 99.9% of the time); agents don't habituate but context is finite. The UI equivalent is simply the pre-disabled control plus a "learn more".
- **Populate the structured payload (code, owner, prop, tier) at the point of rejection;** each surface renders its own form. Never assemble the door ad-hoc downstream.

---

## Rule 5 — Measure follow-rate (the frontier — no software domain has)

No compiler, API, linter, or agent framework publishes a follow-rate metric; clinical decision support is the only field with the measurement discipline. We're ahead of the prior art here, so borrow the discipline:

- **Metric:** after a rejection with code `C` on turn N, did the next action route to `C`'s owner-channel **and succeed**? Binary and automatable on the agent surface — the owner→actions map that *renders* the door also classifies "followed."
- **Define "followed" = action-taken; exclude mere acknowledgment/dismissal** (the CDS "action-taken rate"), or an agent that just acks will game it.
- **A low follow-rate on a code means the explainer is broken → rewrite that door.** The code is stable, so the prose is free to change.
- **Wire in-band feedback:** a way to flag a bad door *from the rejection itself* (in-alert feedback is the only CDS signal that scales). See cohort-research → `rule-as-peer-fix-target`.
- **Humans:** pre-disabling makes follow-rate ~100% by construction — prevention dominates measurement; instrument the agent surface, prevent on the human one.

---

## Quick checklist

- ☐ Assert (internal → throw) or validator (boundary → collect + route)?
- ☐ Each rejection classified: translatable / suggest-menu / explain-route — tier as typed metadata.
- ☐ Collect all violations; transaction phase-correct (mutation = fill-or-kill; discovery = continue + dependency-aware skip).
- ☐ Prevention upstream (pre-disabled controls / typed schema) so the collected set stays small.
- ☐ Code derived from owner taxonomy, internal-only, shipped before perfect prose.
- ☐ Door = fact + reason + action; exact tool names for agents; no stop-words for humans.
- ☐ Structured payload built at the rejection point; per-surface render; per-session verbosity gate in the output layer.
- ☐ Code logged for follow-rate; "followed" excludes acknowledgment; feedback affordance wired.

## Connections

- **cohort-research** diagnostics: `machine-fix-safety-classes` (the Applicability four-class shape, humans-auto vs agents-opt-in), `rule-as-peer-fix-target` (make the rule editable from the violation surface — the in-band feedback affordance), `test-passes-feature-broken` (intent-verification gap).
- **Model-design discipline** — codes are permanent CRDT commitments; derive, don't store what can be derived.
- **Arrival two-phase model** (`DiscoveryToolInteraction` vs `ActionToolInteraction`) grounds Rule 2's phase-split — discovery is the REPL, action is fill-or-kill.
- **`feedback_two_design_principles`** (memory) — "every fact is a door: fact → reason → action" is the spine of this whole skill, applied to the error surface.
