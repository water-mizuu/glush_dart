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

/// A single rule-completion entry in the BSR.
///
/// Records that [rule] was successfully parsed over the input span
/// [[leftExtent], [rightExtent]).
typedef BsrEntry = (Pattern rule, int leftExtent, int rightExtent);

extension BsrEntryMethods on BsrEntry {
  Pattern get rule => $1;
  int get leftExtent => $2;
  int get rightExtent => $3;
}

/// The set of all [BsrEntry] instances accumulated during a parse.
///
/// Can be queried to check which rules were proven to match which spans,
/// and can construct an SPPF on demand restricted to proven spans.
class BsrSet {
  final Set<BsrEntry> _entries = {};

  /// Add a rule-completion entry.
  void add(Pattern rule, int leftExtent, int rightExtent) {
    _entries.add((rule, leftExtent, rightExtent));
  }

  /// Returns true if [rule] was proven to match [[left], [right]).
  bool contains(Pattern rule, int left, int right) => _entries.contains((rule, left, right));

  /// Returns all entries for the given rule.
  Iterable<BsrEntry> entriesForRule(Rule rule) => _entries.where((e) => e.rule == rule);

  /// Returns all entries matching a given span (any rule).
  Iterable<BsrEntry> entriesForSpan(int left, int right) =>
      _entries.where((e) => e.leftExtent == left && e.rightExtent == right);

  /// Total number of recorded rule-completion entries.
  int get length => _entries.length;

  /// Build an SPPF rooted at [startRule] over the full input of length
  /// [inputLength], using only spans that are proven in this BSR set.
  ///
  /// Returns null if the start rule has no proven entry for [0, inputLength].
  SymbolicNode? buildSppf(
    Rule startRule,
    String input,
    ForestNodeManager nodeManager,
  ) {
    final memo = <String, SymbolicNode?>{};
    final inProgress = <String, bool>{};
    return _buildNode(startRule, input, 0, input.length, nodeManager, memo, inProgress).run();
  }

  // ---------------------------------------------------------------------------
  // Internal SPPF construction (BSR-guided grammar walk)
  // ---------------------------------------------------------------------------
  _Trampoline<SymbolicNode?> _buildNode(
    Rule rule,
    String input,
    int start,
    int end,
    ForestNodeManager nodeManager,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress,
  ) {
    // Fast-fail: only build SPPF for spans the BSR proves are reachable.
    if (!contains(rule, start, end)) return _Done(null);

    final key = '${rule.symbolId}:$start:$end';
    if (memo.containsKey(key)) return _Done(memo[key]);
    if (inProgress[key] == true) return _Done(null);

    inProgress[key] = true;
    final symNode = nodeManager.symbolic(start, end, rule);

    return _More(() => _patternNodes(
          rule.body(),
          input,
          start,
          end,
          nodeManager,
          memo,
          inProgress,
          (childNodes) {
            for (final child in childNodes) {
              // Rule nodes now strictly point to 1 child (which may be an IntermediateNode handling the rest)
              symNode.addFamily(Family([child]));
            }

            inProgress[key] = false;
            final result = symNode.families.isNotEmpty ? symNode : null;
            memo[key] = result;
            return _Done(result);
          },
        ));
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
        return _More(() => _patternNodes(
              pattern.left,
              input,
              start,
              end,
              nodeManager,
              memo,
              inProgress,
              (leftNodes) => _More(() => _patternNodes(
                    pattern.right,
                    input,
                    start,
                    end,
                    nodeManager,
                    memo,
                    inProgress,
                    (rightNodes) => continuation([...leftNodes, ...rightNodes]),
                  )),
            ));
      case Seq():
        IntermediateNode? seqNode;

        _Trampoline<T> loop(int mid) {
          if (mid > end) return continuation(seqNode != null ? [seqNode!] : []);

          return _More(() => _patternNodes(
                pattern.left,
                input,
                start,
                mid,
                nodeManager,
                memo,
                inProgress,
                (leftNodes) {
                  if (leftNodes.isEmpty) return _More(() => loop(mid + 1));

                  return _More(() => _patternNodes(
                        pattern.right,
                        input,
                        mid,
                        end,
                        nodeManager,
                        memo,
                        inProgress,
                        (rightNodes) {
                          if (rightNodes.isNotEmpty) {
                            // Hoisted intermediate creation: strictly packed and binarised
                            seqNode ??= nodeManager.intermediate(start, end, pattern, 'Seq');
                            for (final l in leftNodes) {
                              for (final r in rightNodes) {
                                seqNode!.addFamily(Family([l, r]));
                              }
                            }
                          }
                          return _More(() => loop(mid + 1));
                        },
                      ));
                },
              ));
        }

        return _More(() => loop(start));
      case Conj():
        if (start + 1 == end &&
            pattern.left.match(input.codeUnitAt(start)) &&
            pattern.right.match(input.codeUnitAt(start))) {
          final termNode = nodeManager.terminal(start, end, pattern, input.codeUnitAt(start));
          return continuation([termNode]);
        }
        return continuation([]);
      case Plus():
        IntermediateNode? plusNode;

        _Trampoline<T> loop(int mid) {
          if (mid > end) {
            return _More(() => _patternNodes(
                  pattern.child,
                  input,
                  start,
                  end,
                  nodeManager,
                  memo,
                  inProgress,
                  (singleNodes) {
                    if (singleNodes.isNotEmpty) {
                      plusNode ??= nodeManager.intermediate(start, end, pattern, 'Plus');
                      for (final s in singleNodes) {
                        plusNode!.addFamily(Family([s]));
                      }
                    }
                    return continuation(plusNode != null ? [plusNode!] : []);
                  },
                ));
          }

          return _More(() => _patternNodes(
                pattern.child,
                input,
                start,
                mid,
                nodeManager,
                memo,
                inProgress,
                (headNodes) {
                  if (headNodes.isEmpty) return _More(() => loop(mid + 1));

                  return _More(() => _patternNodes(
                        pattern,
                        input,
                        mid,
                        end,
                        nodeManager,
                        memo,
                        inProgress,
                        (tailNodes) {
                          if (tailNodes.isNotEmpty) {
                            plusNode ??= nodeManager.intermediate(start, end, pattern, 'Plus');
                            for (final h in headNodes) {
                              for (final t in tailNodes) {
                                plusNode!.addFamily(Family([h, t]));
                              }
                            }
                          }
                          return _More(() => loop(mid + 1));
                        },
                      ));
                },
              ));
        }

        return _More(() => loop(start + 1));
      case Star():
        IntermediateNode? starNode;

        _Trampoline<T> loop(int mid) {
          if (mid > end) {
            if (start == end) {
              starNode ??= nodeManager.intermediate(start, end, pattern, 'Star');
              starNode!.addFamily(Family([nodeManager.epsilon(start, pattern)]));
            }
            return continuation(starNode != null ? [starNode!] : []);
          }

          return _More(() => _patternNodes(
                pattern.child,
                input,
                start,
                mid,
                nodeManager,
                memo,
                inProgress,
                (headNodes) {
                  if (headNodes.isEmpty) return _More(() => loop(mid + 1));

                  return _More(() => _patternNodes(
                        pattern,
                        input,
                        mid,
                        end,
                        nodeManager,
                        memo,
                        inProgress,
                        (tailNodes) {
                          if (tailNodes.isNotEmpty) {
                            starNode ??= nodeManager.intermediate(start, end, pattern, 'Star');
                            for (final h in headNodes) {
                              for (final t in tailNodes) {
                                starNode!.addFamily(Family([h, t]));
                              }
                            }
                          }
                          return _More(() => loop(mid + 1));
                        },
                      ));
                },
              ));
        }

        return _More(() => loop(start + 1));
      case And() || Not():
        if (start == end) {
          return continuation([nodeManager.epsilon(start, pattern)]);
        }
        return continuation([]);
      case Rule():
        return _More(() => _patternNodes(
              pattern.body(),
              input,
              start,
              end,
              nodeManager,
              memo,
              inProgress,
              continuation,
            ));
      case RuleCall(:var rule) || Call(:var rule):
        return _More(() => _buildNode(rule, input, start, end, nodeManager, memo, inProgress)
            .then((child) => continuation(child != null ? [child] : [])));
      case Action<dynamic>():
        return _More(() => _patternNodes(
              pattern.child,
              input,
              start,
              end,
              nodeManager,
              memo,
              inProgress,
              (childNodes) {
                if (childNodes.isEmpty) return continuation([]);

                final node = nodeManager.intermediate(start, end, pattern, 'Action<T>');
                for (final child in childNodes) {
                  node.addFamily(Family([child]));
                }
                return continuation([node]);
              },
            ));
      case PrecedenceLabeledPattern():
        return _More(() => _patternNodes(
              pattern.pattern,
              input,
              start,
              end,
              nodeManager,
              memo,
              inProgress,
              continuation,
            ));
    }
  }

  @override
  String toString() => 'BsrSet(${_entries.length} entries)';
}

// ---------------------------------------------------------------------------
// Parse outcome types for BSR-based parsing
// ---------------------------------------------------------------------------

/// Sealed result type for [SMParser.parseToBsr].
sealed class BsrParseOutcome {}

/// Returned when BSR parsing fails.
final class BsrParseError implements BsrParseOutcome, Exception {
  final int position;

  const BsrParseError(this.position);

  @override
  String toString() => 'BsrParseError at position $position';
}

/// Returned when BSR parsing succeeds. Contains the [BsrSet] of proven spans.
final class BsrParseSuccess implements BsrParseOutcome {
  final BsrSet bsrSet;
  final List<Mark> marks;

  const BsrParseSuccess(this.bsrSet, this.marks);

  @override
  String toString() => 'BsrParseSuccess($bsrSet)';
}
