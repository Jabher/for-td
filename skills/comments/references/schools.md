# Schools

Adjudicated stance for `comments`. The skill applies this mix; it does not re-run a literature panel unless the user challenges it.

**Outside-world comments are the product. Local comments are a rewrite ticket. Obvious comments are noise.** Clean Code's "comments are failure" is half-right: they fail when they explain *this* code. They are the only honest surface when the fact lives in the platform, the architecture, or another file. JSDoc-as-API lost to TypeScript types.

| School | Axiom | Use |
|---|---|---|
| Clean Code (Martin) — comments as apology | A comment explaining the next block means the block should have been rewritten. | REWRITE. The local-smell law. |
| Ousterhout *A Philosophy of Software Design* — comments for what the code cannot say | The comment's job is the non-local invariant, the why that is not in the names. | KEEP. The outside law. File preambles, named laws, platform pins. |
| Production-writing | Prose states, present tense, a constraint the code cannot show; one home on a placement ladder. | Form of *survivors*. This skill decides existence; that skill decides register and placement. |
| TypeScript hover / no-JSDoc-as-types | The signature is a proof. `@param foo The foo` is a second, worse type system. | DELETE `@param` / `@returns` / paraphrasing `/** Does X */`. |
| Named-law defense | A correct-looking "fix" will be proposed. Name the rule and the failure. | LOUDER. Rejected alternatives *with the failure they cause*. |
| Mechanical "comment every function" / TSDoc lint | Coverage of the outline. | Rejected. Density ∝ invisibility. Mechanical code stays silent. |

## Rejected alternatives

- **Clean Code, full stop: never comment.** That deletes KEEP. A library cleanup, an origin-routing table, a TDZ import-cycle leaf — none of those become "clear code" by renaming a local.
- **Comment the confusing code so the PR reads.** That is the apology. REWRITE, or the next reader trusts the comment and never fixes the smell.
- **JSDoc every export for the generated API.** The `.d.ts` already is the API. `@param` / `@returns` drift the day the signature changes. KEEP content about the *world* may sit in a `/** */` block; the tags still do not.
- **File preamble that restates the export list.** Navigation belongs in names. A preamble states the architecture the file *is*, the law it defends, the platform it sits on.
- **Body comment re-teaching the preamble.** Point (`see preamble, CHANGE ONLY`). Do not fork the rule.
- **Journal the change** ("now we", "previously", "this rev"). The reader needs the constraint as it stands. Git has the history.
- **Fill the file until comment density looks "thorough."** Empty obvious-headroom is success. A starved platform pin is a miss.
- **Strip KEEP comments in a polish pass because the skill said "fewer comments."** Volume is not the metric. Outside facts getting louder is success.
- **Leave a local smell because rewriting it is bigger than adding a sentence.** The sentence trains the next reader to skip the smell. The rewrite *is* the comment's job, done properly.
