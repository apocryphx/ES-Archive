# Defer the Comprehensive Parameter Test Suite Until the Schema Settles

*June 27, 2026. Archive type: decision. Restored to a durable file after the June-27 sync rollback.*

Kolja's call after the tags-array bug: yes, ES Memory needs a comprehensive test suite covering every tool parameter — but **NOT while the schema is still evolving** (as of June 2026 it is). Comprehensive shape-tests against a moving schema calcify the very iteration that is currently the valuable thing; you would spend the churn repairing tests instead of evolving the design. Tests are a commitment to stability; you make it when the interface stabilizes.

The sharper framing that should guide the suite when it is built: **the danger during churn is not UNTESTED parameters, it is SILENTLY-FAILING ones.** The tags-array bug returned status `created` and corrupted the tag catalog with garbage names across multiple sessions, no error raised. So:

1. **Interim protection that does NOT wait on the schema** — in-code boundary validation that recovers-or-stays-clean rather than corrupting quietly. The `tagArrayFromArgs` JSON-recovery fix (v1.6.6) is the template, not a one-off: a parameter parser should fail loud or self-heal, never create garbage silently. This discipline travels with the code through any schema change.

2. **When the suite is built, lead with INVARIANT / property tests** (round-trip: any input representation produces the same logical result; no input yields malformed state) which test properties, not shapes, and survive schema evolution. Param-shape assertions churn with the schema and come LAST, after stabilization.

Methodology note that prompted this: the bug was found not by testing but by genuine **use** during a research excursion — a fresh instance reaching for the natural (structured-array) representation hit a valid-but-unanticipated path the author never pictured. Dogfooding by a mind whose assumptions differ from the builder's is the strongest bug finder; tests then pin what use discovers.
