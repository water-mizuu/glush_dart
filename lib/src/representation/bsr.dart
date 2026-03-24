/// Binary Subtree Representation (BSR) for compact derivation recording.
///
/// A BSR set is populated *during* parsing. Each entry records that a rule
/// was successfully completed over a specific input span.  The SPPF can then
/// be derived on-demand from these entries rather than from an exhaustive
/// grammar walk.
///
/// Reference: Scott & Johnstone, "GLL Parse-Tree Generation" (2013).
library glush.bsr;

import 'dart:collection';

import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/core/mark.dart';
import 'package:glush/src/core/patterns.dart';
import 'sppf.dart';

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
    assert(
      start <= pivot && pivot <= end,
      'Invariant violation in BsrSet.add: expected start <= pivot <= end, '
      'got ($start, $pivot, $end).',
    );
    _pivots.putIfAbsent((patternSymbol, start, end), Set.new).add((pivot));
  }

  /// Total number of recorded rule-completion entries.
  int get length => _pivots.values.expand((v) => v).length;
  Iterable<BsrEntry> get entries =>
      _pivots.entries.expand((e) => e.value.map((v) => (e.key.$1, e.key.$2, e.key.$3, v)));

  Set<int> pivotsFor(PatternSymbol ruleSymbol, int start, int end) {
    assert(
      start <= end,
      'Invariant violation in BsrSet.pivotsFor: expected start <= end, got ($start, $end).',
    );
    final pivots = _pivots[(ruleSymbol, start, end)];
    if (pivots == null) return const {};
    return UnmodifiableSetView(pivots);
  }

  /// Build an SPPF rooted at [startRule] over the full input.
  SymbolicNode? buildSppf(
    GrammarInterface grammar,
    PatternSymbol startSymbol,
    String input,
    ForestNodeManager nodeManager,
  ) {
    final memo = <String, SymbolicNode?>{};
    final inProgress = <String, bool>{};

    return SppfBuilder(this, nodeManager, input, grammar.childrenRegistry) //
        .buildNode(startSymbol, 0, input.length, memo, inProgress);
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

sealed class _Task {
  const _Task();
}

// --- Core Execution Tasks ---
class _DoBuildNode extends _Task {
  final String key;
  final PatternSymbol ruleSymbol;
  final int start, end;
  final int? minPrecedenceLevel;
  final bool isRoot;

  const _DoBuildNode(
    this.key,
    this.ruleSymbol,
    this.start,
    this.end,
    this.minPrecedenceLevel, {
    this.isRoot = false,
  });
}

class _EvalPattern extends _Task {
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start, end, ruleStart;
  final int? minPrecedenceLevel;

  const _EvalPattern(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
  );
}

// --- Continuation Tasks (Replacing callbacks) ---
class _ContBuildNodeFinish extends _Task {
  final SymbolicNode symNode;
  final String key;
  const _ContBuildNodeFinish(this.symNode, this.key);
}

class _ContAltCombine extends _Task {
  const _ContAltCombine();
}

class _ContRuleCallFinish extends _Task {
  const _ContRuleCallFinish();
}

class _ContActionFinish extends _Task {
  final int start, end;
  final PatternSymbol symbolId;
  const _ContActionFinish(this.start, this.end, this.symbolId);
}

// --- Loop State Tasks ---
class _ContSeqLoop extends _Task {
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start, end, ruleStart;
  final int? minPrecedenceLevel;
  final Iterator<int> it;
  IntermediateNode? seqNode;

  _ContSeqLoop(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
    this.it,
  );
}

class _ContSeqLeft extends _Task {
  final _ContSeqLoop loopTask;
  final int mid;
  _ContSeqLeft(this.loopTask, this.mid);
}

class _ContSeqRight extends _Task {
  final _ContSeqLoop loopTask;
  final List<ForestNode> leftNodes;
  _ContSeqRight(this.loopTask, this.leftNodes);
}

class _ContRepLoop extends _Task {
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start, end, ruleStart;
  final int? minPrecedenceLevel;
  final Iterator<int> it;
  IntermediateNode? repNode;

  _ContRepLoop(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
    this.it,
  );
}

class _ContRepBase extends _Task {
  final _ContRepLoop loopTask;
  _ContRepBase(this.loopTask);
}

class _ContRepEpsilon extends _Task {
  final _ContRepLoop loopTask;
  _ContRepEpsilon(this.loopTask);
}

class _ContRepLeft extends _Task {
  final _ContRepLoop loopTask;
  final int mid;
  _ContRepLeft(this.loopTask, this.mid);
}

class _ContRepRight extends _Task {
  final _ContRepLoop loopTask;
  final List<ForestNode> leftNodes;
  _ContRepRight(this.loopTask, this.leftNodes);
}

class _ContOptChoose extends _Task {
  final int start, end;
  final PatternSymbol pattern;

  const _ContOptChoose(this.start, this.end, this.pattern);
}

class _ContConjLeft extends _Task {
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start, end, ruleStart;
  final int? minPrecedenceLevel;

  const _ContConjLeft(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
  );
}

class _ContConjRight extends _Task {
  final _ContConjLeft startTask;
  final List<ForestNode> leftNodes;

  const _ContConjRight(this.startTask, this.leftNodes);
}

class _AscendingIntIterator implements Iterator<int> {
  int _cursor;
  final int _endInclusive;
  int _current = 0;

  _AscendingIntIterator(int startInclusive, this._endInclusive) : _cursor = startInclusive - 1;

  @override
  int get current => _current;

  @override
  bool moveNext() {
    final next = _cursor + 1;
    if (next > _endInclusive) return false;
    _cursor = next;
    _current = next;
    return true;
  }
}

class SppfBuilder {
  final BsrSet bsr;
  final ForestNodeManager nodeManager;
  final String input;
  final Map<PatternSymbol, (String prefix, String suffix)> _patternParts = {};
  final Map<PatternSymbol, (int kind, int a, int b)> _tokenSpec = {};
  final Map<PatternSymbol, int> _suffixInt = {};

  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;

  SppfBuilder(this.bsr, this.nodeManager, this.input, this.childrenRegistry);

  List<PatternSymbol> getChildrenOf(PatternSymbol symbol) {
    if (childrenRegistry[symbol] case List<PatternSymbol> children) {
      return children;
    }
    throw StateError("Couldn't find the children of $symbol.");
  }

  (String prefix, String suffix) _patternPrefixAndSuffix(PatternSymbol pattern) {
    return _patternParts.putIfAbsent(pattern, () {
      final value = pattern as String;
      final firstColon = value.indexOf(':');
      if (firstColon == -1) return (value, '');
      final secondColon = value.indexOf(':', firstColon + 1);
      if (secondColon == -1) {
        return (value.substring(0, firstColon), value.substring(firstColon + 1));
      }
      return (value.substring(0, firstColon), value.substring(secondColon + 1));
    });
  }

  (int kind, int a, int b) _tokenMatcher(PatternSymbol pattern, String suffix) {
    return _tokenSpec.putIfAbsent(pattern, () {
      final tag = suffix[0];
      switch (tag) {
        case '.':
          return (0, 0, 0);
        case ';':
          return (1, int.parse(suffix.substring(1)), 0);
        case '<':
          return (2, int.parse(suffix.substring(1)), 0);
        case '>':
          return (3, int.parse(suffix.substring(1)), 0);
        case '[':
          final body = suffix.substring(1);
          final commaIndex = body.indexOf(',');
          final min = int.parse(body.substring(0, commaIndex));
          final max = int.parse(body.substring(commaIndex + 1));
          return (4, min, max);
        default:
          throw Exception(tag);
      }
    });
  }

  int _parsedSuffixInt(PatternSymbol pattern, String suffix) {
    return _suffixInt.putIfAbsent(pattern, () => int.parse(suffix));
  }

  // Unified public API - returns synchronously
  SymbolicNode? buildNode(
    PatternSymbol ruleSymbol,
    int start,
    int end,
    Map<String, SymbolicNode?> memo,
    Map<String, bool> inProgress, {
    int? minPrecedenceLevel,
  }) {
    assert(
      start <= end,
      'Invariant violation in SppfBuilder.buildNode: expected start <= end, got ($start, $end).',
    );
    final key = '$ruleSymbol:$start:$end';

    // The Two-Stack VM
    final taskStack = <_Task>[
      _DoBuildNode(key, ruleSymbol, start, end, minPrecedenceLevel, isRoot: true),
    ];
    final valueStack = <Object?>[]; // Holds List<ForestNode> and SymbolicNode?

    while (taskStack.isNotEmpty) {
      final task = taskStack.removeLast();

      if (task is _DoBuildNode) {
        if (memo.containsKey(task.key)) {
          valueStack.add(memo[task.key]);
          continue;
        }
        if (inProgress[task.key] == true) {
          valueStack.add(null);
          continue;
        }

        inProgress[task.key] = true;
        final symNode = nodeManager.symbolic(task.start, task.end, task.ruleSymbol);

        // 2. Schedule the completion logic for AFTER the pattern evaluates
        taskStack.add(_ContBuildNodeFinish(symNode, task.key));

        // 1. Evaluate the pattern
        final children = getChildrenOf(task.ruleSymbol);
        assert(
          children.length == 1,
          'Invariant violation in buildNode: symbol ${task.ruleSymbol} must '
          'map to exactly one root pattern, got ${children.length}.',
        );
        final patternToEval = children.single;

        taskStack.add(
          _EvalPattern(
            task.ruleSymbol,
            patternToEval,
            task.start,
            task.end,
            task.start,
            task.minPrecedenceLevel,
          ),
        );
      } else if (task is _ContBuildNodeFinish) {
        final childNodes = valueStack.removeLast() as List<ForestNode>;
        for (final child in childNodes) {
          task.symNode.addFamily(Family.unary(child));
        }

        inProgress[task.key] = false;
        final result = task.symNode.families.isNotEmpty ? task.symNode : null;
        memo[task.key] = result;
        valueStack.add(result);
      } else if (task is _EvalPattern) {
        _executePatternTask(task, taskStack, valueStack);
      }
      // --- Structural Continuations ---
      else if (task is _ContAltCombine) {
        final rightRes = valueStack.removeLast() as List<ForestNode>;
        final leftRes = valueStack.removeLast() as List<ForestNode>;
        final merged = <ForestNode>[];
        merged.addAll(leftRes);
        merged.addAll(rightRes);
        valueStack.add(merged);
      } else if (task is _ContRuleCallFinish) {
        final node = valueStack.removeLast() as SymbolicNode?;
        valueStack.add(node != null ? [node] : <ForestNode>[]);
      } else if (task is _ContActionFinish) {
        final nodes = valueStack.removeLast() as List<ForestNode>;
        if (nodes.isEmpty) {
          valueStack.add(<ForestNode>[]);
        } else {
          final node = nodeManager.intermediate(task.start, task.end, task.symbolId);
          for (final n in nodes) node.addFamily(Family.unary(n));
          valueStack.add([node]);
        }
      }
      // --- Conj ---
      else if (task is _ContConjLeft) {
        final leftNodes = valueStack.removeLast() as List<ForestNode>;
        if (leftNodes.isEmpty) {
          valueStack.add(<ForestNode>[]); // Short circuit
        } else {
          taskStack.add(_ContConjRight(task, leftNodes));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).last,
              task.start,
              task.end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      } else if (task is _ContConjRight) {
        final rightNodes = valueStack.removeLast() as List<ForestNode>;
        if (rightNodes.isEmpty) {
          valueStack.add(<ForestNode>[]);
        } else {
          final node = nodeManager.intermediate(
            task.startTask.start,
            task.startTask.end,
            task.startTask.pattern,
          );
          for (final l in task.leftNodes) {
            for (final r in rightNodes) node.addFamily(Family.binary(l, r));
          }
          valueStack.add([node]);
        }
      }
      // --- Seq Loop ---
      else if (task is _ContSeqLoop) {
        if (!task.it.moveNext()) {
          valueStack.add(task.seqNode != null ? [task.seqNode!] : <ForestNode>[]);
        } else {
          final mid = task.it.current;
          taskStack.add(task); // Re-queue loop state
          taskStack.add(_ContSeqLeft(task, mid));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).first,
              task.start,
              mid,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      } else if (task is _ContSeqLeft) {
        final leftNodes = valueStack.removeLast() as List<ForestNode>;
        if (leftNodes.isEmpty) {
          // Skip right evaluation, let loop continue on next tick
        } else {
          taskStack.add(_ContSeqRight(task.loopTask, leftNodes));
          taskStack.add(
            _EvalPattern(
              task.loopTask.currentRule,
              getChildrenOf(task.loopTask.pattern).last,
              task.mid,
              task.loopTask.end,
              task.loopTask.ruleStart,
              task.loopTask.minPrecedenceLevel,
            ),
          );
        }
      } else if (task is _ContSeqRight) {
        final rightNodes = valueStack.removeLast() as List<ForestNode>;
        if (rightNodes.isNotEmpty) {
          task.loopTask.seqNode ??= nodeManager.intermediate(
            task.loopTask.start,
            task.loopTask.end,
            task.loopTask.pattern,
          );
          for (final l in task.leftNodes) {
            for (final r in rightNodes) task.loopTask.seqNode!.addFamily(Family.binary(l, r));
          }
        }
      } else if (task is _ContRepEpsilon) {
        task.loopTask.repNode ??= nodeManager.intermediate(
          task.loopTask.start,
          task.loopTask.end,
          task.loopTask.pattern,
        );
        task.loopTask.repNode!.addFamily(
          Family.unary(nodeManager.epsilon(task.loopTask.start, task.loopTask.pattern)),
        );
      } else if (task is _ContRepBase) {
        final baseNodes = valueStack.removeLast() as List<ForestNode>;
        if (baseNodes.isNotEmpty) {
          task.loopTask.repNode ??= nodeManager.intermediate(
            task.loopTask.start,
            task.loopTask.end,
            task.loopTask.pattern,
          );
          for (final base in baseNodes) {
            task.loopTask.repNode!.addFamily(Family.unary(base));
          }
        }
      } else if (task is _ContRepLoop) {
        if (!task.it.moveNext()) {
          valueStack.add(task.repNode != null ? [task.repNode!] : <ForestNode>[]);
        } else {
          final mid = task.it.current;
          taskStack.add(task);
          taskStack.add(_ContRepLeft(task, mid));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).single,
              task.start,
              mid,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      } else if (task is _ContRepLeft) {
        final leftNodes = valueStack.removeLast() as List<ForestNode>;
        if (leftNodes.isNotEmpty) {
          taskStack.add(_ContRepRight(task.loopTask, leftNodes));
          taskStack.add(
            _EvalPattern(
              task.loopTask.currentRule,
              task.loopTask.pattern,
              task.mid,
              task.loopTask.end,
              task.loopTask.ruleStart,
              task.loopTask.minPrecedenceLevel,
            ),
          );
        }
      } else if (task is _ContRepRight) {
        final rightNodes = valueStack.removeLast() as List<ForestNode>;
        if (rightNodes.isNotEmpty) {
          task.loopTask.repNode ??= nodeManager.intermediate(
            task.loopTask.start,
            task.loopTask.end,
            task.loopTask.pattern,
          );
          for (final l in task.leftNodes) {
            for (final r in rightNodes) {
              task.loopTask.repNode!.addFamily(Family.binary(l, r));
            }
          }
        }
      } else if (task is _ContOptChoose) {
        final childNodes = valueStack.removeLast() as List<ForestNode>;
        if (childNodes.isNotEmpty) {
          valueStack.add(childNodes);
        } else if (task.start == task.end) {
          valueStack.add([nodeManager.epsilon(task.start, task.pattern)]);
        } else {
          valueStack.add(<ForestNode>[]);
        }
      }
    }

    return valueStack.removeLast() as SymbolicNode?;
  }

  void _executePatternTask(_EvalPattern task, List<_Task> taskStack, List<Object?> valueStack) {
    final start = task.start;
    final end = task.end;

    final (prefix, suffix) = _patternPrefixAndSuffix(task.pattern);
    switch (prefix) {
      case "eps":
        valueStack.add(start == end ? [nodeManager.epsilon(start, task.pattern)] : <ForestNode>[]);
      case "tok":
        {
          if (start + 1 == end) {
            assert(
              start >= 0 && start < input.length,
              'Invariant violation in _executePatternTask(tok): span [$start,$end) '
              'must index into input length ${input.length}.',
            );
            final unit = input.codeUnitAt(start);
            final (kind, a, b) = _tokenMatcher(task.pattern, suffix);
            final isMatching = switch (kind) {
              0 => true,
              1 => unit == a,
              2 => unit <= a,
              3 => unit >= a,
              4 => a <= unit && unit <= b,
              _ => false,
            };
            if (isMatching) {
              valueStack.add([
                nodeManager.terminal(start, end, task.pattern, unit),
              ]);
            } else {
              valueStack.add(const <ForestNode>[]);
            }
          } else {
            valueStack.add(const <ForestNode>[]);
          }
        }
      case "mar":
        {
          valueStack.add(
            (start == end) //
                ? [nodeManager.marker(start, task.pattern, suffix)]
                : const <ForestNode>[],
          );
        }
      case "las":
      case "lae":
        {
          valueStack.add(
            (start == end) //
                ? [nodeManager.marker(start, task.pattern, suffix)]
                : const <ForestNode>[],
          );
        }
      case "and":
      case "not":
        {
          valueStack.add(
            (start == end) //
                ? [nodeManager.epsilon(start, task.pattern)]
                : <ForestNode>[],
          );
        }
      case "alt":
        {
          taskStack.add(_ContAltCombine());

          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).last,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).first,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "lab":
        {
          taskStack.add(_ContActionFinish(start, end, task.pattern));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).single,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "opt":
        {
          taskStack.add(_ContOptChoose(start, end, task.pattern));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).single,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "seq":
        {
          final pivots = bsr.pivotsFor(task.currentRule, start, end);
          taskStack.add(
            _ContSeqLoop(
              task.currentRule,
              task.pattern,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
              pivots.iterator,
            ),
          );
        }
      case "sta":
        {
          final mids = _AscendingIntIterator(start + 1, end);
          final loop = _ContRepLoop(
            task.currentRule,
            task.pattern,
            start,
            end,
            task.ruleStart,
            task.minPrecedenceLevel,
            mids,
          );
          taskStack.add(loop);
          if (start == end) {
            taskStack.add(_ContRepEpsilon(loop));
          }
        }
      case "plu":
        {
          final mids = _AscendingIntIterator(start + 1, end);
          final loop = _ContRepLoop(
            task.currentRule,
            task.pattern,
            start,
            end,
            task.ruleStart,
            task.minPrecedenceLevel,
            mids,
          );
          taskStack.add(loop);
          taskStack.add(_ContRepBase(loop));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).single,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "con":
        {
          taskStack.add(
            _ContConjLeft(
              task.currentRule,
              task.pattern,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).first,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "rul":
        {
          taskStack.add(
            _EvalPattern(
              task.pattern,
              getChildrenOf(task.pattern).single,
              start,
              end,
              start,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "rca":
        {
          final prec = suffix.isEmpty ? null : _parsedSuffixInt(task.pattern, suffix);
          final effectivePrec = prec ?? task.minPrecedenceLevel;
          final toCall = getChildrenOf(task.pattern).single;
          final key = '$toCall:$start:$end:${effectivePrec ?? 'null'}';

          taskStack.add(_ContRuleCallFinish());
          taskStack.add(_DoBuildNode(key, toCall, start, end, effectivePrec));
        }
      case "act":
        {
          taskStack.add(_ContActionFinish(start, end, task.pattern));
          taskStack.add(
            _EvalPattern(
              task.currentRule,
              getChildrenOf(task.pattern).single,
              start,
              end,
              task.ruleStart,
              task.minPrecedenceLevel,
            ),
          );
        }
      case "pre":
        {
          if (task.minPrecedenceLevel != null &&
              _parsedSuffixInt(task.pattern, suffix) < task.minPrecedenceLevel!) {
            valueStack.add(<ForestNode>[]); // Skip
          } else {
            taskStack.add(
              _EvalPattern(
                task.currentRule,
                getChildrenOf(task.pattern).single,
                start,
                end,
                task.ruleStart,
                task.minPrecedenceLevel,
              ),
            );
          }
        }
      case _:
        throw StateError("Unhandled case: $prefix");
    }
  }
}
