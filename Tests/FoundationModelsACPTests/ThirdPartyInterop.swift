/// Third-party interop against a real v2 agent or client — **deliberately
/// deferred**, not silently skipped (plan.md M9).
///
/// This is the one acceptance criterion this milestone cannot satisfy yet,
/// and it is recorded here rather than left as an unchecked claim or faked
/// with a mock.
///
/// ## Why deferred
///
/// v2 is a **draft** (`schema-v2.0.0-alpha.2`): `plan.md`'s own "Decision: v2
/// only" section notes the plan was written from a handful of doc pages plus
/// the migration guide, and that the migration guide has already proven to
/// run ahead of the schema. Both consumers this wire is for —
/// `FoundationModelsACPAgent` and `FoundationModelsACPClient` — are
/// themselves unimplemented, and no independent third-party v2 agent or
/// client is known to exist to round-trip against. There is nothing to dial.
///
/// ## Why not fake it with a mock
///
/// Every other test in this suite — `GoldenSessionEndToEndTests`,
/// `RoutingCoverageTests`, `PromptLifecycleTests`, and the rest — already
/// drives a real `Agent`/`Client` pair over a real `Connection` and real wire
/// bytes. Standing up one more mock `Agent` or `Client` and labeling the
/// result "interop" would not exercise anything those suites do not already
/// cover; it would only rename a unit test. Worse, it would look like this
/// criterion had been satisfied when it structurally cannot be by a
/// self-authored peer: the entire point of third-party interop is to
/// falsify **"we implement v2"** as distinct from **"we implement our
/// reading of v2"** — and a peer built by the same reading can only ever
/// agree with itself. A green result would prove nothing about where our
/// reading of the draft might have quietly diverged from what an independent
/// implementation does with the same schema.
///
/// ## Follow-up
///
/// Tracked as kanban task ^dsefdb7 ("Third-party v2 interop round trip, once
/// a real peer exists"): run a live round trip once a real v2 peer exists — a
/// reference implementation from the ACP project, an independent third-party
/// agent or client, or `FoundationModelsACPAgent` / `FoundationModelsACPClient`
/// tested against each other or against such a peer once either is built.
/// Until then, this criterion stays open, not quietly checked off.
///
/// ## Why no runtime test
///
/// This is an uninhabited (zero-case) enum: a documentation anchor, not a
/// value or behavior anything could exercise. A prior review round flagged
/// it as dead code for lacking an inbound caller, and a runtime test was
/// added purely to give it one — but the only assertion available for a
/// type with no cases and no behavior was an `ObjectIdentifier` compared to
/// itself, which passes unconditionally and checked nothing. That test has
/// been removed rather than kept as a tautology; the deferral itself is
/// verified by inspection (this comment, and the review process that reads
/// it), not by a test that could never fail.
enum ThirdPartyInteropDeferred {}
