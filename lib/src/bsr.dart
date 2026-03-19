/// Binary Subtree Representation (BSR) for compact derivation recording.
///
/// A BSR set is populated *during* parsing. Each entry records that a rule
/// was successfully completed over a specific input span.  The SPPF can then
/// be derived on-demand from these entries rather than from an exhaustive
/// grammar walk.
///
/// Reference: Scott & Johnstone, "GLL Parse-Tree Generation" (2013).
library glush.bsr;

import 'package:glush/src/grammar.dart';
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

/// A BSR entry (RuleSlot, start, pivot, end) according to Scott & Johnstone.
typedef BsrEntry = (PatternSymbol slot, int start, int pivot, int end);

extension BsrEntryMethods on BsrEntry {
  PatternSymbol get slot => $1;
  int get start => $2;
  int get pivot => $3;
  int get end => $4;
}

extension type const BsrPattern(String thing) {}

/// The set of all [BsrEntry] instances accumulated during a parse.
class BsrSet {
  final Map<(PatternSymbol, int start, int end), Set<int>> _pivots = {};

  /// Add a rule-completion entry.
  void add(PatternSymbol patternSymbol, int start, int pivot, int end) {
    _pivots.putIfAbsent((patternSymbol, start, end), Set.new).add((pivot));
  }

  /// Total number of recorded rule-completion entries.
  int get length => _pivots.values.expand((v) => v).length;
  Iterable<BsrEntry> get entries =>
      _pivots.entries.expand((e) => e.value.map((v) => (e.key.$1, e.key.$2, e.key.$3, v)));

  Set<int> pivotsFor(PatternSymbol ruleSymbol, int start, int end) {
    return _pivots.putIfAbsent((ruleSymbol, start, end), Set.new).toSet();
  }

  /// Build an SPPF rooted at [startRule] over the full input.
  SymbolicNode? buildSppf(
    GrammarInterface grammar,
    Rule startRule,
    String input,
    ForestNodeManager nodeManager,
  ) {
    final memo = <String, SymbolicNode?>{};
    final inProgress = <String, bool>{};

    return SppfBuilder(this, nodeManager, input) //
        .buildNode(startRule, 0, input.length, memo, inProgress)
        .run();
  }

  @override
  String toString() => 'BsrSet(${_pivots.length} entries)';
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

class SppfBuilder {
  final BsrSet bsr;
  final ForestNodeManager nodeManager;
  final String input;

  const SppfBuilder(this.bsr, this.nodeManager, this.input);

  _Trampoline<SymbolicNode?> buildNode(
    Rule rule,
    int start,
    int end,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress, {
    int? minPrecedenceLevel,
  }) {
    final key = '${rule.name}:$start:$end';
    if (memo.containsKey(key)) return _Done(memo[key]);
    if (inProgress[key] == true) return _Done(null);

    inProgress[key] = true;
    final symNode = nodeManager.symbolic(start, end, rule.symbolId!);

    return _More(
      () => _patternNodes(
        rule,
        rule.body(),
        start,
        end,
        memo,
        inProgress,
        (childNodes) {
          for (final child in childNodes) symNode.addFamily(Family.unary(child));
          inProgress[key] = false;
          final result = symNode.families.isNotEmpty ? symNode : null;
          memo[key] = result;
          return _Done(result);
        },
        start,
        minPrecedenceLevel: minPrecedenceLevel,
      ),
    );
  }

  _Trampoline<T> _buildNodeWith<T>(
    Rule rule,
    int start,
    int end,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
    _Trampoline<T> Function(SymbolicNode?) cont, {
    int? minPrecedenceLevel,
  }) {
    final key = '${rule.symbolId}:$start:$end:${minPrecedenceLevel ?? 'null'}';
    if (memo.containsKey(key)) return cont(memo[key]);
    if (inProgress[key] == true) return cont(null);

    inProgress[key] = true;
    final symNode = nodeManager.symbolic(start, end, rule.symbolId!);

    return _More(
      () => _patternNodes(
        rule,
        rule.body(),
        start,
        end,
        memo,
        inProgress,
        (childNodes) {
          for (final child in childNodes) {
            symNode.addFamily(Family.unary(child));
          }

          inProgress[key] = false;
          final result = symNode.families.isNotEmpty ? symNode : null;
          memo[key] = result;

          return cont(result);
        },
        start,
        minPrecedenceLevel: minPrecedenceLevel,
      ),
    );
  }

  _Trampoline<T> _patternNodes<T>(
    Rule currentRule,
    Pattern pattern,
    int start,
    int end,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
    _Trampoline<T> Function(List<ForestNode>) continuation,
    int ruleStart, {
    int? minPrecedenceLevel,
  }) {
    switch (pattern) {
      case Token():
        if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
          return continuation([
            nodeManager.terminal(start, end, pattern.symbolId!, input.codeUnitAt(start)),
          ]);
        }
        return continuation([]);
      case Marker():
        return continuation(start == end ? [nodeManager.marker(start, pattern)] : []);
      case Eps():
        return continuation(start == end ? [nodeManager.epsilon(start, pattern.symbolId!)] : []);
      case Alt():
        return _More(
          () => _patternNodes(
            currentRule,
            pattern.left,
            start,
            end,
            memo,
            inProgress,
            (left) => _More(
              () => _patternNodes(
                currentRule,
                pattern.right,
                start,
                end,
                memo,
                inProgress,
                (right) => continuation([...left, ...right]),
                ruleStart,
                minPrecedenceLevel: minPrecedenceLevel,
              ),
            ),
            ruleStart,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
        );
      case Seq():
        IntermediateNode? seqNode;

        // Pivot optimization only works when we're processing the full rule span
        // starting from ruleStart. For sub-spans, we use exhaustive search.
        Set<int> splitPoints = bsr.pivotsFor(currentRule.symbolId!, start, end);
        _Trampoline<T> loop(Iterator<int> it) {
          if (!it.moveNext()) return continuation(seqNode != null ? [seqNode!] : []);
          final mid = it.current;
          return _More(
            () => _patternNodes(
              currentRule,
              pattern.left,
              start,
              mid,
              memo,
              inProgress,
              (leftNodes) {
                if (leftNodes.isEmpty) return _More(() => loop(it));
                return _More(
                  () => _patternNodes(
                    currentRule,
                    pattern.right,
                    mid,
                    end,
                    memo,
                    inProgress,
                    (rightNodes) {
                      if (rightNodes.isNotEmpty) {
                        seqNode ??= nodeManager.intermediate(start, end, pattern.symbolId!);
                        for (final l in leftNodes)
                          for (final r in rightNodes) seqNode!.addFamily(Family.binary(l, r));
                      }
                      return _More(() => loop(it));
                    },
                    ruleStart,
                    minPrecedenceLevel: minPrecedenceLevel,
                  ),
                );
              },
              ruleStart,
              minPrecedenceLevel: minPrecedenceLevel,
            ),
          );
        }
        return _More(() => loop(splitPoints.iterator));

      case Plus():
        IntermediateNode? plusNode;
        final pivots = bsr.pivotsFor(currentRule.symbolId!, ruleStart, end);

        _Trampoline<T> loop(Iterator<int> it) {
          if (!it.moveNext()) {
            return _More(
              () => _patternNodes(
                currentRule,
                pattern.child,
                start,
                end,
                memo,
                inProgress,
                (nodes) {
                  if (nodes.isNotEmpty) {
                    plusNode ??= nodeManager.intermediate(start, end, pattern.symbolId!);
                    for (final n in nodes) plusNode!.addFamily(Family.unary(n));
                  }
                  return continuation(plusNode != null ? [plusNode!] : []);
                },
                ruleStart,
                minPrecedenceLevel: minPrecedenceLevel,
              ),
            );
          }
          final mid = it.current;
          return _More(
            () => _patternNodes(
              currentRule,
              pattern.child,
              start,
              mid,
              memo,
              inProgress,
              (head) {
                if (head.isEmpty) return _More(() => loop(it));
                return _More(
                  () => _patternNodes(
                    currentRule,
                    pattern,
                    mid,
                    end,
                    memo,
                    inProgress,
                    (tail) {
                      if (tail.isNotEmpty) {
                        plusNode ??= nodeManager.intermediate(start, end, pattern.symbolId!);
                        for (final h in head)
                          for (final t in tail) plusNode!.addFamily(Family.binary(h, t));
                      }
                      return _More(() => loop(it));
                    },
                    ruleStart,
                    minPrecedenceLevel: minPrecedenceLevel,
                  ),
                );
              },
              ruleStart,
              minPrecedenceLevel: minPrecedenceLevel,
            ),
          );
        }
        return _More(() => loop(pivots.iterator));
      case Star():
        IntermediateNode? starNode;
        final pivots = bsr.pivotsFor(currentRule.symbolId!, ruleStart, end);

        _Trampoline<T> loop(Iterator<int> it) {
          if (!it.moveNext()) {
            if (start == end) {
              starNode ??= nodeManager.intermediate(start, end, pattern.symbolId!);
              starNode!.addFamily(Family.unary(nodeManager.epsilon(start, pattern.symbolId!)));
            }
            return continuation(starNode != null ? [starNode!] : []);
          }
          final mid = it.current;
          return _More(
            () => _patternNodes(
              currentRule,
              pattern.child,
              start,
              mid,
              memo,
              inProgress,
              (head) {
                if (head.isEmpty) return _More(() => loop(it));
                return _More(
                  () => _patternNodes(
                    currentRule,
                    pattern,
                    mid,
                    end,
                    memo,
                    inProgress,
                    (tail) {
                      if (tail.isNotEmpty) {
                        starNode ??= nodeManager.intermediate(start, end, pattern.symbolId!);
                        for (final h in head)
                          for (final t in tail) starNode!.addFamily(Family.binary(h, t));
                      }
                      return _More(() => loop(it));
                    },
                    ruleStart,
                    minPrecedenceLevel: minPrecedenceLevel,
                  ),
                );
              },
              ruleStart,
              minPrecedenceLevel: minPrecedenceLevel,
            ),
          );
        }
        return _More(() => loop(pivots.iterator));
      case Conj():
        return _More(
          () => _patternNodes(
            currentRule,
            pattern.left,
            start,
            end,
            memo,
            inProgress,
            (left) {
              if (left.isEmpty) return continuation([]);
              return _More(
                () => _patternNodes(
                  currentRule,
                  pattern.right,
                  start,
                  end,
                  memo,
                  inProgress,
                  (right) {
                    if (right.isEmpty) {
                      return continuation([]);
                    }

                    final node = nodeManager.intermediate(start, end, pattern.symbolId!);
                    for (final l in left) {
                      for (final r in right) {
                        node.addFamily(Family.binary(l, r));
                      }
                    }
                    return continuation([node]);
                  },
                  ruleStart,
                  minPrecedenceLevel: minPrecedenceLevel,
                ),
              );
            },
            ruleStart,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
        );
      case Rule():
        return _More(
          () => _patternNodes(
            pattern,
            pattern.body(),
            start,
            end,
            memo,
            inProgress,
            continuation,
            start,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
        );
      case RuleCall(minPrecedenceLevel: var prec, :var rule) ||
          Call(minPrecedenceLevel: var prec, :var rule):
        return _More(
          () => _buildNodeWith(
            rule,
            start,
            end,
            memo,
            inProgress,
            (node) => continuation(node != null ? [node] : []),
            minPrecedenceLevel: prec ?? minPrecedenceLevel,
          ),
        );
      case Action<dynamic>():
        return _More(
          () => _patternNodes(
            currentRule,
            pattern.child,
            start,
            end,
            memo,
            inProgress,
            (nodes) {
              if (nodes.isEmpty) {
                return continuation([]);
              }
              final node = nodeManager.intermediate(start, end, pattern.symbolId!);
              for (final n in nodes) {
                node.addFamily(Family.unary(n));
              }

              return continuation([node]);
            },
            ruleStart,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
        );
      case PrecedenceLabeledPattern():
        // Check if this alternative meets the minimum precedence level
        if (minPrecedenceLevel != null && pattern.precedenceLevel < minPrecedenceLevel) {
          // Skip this alternative - it doesn't meet the precedence requirement
          return continuation([]);
        }
        return _More(
          () => _patternNodes(
            currentRule,
            pattern.child,
            start,
            end,
            memo,
            inProgress,
            continuation,
            ruleStart,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
        );
      case And() || Not():
        return continuation(start == end ? [nodeManager.epsilon(start, pattern.symbolId!)] : []);
    }
  }
}
