# Schools

Adjudicated stance for `tests-review`. The skill applies this mix; it does not re-run a literature panel unless the user challenges it.

**Trophy cup + Chicago sociability + honeycomb edges + DHH natural layer + ROI seating + visual split + property collapse of farms + oracle collapse + workflow fusion.**

London does **not** win as the backbone. Isolating orchestrators from the product's substrate (CRDT, live daemon, real FS) is how test-only seams come back. Keep a handful of live-wiring tests; do not grow them into N vendor copies.

Google size applies to **CI shape**, not to renaming every test "unit."

| School | Axiom | Use |
|---|---|---|
| Rauch / Dodds trophy — [Write tests](https://kentcdodds.com/blog/write-tests); [Testing implementation details](https://kentcdodds.com/blog/testing-implementation-details) | Confidence, not coverage. A test that uses the code differently than production is a third user. | The cup is the wiring tests. Implementation-detail encyclopedias are the ice-cream cone. |
| Spotify honeycomb — [Testing of Microservices](https://engineering.atspotify.com/2018/01/testing-of-microservices) | Hit the component's edges. Implementation-detail only for combinatorial guts. Integrated (depends on another system) ideally none. | Edges, not 300 thin slices of a few edges. Rewrite live OAuth/HTTP onto an owned server. |
| Chicago / Fowler [UnitTest](https://martinfowler.com/bliki/UnitTest.html) | A unit is a behavior. Real collaborators. Mock the network. | Construction: real document, real FS, local HTTP. |
| London + [Rainsberger](https://blog.thecodewhisperer.com/permalink/integrated-tests-are-a-scam) | Collaboration + contract, O(n). An integrated failure is inexplicable. | Useful for *contracts* (lattice, path-escape). Rejected as the backbone of a daemon/CRDT/TUI product. |
| DHH — [Test-induced design damage](https://dhh.dk/2014/test-induced-design-damage.html) | Design drives tests. Natural layer. Don't extract seams so a unit test can mock. | If the UI is the interesting layer, ~dozen system stories, not dozens of painted-string searches. |
| Google S/M/L — *Software Engineering at Google* ch.11 | Size is resources. Large flakes ~28×. | Default job Small+Medium. Large quarantined. |
| QuickCheck / Hypothesis | Example farms are accidental quality. | One property + named regressions. |
| Emily Bache / TextTest | Logic asserts decisions. Visual approves appearance. | Separate job. Structural dump. A protocol fixture the other side locks stays with logic. |
| ROI / excuse-to-exist | If Unique is "documents the code", delete. Rank Blast × Unique / Cost. | Seating chart. Ceiling if the user names one; never a target. |

## Rejected alternatives

- **Keep them, they're fast.** Speed is not uniqueness.
- **Pyramid 70% Small units.** UI- or daemon-heavy products shift toward Medium at the natural layer. Small `instanceof` tests are the ice-cream cone.
- **London as backbone.** Isolating from the substrate recreates a test-only seam (`*Deps`, `resetXForTests`, a `#[cfg(test)]` hole, a shadow path).
- **Coverage % / one case per current title.** Implementation-detail third user (Dodds).
- **Visual stays in the logic suite.** Painted-string search is neither a decision nor an approval.
- **Refuse fusion so the count stays large.** A workflow split across three cases is three ways to miss the joint.
- **Fuse unrelated concepts to look smaller.** Budget cheat and a worse diagnostic.
- **Fill a named ceiling.** The ceiling is a ceiling.
