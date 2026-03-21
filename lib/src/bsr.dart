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

class SppfBuilder {
  final BsrSet bsr;
  final ForestNodeManager nodeManager;
  final String input;

  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;

  const SppfBuilder(this.bsr, this.nodeManager, this.input, this.childrenRegistry);

  List<PatternSymbol> getChildrenOf(PatternSymbol symbol) {
    if (childrenRegistry[symbol] case List<PatternSymbol> children) {
      return children;
    }
    throw StateError("Couldn't find the children of $symbol.");
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
        final patternToEval = getChildrenOf(task.ruleSymbol).single;

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
        valueStack.add([...leftRes, ...rightRes]);
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
      }
    }

    return valueStack.removeLast() as SymbolicNode?;
  }

  void _executePatternTask(_EvalPattern task, List<_Task> taskStack, List<Object?> valueStack) {
    final pattern = task.pattern as String;
    final start = task.start;
    final end = task.end;

    final [prefix, _, suffix] = pattern.split(":");
    switch (prefix) {
      case "eps":
        valueStack.add(start == end ? [nodeManager.epsilon(start, task.pattern)] : <ForestNode>[]);
      case "tok":
        {
          late bool isMatching = switch (suffix[0]) {
            "." => true,
            ";" => input.codeUnitAt(start) == int.parse(suffix.substring(1)),
            "<" => input.codeUnitAt(start) <= int.parse(suffix.substring(1)),
            ">" => input.codeUnitAt(start) >= int.parse(suffix.substring(1)),
            "[" => () {
              final unit = input.codeUnitAt(start);
              final [min, max] = suffix.substring(1).split(",").map(int.parse).toList();

              return min <= unit && unit <= max;
            }(),
            _ => throw Exception(suffix[0]),
          };
          if (start + 1 == end && isMatching) {
            valueStack.add([
              nodeManager.terminal(start, end, task.pattern, input.codeUnitAt(start)),
            ]);
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
          final prec = suffix.isEmpty ? null : int.parse(suffix);
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
          if (task.minPrecedenceLevel != null && int.parse(suffix) < task.minPrecedenceLevel!) {
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
