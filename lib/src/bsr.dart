/// Binary Subtree Representation (BSR) for compact derivation recording.
///
/// A BSR set is populated *during* parsing. Each entry records that a rule
/// was successfully completed over a specific input span.  The SPPF can then
/// be derived on-demand from these entries rather than from an exhaustive
/// grammar walk.
///
/// Reference: Scott & Johnstone, "GLL Parse-Tree Generation" (2013).
library glush.bsr;

import 'package:glush/src/mark.dart';
import 'patterns.dart';
import 'sppf.dart';

// ---------------------------------------------------------------------------
// Trampoline for CPS-based recursion management
// ---------------------------------------------------------------------------

abstract class _Trampoline<T> {
  T run() {
    _Trampoline<T> current = this;
    while (current is _More<T>) {
      current = current.next();
    }
    return (current as _Done<T>).result;
  }
}

class _More<T> extends _Trampoline<T> {
  final _Trampoline<T> Function() next;
  _More(this.next);
}

class _Done<T> extends _Trampoline<T> {
  final T result;
  _Done(this.result);
}

extension _TrampolineExtensions<T> on _Trampoline<T> {
  _Trampoline<U> then<U>(_Trampoline<U> Function(T) f) {
    if (this is _Done<T>) {
      return f((this as _Done<T>).result);
    }
    return _More<U>(() => (this as _More<T>).next().then(f));
  }
}

/// Represents a grammar slot in a production: A ::= \alpha · \beta.
class GrammarSlot {
  final Rule rule;
  final Pattern? pattern; // The pattern that was just matched (\alpha = \gamma pattern)

  const GrammarSlot(this.rule, this.pattern);

  @override
  bool operator ==(Object other) =>
      other is GrammarSlot && other.rule == rule && other.pattern == pattern;

  @override
  int get hashCode => Object.hash(rule, pattern);

  @override
  String toString() {
    if (pattern == null) return '<${rule.name} ::= · ...>';
    if (pattern == rule) return '<${rule.name} ::= ... ·>';
    return '<${rule.name} ::= ... $pattern · ...>';
  }
}

/// A BSR entry (RuleSlot, start, pivot, end) according to Scott & Johnstone.
typedef BsrEntry = (GrammarSlot slot, int start, int pivot, int end);

extension BsrEntryMethods on BsrEntry {
  GrammarSlot get slot => $1;
  int get start => $2;
  int get pivot => $3;
  int get end => $4;
}

/// The set of all [BsrEntry] instances accumulated during a parse.
class BsrSet {
  final Set<BsrEntry> _entries = {};

  // Indexing for efficient SPPF construction.
  Map<(Rule, int, int), List<(int, Pattern?)>>? _index;
  Map<(Rule, int, int), List<(int, Pattern?)>>? _leftIndex;

  void _ensureIndex() {
    if (_index != null) return;
    final entriesBySpan = <(Rule, int, int), List<(int, Pattern?)>>{};
    final entriesByStart = <(Rule, int, int), List<(int, Pattern?)>>{};

    for (final entry in _entries) {
      final key = (entry.slot.rule, entry.start, entry.end);
      (entriesBySpan[key] ??= []).add((entry.pivot, entry.slot.pattern));

      final startKey = (entry.slot.rule, entry.start, entry.pivot);
      (entriesByStart[startKey] ??= []).add((entry.end, entry.slot.pattern));
    }
    _index = entriesBySpan;
    _leftIndex = entriesByStart;
  }

  /// Add a rule-completion entry.
  void add(GrammarSlot slot, int start, int pivot, int end) {
    _entries.add((slot, start, pivot, end));
    _index = null;
  }

  /// Total number of recorded rule-completion entries.
  int get length => _entries.length;
  Iterable<BsrEntry> get allEntries => _entries;

  /// Build an SPPF rooted at [startRule] over the full input.
  SymbolicNode? buildSppf(Rule startRule, String input, ForestNodeManager nodeManager) {
    _ensureIndex();
    final memo = <String, SymbolicNode?>{};
    final inProgress = <String, bool>{};
    return _buildNode(startRule, input, 0, input.length, nodeManager, memo, inProgress).run();
  }

  _Trampoline<SymbolicNode?> _buildNode(
    Rule rule,
    String input,
    int start,
    int end,
    ForestNodeManager nodeManager,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
  ) {
    final key = '${rule.symbolId}:$start:$end';
    if (_index![(rule, start, end)] == null) return _Done(null);
    if (memo.containsKey(key)) return _Done(memo[key]);
    if (inProgress[key] == true) return _Done(null);

    inProgress[key] = true;
    final symNode = nodeManager.symbolic(start, end, rule);

    return _More(
      () => _patternNodes(
        rule.body(),
        input,
        start,
        end,
        nodeManager,
        memo,
        inProgress,
        (childNodes) {
          for (final child in childNodes) symNode.addFamily(Family([child]));
          inProgress[key] = false;
          final result = symNode.families.isNotEmpty ? symNode : null;
          memo[key] = result;
          return _Done(result);
        },
        rule,
        start,
      ),
    );
  }

  _Trampoline<T> _buildNodeWith<T>(
    Rule rule,
    String input,
    int start,
    int end,
    ForestNodeManager nodeManager,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
    _Trampoline<T> Function(SymbolicNode?) cont,
  ) {
    final key = '${rule.symbolId}:$start:$end';
    if (_index![(rule, start, end)] == null) return cont(null);
    if (memo.containsKey(key)) return cont(memo[key]);
    if (inProgress[key] == true) return cont(null);

    inProgress[key] = true;
    final symNode = nodeManager.symbolic(start, end, rule);

    return _More(
      () => _patternNodes(
        rule.body(),
        input,
        start,
        end,
        nodeManager,
        memo,
        inProgress,
        (childNodes) {
          for (final child in childNodes) symNode.addFamily(Family([child]));
          inProgress[key] = false;
          final result = symNode.families.isNotEmpty ? symNode : null;
          memo[key] = result;
          return cont(result);
        },
        rule,
        start,
      ),
    );
  }

  Set<int> _pivotsFor(Rule rule, int ruleStart, int currentEnd, Pattern lastPattern) {
    if (_index == null) _ensureIndex();
    final entries = _index![(rule, ruleStart, currentEnd)];
    if (entries == null) return const {};
    final result = <int>{};
    for (final (pivot, slotPat) in entries) {
      if (_slotPatternMatches(slotPat, lastPattern)) result.add(pivot);
    }
    return result;
  }

  Set<int> _pivotsFromLeft(Rule rule, int ruleStart, int pivot, Pattern firstPattern) {
    if (_leftIndex == null) _ensureIndex();
    final entries = _leftIndex![(rule, ruleStart, pivot)];
    if (entries == null) return const {};
    final result = <int>{};
    for (final (end, slotPat) in entries) {
      if (_slotPatternMatches(slotPat, firstPattern)) result.add(end);
    }
    return result;
  }

  static bool _slotPatternMatches(Pattern? recorded, Pattern? query) {
    if (recorded == query) return true;
    if (recorded == null || query == null) return false;
    if (recorded.symbolId != null && recorded.symbolId == query.symbolId) return true;
    if (query is RuleCall) return _slotPatternMatches(recorded, query.rule);
    if (query is Call) return _slotPatternMatches(recorded, query.rule);
    if (query is Action) return _slotPatternMatches(recorded, query.child);
    if (query is PrecedenceLabeledPattern) return _slotPatternMatches(recorded, query.pattern);
    return false;
  }

  _Trampoline<T> _patternNodes<T>(
    Pattern pattern,
    String input,
    int start,
    int end,
    ForestNodeManager nodeManager,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
    _Trampoline<T> Function(List<ForestNode>) continuation,
    Rule currentRule,
    int ruleStart,
  ) {
    switch (pattern) {
      case Token():
        if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
          return continuation([nodeManager.terminal(start, end, pattern, input.codeUnitAt(start))]);
        }
        return continuation([]);
      case Marker():
        return continuation(start == end ? [nodeManager.marker(start, pattern)] : []);
      case Eps():
        return continuation(start == end ? [nodeManager.epsilon(start, pattern)] : []);
      case Alt():
        return _More(
          () => _patternNodes(
            pattern.left,
            input,
            start,
            end,
            nodeManager,
            memo,
            inProgress,
            (left) => _More(
              () => _patternNodes(
                pattern.right,
                input,
                start,
                end,
                nodeManager,
                memo,
                inProgress,
                (right) => continuation([...left, ...right]),
                currentRule,
                ruleStart,
              ),
            ),
            currentRule,
            ruleStart,
          ),
        );
      case Seq():
        IntermediateNode? seqNode;
        final rightPivots = _pivotsFor(currentRule, ruleStart, end, pattern.right);
        final leftPivots = _pivotsFromLeft(currentRule, ruleStart, start, pattern.left);

        // Final optimization: use BSR pivots if available to achieve O(1) splits.
        // Fallback to guarded exhaustive search ONLY if BSR indicates a match exists.
        final Iterable<int> splitPoints;
        if (rightPivots.isNotEmpty || leftPivots.isNotEmpty) {
          splitPoints = {...rightPivots, ...leftPivots};
        } else if (_index![(currentRule, ruleStart, end)] != null) {
          splitPoints = {for (var i = start; i <= end; i++) i};
        } else {
          return continuation([]);
        }

        _Trampoline<T> loop(Iterator<int> it) {
          if (!it.moveNext()) return continuation(seqNode != null ? [seqNode!] : []);
          final mid = it.current;
          return _More(
            () => _patternNodes(
              pattern.left,
              input,
              start,
              mid,
              nodeManager,
              memo,
              inProgress,
              (leftNodes) {
                if (leftNodes.isEmpty) return _More(() => loop(it));
                return _More(
                  () => _patternNodes(
                    pattern.right,
                    input,
                    mid,
                    end,
                    nodeManager,
                    memo,
                    inProgress,
                    (rightNodes) {
                      if (rightNodes.isNotEmpty) {
                        seqNode ??= nodeManager.intermediate(start, end, pattern, 'Seq');
                        for (final l in leftNodes)
                          for (final r in rightNodes) seqNode!.addFamily(Family([l, r]));
                      }
                      return _More(() => loop(it));
                    },
                    currentRule,
                    ruleStart,
                  ),
                );
              },
              currentRule,
              ruleStart,
            ),
          );
        }
        return _More(() => loop(splitPoints.iterator));
      case Plus():
        IntermediateNode? plusNode;
        final pivots = _pivotsFor(currentRule, ruleStart, end, pattern.child);
        final Iterable<int> splitPoints;
        if (pivots.isNotEmpty) {
          splitPoints = pivots;
        } else if (_index![(currentRule, ruleStart, end)] != null) {
          splitPoints = {for (var i = start + 1; i <= end; i++) i};
        } else {
          splitPoints = const <int>{};
        }

        _Trampoline<T> loop(Iterator<int> it) {
          if (!it.moveNext()) {
            return _More(
              () => _patternNodes(
                pattern.child,
                input,
                start,
                end,
                nodeManager,
                memo,
                inProgress,
                (nodes) {
                  if (nodes.isNotEmpty) {
                    plusNode ??= nodeManager.intermediate(start, end, pattern, 'Plus');
                    for (final n in nodes) plusNode!.addFamily(Family([n]));
                  }
                  return continuation(plusNode != null ? [plusNode!] : []);
                },
                currentRule,
                ruleStart,
              ),
            );
          }
          final mid = it.current;
          return _More(
            () => _patternNodes(
              pattern.child,
              input,
              start,
              mid,
              nodeManager,
              memo,
              inProgress,
              (head) {
                if (head.isEmpty) return _More(() => loop(it));
                return _More(
                  () => _patternNodes(
                    pattern,
                    input,
                    mid,
                    end,
                    nodeManager,
                    memo,
                    inProgress,
                    (tail) {
                      if (tail.isNotEmpty) {
                        plusNode ??= nodeManager.intermediate(start, end, pattern, 'Plus');
                        for (final h in head)
                          for (final t in tail) plusNode!.addFamily(Family([h, t]));
                      }
                      return _More(() => loop(it));
                    },
                    currentRule,
                    ruleStart,
                  ),
                );
              },
              currentRule,
              ruleStart,
            ),
          );
        }
        return _More(() => loop(splitPoints.iterator));
      case Star():
        IntermediateNode? starNode;
        final pivots = _pivotsFor(currentRule, ruleStart, end, pattern.child);
        final Iterable<int> splitPoints;
        if (pivots.isNotEmpty) {
          splitPoints = pivots;
        } else if (_index![(currentRule, ruleStart, end)] != null) {
          splitPoints = {for (var i = start + 1; i <= end; i++) i};
        } else {
          splitPoints = const <int>{};
        }

        _Trampoline<T> loop(Iterator<int> it) {
          if (!it.moveNext()) {
            if (start == end) {
              starNode ??= nodeManager.intermediate(start, end, pattern, 'Star');
              starNode!.addFamily(Family([nodeManager.epsilon(start, pattern)]));
            }
            return continuation(starNode != null ? [starNode!] : []);
          }
          final mid = it.current;
          return _More(
            () => _patternNodes(
              pattern.child,
              input,
              start,
              mid,
              nodeManager,
              memo,
              inProgress,
              (head) {
                if (head.isEmpty) return _More(() => loop(it));
                return _More(
                  () => _patternNodes(
                    pattern,
                    input,
                    mid,
                    end,
                    nodeManager,
                    memo,
                    inProgress,
                    (tail) {
                      if (tail.isNotEmpty) {
                        starNode ??= nodeManager.intermediate(start, end, pattern, 'Star');
                        for (final h in head)
                          for (final t in tail) starNode!.addFamily(Family([h, t]));
                      }
                      return _More(() => loop(it));
                    },
                    currentRule,
                    ruleStart,
                  ),
                );
              },
              currentRule,
              ruleStart,
            ),
          );
        }
        return _More(() => loop(splitPoints.iterator));
      case Conj():
        return _More(
          () => _patternNodes(
            pattern.left,
            input,
            start,
            end,
            nodeManager,
            memo,
            inProgress,
            (left) {
              if (left.isEmpty) return continuation([]);
              return _More(
                () => _patternNodes(
                  pattern.right,
                  input,
                  start,
                  end,
                  nodeManager,
                  memo,
                  inProgress,
                  (right) {
                    if (right.isEmpty) return continuation([]);
                    final node = nodeManager.intermediate(start, end, pattern, 'Conj');
                    for (final l in left) for (final r in right) node.addFamily(Family([l, r]));
                    return continuation([node]);
                  },
                  currentRule,
                  ruleStart,
                ),
              );
            },
            currentRule,
            ruleStart,
          ),
        );
      case Rule():
        return _More(
          () => _patternNodes(
            pattern.body(),
            input,
            start,
            end,
            nodeManager,
            memo,
            inProgress,
            continuation,
            pattern,
            ruleStart,
          ),
        );
      case RuleCall(:var rule) || Call(:var rule):
        return _More(
          () => _buildNodeWith(
            rule,
            input,
            start,
            end,
            nodeManager,
            memo,
            inProgress,
            (node) => continuation(node != null ? [node] : []),
          ),
        );
      case Action<dynamic>():
        return _More(
          () => _patternNodes(
            pattern.child,
            input,
            start,
            end,
            nodeManager,
            memo,
            inProgress,
            (nodes) {
              if (nodes.isEmpty) return continuation([]);
              final node = nodeManager.intermediate(start, end, pattern, 'Action');
              for (final n in nodes) node.addFamily(Family([n]));
              return continuation([node]);
            },
            currentRule,
            ruleStart,
          ),
        );
      case PrecedenceLabeledPattern():
        return _More(
          () => _patternNodes(
            pattern.pattern,
            input,
            start,
            end,
            nodeManager,
            memo,
            inProgress,
            continuation,
            currentRule,
            ruleStart,
          ),
        );
      case And() || Not():
        return continuation(start == end ? [nodeManager.epsilon(start, pattern)] : []);
    }
  }

  @override
  String toString() => 'BsrSet(${_entries.length} entries)';
}

sealed class BsrParseOutcome {}

final class BsrParseError implements BsrParseOutcome, Exception {
  final int position;
  const BsrParseError(this.position);
}

final class BsrParseSuccess implements BsrParseOutcome {
  final BsrSet bsrSet;
  final List<Mark> marks;
  const BsrParseSuccess(this.bsrSet, this.marks);
}
