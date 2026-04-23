# Incremental Parsing Roadblocks & Technical Conflicts

## 1. Fast-Forwarding Synchronization Conflict (Papa Carlo)

**The Problem:**
The `glush_dart` parser is built as a synchronized, token-by-token evaluation engine. The `ParseState.processToken()` method drives the machine forward by one position at a time, moving active frames into the next step.
If we implement "Papa Carlo" Subtree Reuse, a specific parsing branch might find a cached `IntervalNode` and decide to "fast-forward" (e.g., skip from position 10 to position 25). 

However, `ParseState` does not have a global mechanism to defer frames far into the future. Currently, `Step.deferredFramesByPosition` only handles frames deferred for exactly `position + 1` (used primarily by predicates or epsilon transitions). If we shift a frame to position 25, it will be lost because `ParseState` only collects `step.deferredFramesByPosition.remove(position + 1)` and the `Step` object is then discarded.

**Implications:**
We cannot fast-forward one branch of the GSS without either:
1. Advancing the global `ParseState` (which would break other slower branches that still need to parse characters 10 through 24).
2. Introducing a global `Map<int, List<Frame>> futureFrames` inside `ParseState` where fast-forwarded branches can "wait" until the global synchronous loop catches up to them.

**Potential Solution:**
Move `deferredFramesByPosition` out of `Step` and into `ParseState` as `Map<int, List<Frame>> globalWaitlist`. In `ParseState.processToken`, when `position` reaches a waitlisted index, we inject those "fast-forwarded" frames back into the active `frames` pool.

---

## 2. IntervalTree Storage Type

**The Problem:**
Currently, `IntervalNode<T>` stores `LazyGlushList<Mark>`. But when querying `IntervalTree.findOverlapping(position)` during a rule call (`_seedRuleCall`), we need to verify that the cached derivation actually belongs to the *exact same rule* we are trying to parse. 
Just knowing there is a successful derivation from `start` to `end` is insufficient—we must know that it was a derivation for `targetRule`.

**Potential Solution:**
Create a `CachedRuleResult` struct:
```dart
class CachedRuleResult {
  final Rule rule;
  final LazyGlushList<Mark> marks;
  CachedRuleResult(this.rule, this.marks);
}
```
And change `ParseState.intervalIndex` to `IntervalTree<CachedRuleResult>`.
