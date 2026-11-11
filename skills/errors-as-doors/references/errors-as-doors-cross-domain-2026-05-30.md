# Errors as Doors — cross-domain research consolidation (2026-05-30)

Evidence base for the `errors-as-doors` skill (`skills/errors-as-doors/SKILL.md`). Source: an 8-domain parallel research swarm on "diagnostics-as-interface / educational-error" prior art (~620k tokens, 337 web lookups). This doc preserves the consolidated synthesis + the per-domain citation base; the skill carries the distilled, prescriptive rules.

## Context

We are reworking the "property disabled" DX in here.build so that "bad request / not allowed" rejections are **educational, not banning**. The model layer rejects certain CSS property writes because dedicated structured subsystems own those concerns (`display:none`/`visibility` → TplVisibility; `filter` → FilterLayer; `transform` → TransformLayer; `box-shadow` → ShadowLayer; backgrounds → BackgroundLayer; `font`/`columns`/`list-style` → decompose). Consumers are **both** AI agents (via MCP `set-styles`, which today throws on the first bad prop) and humans (via studio UI).

Four open design questions framed the swarm:
1. **Reject vs translate** — when auto-translate into the owning flow (lossless) vs reject-and-teach (owner is richer)?
2. **Collect-all vs fail-fast** — move off throw-on-first toward a validation schema?
3. **Error-code inventory** — stable semantic codes without rot?
4. **Explainers + follow-rate** — wire the redirect to each surface, and measure whether the caller actually follows it?

## Headline: the spine is the convergent best practice

"Errors are doors / reject = pointer to the owning subsystem" was independently the consensus of four unrelated domains: **Elm** ("a compiler is a teaching assistant; every error is a redirect"), **Norman** ("eliminate error messages, replace with help and guidance; let people correct directly from the guidance"), **AWS IAM** ("name the owning policy + the remediation verb"), **Stripe** ("the error *is* the routing instruction — `doc_url` ships in the payload"). Not invented — re-derived.

## The reframe: agent ≠ human is two optimization targets, not one rendering detail

Surfaced unprompted in four domains:
- **Clinical:** humans **habituate** — acceptance drops ~30% per additional alert/encounter; once a clinician overrides a specific alert they re-override it **99.9%** of the time. An explainer that re-fires becomes noise within days. *But* "our MCP agent consumer is not a human; it does not habituate the same way."
- **Agent frontier:** even a **lossless** auto-translate may be wrong for an agent — silent correction leaves the agent's world-model stale (it never learns the proper channel). No published experiment compares lossless-translate vs teach for agents.

→ The two callers may want opposite defaults (human: silently normalize / pre-disable; agent: teach so it learns the channel). The door is rendered differently per consumer, and even the translate-vs-teach default may flip per consumer.

## Consolidated synthesis by question

### Q1 — Reject vs translate (8/8 convergence)
Auto-translate **iff** lossless bijection **and** the owner carries no richer structure; else teach. Named taxonomy to adopt: the rustc/Clippy **`Applicability` enum** (MachineApplicable / MaybeIncorrect / HasPlaceholders / Unspecified) — a typed 3-way branch (translate / suggest-menu / explain-route), not a binary. The tier lives as typed metadata on the rule, never in docs. **Sharpening:** `display:none` → TplVisibility is *not* a clean bijection (1-of-5 modes) → suggest-menu, not silent translate. **Open/empirical:** lossless-translate-vs-teach for agents is unvalidated by every domain — instrument it.

### Q2 — Collect-all (unanimous)
Collect all violations, return together; fail-fast is named an anti-pattern everywhere. **Zod** is the canonical implementation reference (cited by 3 domains independently). **Refinements:** (a) collect-all only for *independent* errors — for *causally-chained*, surface the root cause (AgentDebug); (b) collect-all needs **prevention-governance** or it just slows the whack-a-mole — pre-disabled controls (UI) / typed schema (agent) keep the set small; volume↔acceptance are coupled.

### Q3 — Error codes (unanimous, == our model-design discipline)
Stable semantic code + mutable message, permanent pair. **Three refinements:** (a) **derive** the code from the owner taxonomy (Biome `lint/group/rule` = zero-maintenance, no registry to rot); (b) the code is an **internal routing/telemetry key, never surfaced raw** (agents reason from prose — Anthropic; bare code to a human fails WCAG 3.3.1); (c) **ship the stable code first, then iterate prose forever** (AIP-193: message mutable iff machine identity always present).

### Q4 — Explainers + follow-rate
Tripartite fact→reason→action confirmed. **Agent door** = numbered recovery-script with exact tool names (parameter-specific ≈3× generic; per-class corrective action +57pp). **Dual-surface, populated at rejection** (GOV.UK same-wording summary+inline; one payload, per-surface render). **Follow-rate is the frontier — no software domain publishes it;** clinical (CDS) is the only field with the discipline: define "followed" = action-taken (exclude acknowledgment), watch the habituation curve, prune for specificity, wire in-band feedback. Our agent surface makes the metric uniquely binary/automatable.

## Decisions locked (2026-05-30, with V)

1. **Transaction = phase-split.** Mutations → **fill-or-kill** (atomic batch, shared context). Discovery/REPL → continue independent top-level statements after failure; **skip a statement depending on a symbol that failed to define, with explicit attribution** (never silent, never a secondary "unbound x").
2. **Agent default = teach + observability** (not translate), even when lossless. Don't build the translate machinery in v1; let follow-rate data earn the flip.
3. **First instance = suggest-menu, same code, verbose-vs-terse by per-session first-occurrence.** `display:none` → present the 5 TplVisibility modes. Verbosity is **MCP-output postprocessing** keyed on a per-session `Set<seen code>` — first occurrence → concept-intro, after → one-liner. Generator stays dumb.

## Per-domain citation base

### Compiler / language-tooling diagnostics
- rustc `Applicability` enum — confidence-to-auto-apply: `https://doc.rust-lang.org/nightly/nightly-rustc/rustc_errors/enum.Applicability.html`
- Clang fix-it placement (errors/warnings vs notes — note = never auto-applied): `https://clang.llvm.org/docs/InternalsManual.html`
- rustc error-code catalog (permanent E-numbers) + `--explain`: `https://rustc-dev-guide.rust-lang.org/diagnostics/error-codes.html`
- rustc stash/steal + parser error-recovery (collect-all across phases): `https://github.com/rust-lang/rust/pull/120828`
- Elm "compiler errors for humans" (every error is a redirect): `https://elm-lang.org/news/compiler-errors-for-humans`
- Fluent slug migration (stable slug / mutable text): `https://blog.rust-lang.org/inside-rust/2022/08/16/diagnostic-effort/`

### API developer-experience & structured errors
- Stripe error object (type/code/param/doc_url; message mutable, code stable): `https://docs.stripe.com/api/errors`
- Google AIP-193 ErrorInfo `(reason, domain)` permanent identity; message-mutable-iff-ErrorInfo-present: `https://google.aip.dev/193`
- RFC 9457 Problem Details — `errors[]` + JSON Pointer collect-all: `https://datatracker.ietf.org/doc/html/rfc9457`
- gRPC `BadRequest.FieldViolations[]`; GraphQL `errors[]` partial-success-by-default; HTTP 207 multi-status (index field).

### Linters & autofix (adoption economics)
- ESLint `meta.fixable` vs `meta.hasSuggestions`: `https://eslint.org/docs/latest/extend/custom-rules`
- Clippy `Applicability` enum (same as rustc): `https://doc.rust-lang.org/nightly/nightly-rustc/rustc_lint_defs/enum.Applicability.html`
- Biome `fix: safe|unsafe|none`, user-overridable: `https://biomejs.dev/linter/`
- Biome category `lint/group/ruleName` = self-documenting stable code: `https://biomejs.dev/reference/diagnostics/`
- ESLint bulk-suppressions (the "guidance routed around" negative signal): `https://eslint.org/blog/2025/04/introducing-bulk-suppressions/`
- Clippy adoption study (42% FP complaints, 68% prefer warn over deny): `https://arxiv.org/html/2310.11738`

### Clinical decision support / CPOE alert fatigue
- Five Rights of CDS (right info/person/format/channel/time): `https://digital.ahrq.gov/.../section-2-overview-cds-five-rights`
- Hard-stop efficacy + unintended consequences (JAMIA 2018): `https://pmc.ncbi.nlm.nih.gov/articles/PMC6915824/`
- Override-rate corpus (90–96% baseline; minimally-interruptive 61.9%): `https://pmc.ncbi.nlm.nih.gov/articles/PMC7761179/`
- Habituation (30%/alert; OR 0.38 above 720 alerts/90d; 99.9% re-override): `https://pmc.ncbi.nlm.nih.gov/articles/PMC9748542/`
- Singapore governance (volume −59.6% → action-taken 8%→54.7%): `https://pmc.ncbi.nlm.nih.gov/articles/PMC10393867/`
- Renal auto-translate proof (2.2% appropriate-override → auto-default = 100% accept; removal = 100% override): `https://pmc.ncbi.nlm.nih.gov/articles/PMC8661393/`
- In-band feedback stewardship (806 submissions → 21 fixes): `https://pmc.ncbi.nlm.nih.gov/articles/PMC9132737/`

### LLM tool-use / agent error recovery (frontier)
- MCP spec — `isError` + actionable execution-error example: `https://modelcontextprotocol.io/specification/2025-11-25/server/tools`
- Anthropic "Writing Tools for Agents" (avoid opaque codes; actionable prose): `https://www.anthropic.com/engineering/writing-tools-for-agents`
- PALADIN recovery dictionary (7 classes → corrective action; +57pp): `https://arxiv.org/abs/2509.25238`
- Fission-GRPO (parameter-specific +3.62% vs generic +1.25%): `https://arxiv.org/abs/2601.15625`
- ReAct retry-waste (90.8% wasted; permanent/transient split): `https://towardsdatascience.com/your-react-agent-is-wasting-90-of-its-retries-heres-how-to-stop-it/`
- Pydantic/Instructor ValidationError collect-all + re-ask: `https://python.useinstructor.com/concepts/reask_validation/`
- AgentDebug (earliest-root-cause beats reporting-all for chained errors): `https://arxiv.org/abs/2509.25370`

### HCI error-design theory
- Norman slip/mistake (slip → translate; mistake → educate): `https://tianpan.co/blog/2025-08-31-the-design-of-everyday-things`
- Nielsen heuristics #5 (prevention) / #9 (recognize-diagnose-recover, "no error codes"): `https://www.nngroup.com/articles/ten-usability-heuristics/`
- NN/g error-message scoring rubric (Visibility/Communication/Efficiency): `https://www.nngroup.com/articles/error-messages-scoring-rubric/`
- Postel's Law as the lossless-translate criterion: `https://www.perpetualny.com/blog/ux-design-principle-005-postels-law`
- Poka-yoke response hierarchy (Warning > Control/Shutdown) + prevention hierarchy (Eliminate > Prevent > Detect): `https://asq.org/quality-resources/mistake-proofing`
- "Error message is a recovery script the LLM executes" (~20%→~95%): `https://dev.to/johnonline35/why-your-apis-error-messages-fail-when-called-by-an-llm-and-how-to-fix-them-5a5d`

### Form validation & accessibility error UX
- GOV.UK error summary — dual-display + focus-move + anchor links: `https://design-system.service.gov.uk/components/error-summary/`
- GOV.UK error-message stop-word list (no invalid/forbidden/please/sorry): `https://design-system.service.gov.uk/components/error-message/`
- GOV.UK validate-on-submit-not-on-blur: `https://design-system.service.gov.uk/patterns/validation/`
- WCAG 3.3.1 (in-text identification) / 3.3.3 (suggestion) / 3.3.4 (prevention): `https://www.w3.org/WAI/WCAG21/Understanding/error-identification.html`
- Zod `ZodError.issues[]` + `flatten()` (stable code + mutable message): `https://deno.land/x/zod@v3-snapshot-2021-01-21/ERROR_HANDLING.md`
- HTML5 Constraint Validation (auto-translate semantic types, defer patterns): `https://developer.mozilla.org/en-US/docs/Web/HTML/Guides/Constraint_validation`
- Baymard inline validation (−22% errors, −42% time; 98% sites generic): `https://baymard.com/blog/inline-form-validation`

### Authorization / policy-denial explanation
- AWS IAM access-denied format (names owning policy + ARN; explicit vs implicit deny = different remediation verbs): `https://docs.aws.amazon.com/IAM/latest/UserGuide/troubleshoot_access-denied.html`
- IAM Access Analyzer four-tier findings (ERROR/SECURITY_WARNING/WARNING/SUGGESTION) + `recommendedAction` enum: `https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-reference-policy-checks.html`
- Cedar `isAuthorized()` returns determining-policy IDs (collect-all): `https://docs.cedarpolicy.com/auth/authorization.html`
- OPA Rego `deny contains msg` partial set (all violations) + `?explain=fails`: `https://www.openpolicyagent.org/docs`
- RFC 6750 `WWW-Authenticate: insufficient_scope` + `scope=` (the literal next-request string): `https://datatracker.ietf.org/doc/html/rfc6750`

## Pointers
- Skill: `skills/errors-as-doors/SKILL.md`
- Related prior decisions: `docs/working-proposals/todo/datacond-disentangle.md` (TplVisibility 5-mode enum), `.claude/rules/model-design.md`, `.claude/rules/interactions.md` (`represents` = recognition not constraint).
- Next: a working-proposal for the property-disabled rework itself, eng-reviewed before code.
