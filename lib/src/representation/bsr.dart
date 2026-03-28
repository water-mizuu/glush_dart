/// Binary Subtree Representation (BSR) for compact derivation recording.
///
/// A BSR set is populated *during* parsing. Each entry records that a rule
/// was successfully completed over a specific input span.  The SPPF can then
/// be derived on-demand from these entries rather than from an exhaustive
/// grammar walk.
///
/// Reference: Scott & Johnstone, "GLL Parse-Tree Generation" (2013).
library glush.bsr;

import "dart:collection";

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/representation/sppf.dart";

/// A BSR entry (RuleSlot, start, pivot, end) according to Scott & Johnstone.
typedef BsrEntry = (PatternSymbol slot, int start, int pivot, int end);

/// A recorded terminal match for SPPF reconstruction.
typedef BsrTerminalEntry = (PatternSymbol symbol, int start, int end, int token);

extension BsrEntryMethods on BsrEntry {
  PatternSymbol get slot => $1;
  int get start => $2;
  int get pivot => $3;
  int get end => $4;
}

extension BsrTerminalEntryMethods on BsrTerminalEntry {
  PatternSymbol get symbol => $1;
  int get start => $2;
  int get end => $3;
  int get token => $4;
}

extension type const BsrPattern(String thing) {}

/// The set of all [BsrEntry] instances accumulated during a parse.
class BsrSet {
  final Map<(PatternSymbol, int start, int end), Set<int>> _pivots = {};
  final Map<(PatternSymbol, int start, int end), int> _terminals = {};

  // Secondary indexes for fast range queries
  final Map<(PatternSymbol, int start), Set<int>> _endsBySymbolStart = {};
  final Map<(PatternSymbol, int start), Set<int>> _terminalEndsBySymbolStart = {};

  /// Add a rule-completion entry.
  void add(PatternSymbol patternSymbol, int start, int pivot, int end) {
    assert(
      start <= pivot && pivot <= end,
      "Invariant violation in BsrSet.add: expected start <= pivot <= end, "
      "got ($start, $pivot, $end).",
    );
    _pivots.putIfAbsent((patternSymbol, start, end), Set.new).add(pivot);
    _endsBySymbolStart.putIfAbsent((patternSymbol, start), Set.new).add(end);
  }

  /// Record the exact token matched by a terminal symbol.
  void addTerminal(PatternSymbol symbol, int start, int end, int token) {
    assert(
      start + 1 == end,
      "Invariant violation in BsrSet.addTerminal: expected a single-token span, "
      "got ($start, $end).",
    );
    var key = (symbol, start, end);
    var existing = _terminals[key];
    assert(
      existing == null || existing == token,
      "Invariant violation in BsrSet.addTerminal: conflicting token payload "
      "for $symbol at [$start, $end).",
    );
    _terminals[key] = token;
    _terminalEndsBySymbolStart.putIfAbsent((symbol, start), Set.new).add(end);
  }

  /// Total number of recorded rule-completion entries.
  int get length => _pivots.values.expand((v) => v).length + _terminals.length;
  Iterable<BsrEntry> get entries =>
      _pivots.entries.expand((e) => e.value.map((v) => (e.key.$1, e.key.$2, e.key.$3, v)));

  Iterable<BsrTerminalEntry> get terminalEntries =>
      _terminals.entries.map((e) => (e.key.$1, e.key.$2, e.key.$3, e.value));

  Set<int> pivotsFor(PatternSymbol ruleSymbol, int start, int end) {
    assert(
      start <= end,
      "Invariant violation in BsrSet.pivotsFor: expected start <= end, got ($start, $end).",
    );
    var pivots = _pivots[(ruleSymbol, start, end)];
    if (pivots == null) {
      return const {};
    }
    return UnmodifiableSetView(pivots);
  }

  int? tokenFor(PatternSymbol symbol, int start, int end) {
    return _terminals[(symbol, start, end)];
  }

  /// Returns all end positions for a given symbol and start position.
  Iterable<int> endsFor(PatternSymbol symbol, int start) {
    return _endsBySymbolStart[(symbol, start)] ?? const [];
  }

  /// Returns all terminal end positions for a given symbol and start position.
  Iterable<int> terminalEndsFor(PatternSymbol symbol, int start) {
    return _terminalEndsBySymbolStart[(symbol, start)] ?? const [];
  }

  /// Build an SPPF rooted at [startSymbol] over the full input.
  SymbolicNode buildSppf(
    GrammarInterface grammar,
    PatternSymbol startSymbol,
    String input,
    ForestNodeCache nodeCache,
  ) {
    var memo = <String, SymbolicNode?>{};
    var inProgress = <String, bool>{};
    var root =
        SppfBuilder(this, nodeCache, grammar.childrenRegistry, input.length) //
            .buildNode(startSymbol, 0, input.length, memo, inProgress);
    return root ?? nodeCache.symbolic(0, input.length, startSymbol);
  }

  @override
  String toString() => "BsrSet(${_pivots.length} entries)";
}

sealed class BsrParseOutcome {}

final class BsrParseError implements BsrParseOutcome, Exception {
  const BsrParseError(this.position);
  final int position;
}

final class BsrParseSuccess implements BsrParseOutcome {
  const BsrParseSuccess(this.bsrSet, this.marks);
  final BsrSet bsrSet;
  final List<Mark> marks;
}

sealed class _Task {
  const _Task();
}

// --- Core Execution Tasks ---
class _DoBuildNode extends _Task {
  const _DoBuildNode(
    this.key,
    this.ruleSymbol,
    this.start,
    this.end,
    this.minPrecedenceLevel, {
    this.isRoot = false,
  });
  final String key;
  final PatternSymbol ruleSymbol;
  final int start;
  final int end;
  final int? minPrecedenceLevel;
  final bool isRoot;
}

class _EvalPattern extends _Task {
  const _EvalPattern(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
  );
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start;
  final int end;
  final int ruleStart;
  final int? minPrecedenceLevel;
}

// --- Continuation Tasks (Replacing callbacks) ---
class _ContBuildNodeFinish extends _Task {
  const _ContBuildNodeFinish(this.symNode, this.key, this.ruleSymbol);
  final SymbolicNode symNode;
  final String key;
  final PatternSymbol ruleSymbol;
}

class _ContAltCombine extends _Task {
  const _ContAltCombine();
}

class _ContRuleCallFinish extends _Task {
  const _ContRuleCallFinish();
}

class _ContActionFinish extends _Task {
  const _ContActionFinish(this.start, this.end, this.symbolId);
  final int start;
  final int end;
  final PatternSymbol symbolId;
}

// --- Loop State Tasks ---
class _ContSeqLoop extends _Task {
  _ContSeqLoop(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
    this.it,
  );
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start;
  final int end;
  final int ruleStart;
  final int? minPrecedenceLevel;
  final Iterator<int> it;
  IntermediateNode? seqNode;
}

class _ContSeqLeft extends _Task {
  _ContSeqLeft(this.loopTask, this.mid);
  final _ContSeqLoop loopTask;
  final int mid;
}

class _ContSeqRight extends _Task {
  _ContSeqRight(this.loopTask, this.leftNodes);
  final _ContSeqLoop loopTask;
  final List<ForestNode> leftNodes;
}

class _ContRepLoop extends _Task {
  _ContRepLoop(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
    this.it,
  );
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start;
  final int end;
  final int ruleStart;
  final int? minPrecedenceLevel;
  final Iterator<int> it;
  IntermediateNode? repNode;
}

class _ContRepBase extends _Task {
  _ContRepBase(this.loopTask);
  final _ContRepLoop loopTask;
}

class _ContRepEpsilon extends _Task {
  _ContRepEpsilon(this.loopTask);
  final _ContRepLoop loopTask;
}

class _ContRepLeft extends _Task {
  _ContRepLeft(this.loopTask, this.mid);
  final _ContRepLoop loopTask;
  final int mid;
}

class _ContRepRight extends _Task {
  _ContRepRight(this.loopTask, this.leftNodes);
  final _ContRepLoop loopTask;
  final List<ForestNode> leftNodes;
}

class _ContOptChoose extends _Task {
  const _ContOptChoose(this.start, this.end, this.pattern);
  final int start;
  final int end;
  final PatternSymbol pattern;
}

class _ContConjLeft extends _Task {
  const _ContConjLeft(
    this.currentRule,
    this.pattern,
    this.start,
    this.end,
    this.ruleStart,
    this.minPrecedenceLevel,
  );
  final PatternSymbol currentRule;
  final PatternSymbol pattern;
  final int start;
  final int end;
  final int ruleStart;
  final int? minPrecedenceLevel;
}

class _ContConjRight extends _Task {
  const _ContConjRight(this.startTask, this.leftNodes);
  final _ContConjLeft startTask;
  final List<ForestNode> leftNodes;
}

class SppfBuilder {
  SppfBuilder(this.bsr, this.nodeCache, this.childrenRegistry, this.inputLength);
  final BsrSet bsr;
  final ForestNodeCache nodeCache;
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;
  final int inputLength;

  List<PatternSymbol> getChildrenOf(PatternSymbol symbol) {
    if (childrenRegistry[symbol] case List<PatternSymbol> children) {
      return children;
    }
    throw StateError("Couldn't find the children of $symbol.");
  }

  (String prefix, String suffix)? _splitSymbol(PatternSymbol pattern) {
    // Patterns are encoded as `prefix:id:suffix`; the prefix drives forest
    // reconstruction while the suffix carries the readable payload.
    var split = pattern.symbol.split(":");
    if (split.length < 3) {
      return null;
    }

    return (split[0], split[2]);
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
      "Invariant violation in SppfBuilder.buildNode: expected start <= end, got ($start, $end).",
    );
    var key = "$ruleSymbol:$start:$end";

    // The Two-Stack VM
    var taskStack = <_Task>[
      _DoBuildNode(key, ruleSymbol, start, end, minPrecedenceLevel, isRoot: true),
    ];
    var valueStack = <Object?>[]; // Holds List<ForestNode> and SymbolicNode?

    while (taskStack.isNotEmpty) {
      var task = taskStack.removeLast();

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
        var symNode = nodeCache.symbolic(task.start, task.end, task.ruleSymbol);

        // 2. Schedule the completion logic for AFTER the pattern evaluates
        taskStack.add(_ContBuildNodeFinish(symNode, task.key, task.ruleSymbol));

        // 1. Evaluate the pattern
        var children = getChildrenOf(task.ruleSymbol);
        assert(
          children.length == 1,
          "Invariant violation in buildNode: symbol ${task.ruleSymbol} must "
          "map to exactly one root pattern, got ${children.length}.",
        );
        var patternToEval = children.single;

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
        var childNodes = valueStack.removeLast()! as List<ForestNode>;
        var split = _splitSymbol(task.ruleSymbol);
        var isNeg = switch (split) {
          (String prefix, _) when prefix == "neg" => true,
          _ => false,
        };

        if (isNeg) {
          if (childNodes.isEmpty) {
            inProgress[task.key] = false;
            memo[task.key] = null;
            valueStack.add(null);
          } else {
            inProgress[task.key] = false;
            memo[task.key] = task.symNode;
            valueStack.add(task.symNode);
          }
          continue;
        }

        for (var child in childNodes) {
          task.symNode.addFamily(Family.unary(child));
        }

        inProgress[task.key] = false;
        var result = task.symNode.families.isNotEmpty ? task.symNode : null;
        memo[task.key] = result;
        valueStack.add(result);
      } else if (task is _EvalPattern) {
        _executePatternTask(task, taskStack, valueStack);
      }
      // --- Structural Continuations ---
      else if (task is _ContAltCombine) {
        var rightRes = valueStack.removeLast()! as List<ForestNode>;
        var leftRes = valueStack.removeLast()! as List<ForestNode>;
        var merged = <ForestNode>[];
        merged.addAll(leftRes);
        merged.addAll(rightRes);
        valueStack.add(merged);
      } else if (task is _ContRuleCallFinish) {
        var node = valueStack.removeLast() as SymbolicNode?;
        valueStack.add(node != null ? [node] : <ForestNode>[]);
      } else if (task is _ContActionFinish) {
        var nodes = valueStack.removeLast()! as List<ForestNode>;
        if (nodes.isEmpty) {
          valueStack.add(<ForestNode>[]);
        } else {
          var node = nodeCache.intermediate(task.start, task.end, task.symbolId);
          for (var n in nodes) {
            node.addFamily(Family.unary(n));
          }
          valueStack.add([node]);
        }
      }
      // --- Conj ---
      else if (task is _ContConjLeft) {
        var leftNodes = valueStack.removeLast()! as List<ForestNode>;
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
        var rightNodes = valueStack.removeLast()! as List<ForestNode>;
        if (rightNodes.isEmpty) {
          valueStack.add(<ForestNode>[]);
        } else {
          var node = nodeCache.intermediate(
            task.startTask.start,
            task.startTask.end,
            task.startTask.pattern,
          );
          for (var l in task.leftNodes) {
            for (var r in rightNodes) {
              node.addFamily(Family.binary(l, r));
            }
          }
          valueStack.add([node]);
        }
      }
      // --- Seq Loop ---
      else if (task is _ContSeqLoop) {
        if (!task.it.moveNext()) {
          valueStack.add(task.seqNode != null ? [task.seqNode!] : <ForestNode>[]);
        } else {
          var mid = task.it.current;
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
        var leftNodes = valueStack.removeLast()! as List<ForestNode>;
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
        var rightNodes = valueStack.removeLast()! as List<ForestNode>;
        if (rightNodes.isNotEmpty) {
          task.loopTask.seqNode ??= nodeCache.intermediate(
            task.loopTask.start,
            task.loopTask.end,
            task.loopTask.pattern,
          );
          for (var l in task.leftNodes) {
            for (var r in rightNodes) {
              task.loopTask.seqNode!.addFamily(Family.binary(l, r));
            }
          }
        }
      } else if (task is _ContRepEpsilon) {
        task.loopTask.repNode ??= nodeCache.intermediate(
          task.loopTask.start,
          task.loopTask.end,
          task.loopTask.pattern,
        );
        task.loopTask.repNode!.addFamily(
          Family.unary(nodeCache.epsilon(task.loopTask.start, task.loopTask.pattern)),
        );
      } else if (task is _ContRepBase) {
        var baseNodes = valueStack.removeLast()! as List<ForestNode>;
        if (baseNodes.isNotEmpty) {
          task.loopTask.repNode ??= nodeCache.intermediate(
            task.loopTask.start,
            task.loopTask.end,
            task.loopTask.pattern,
          );
          for (var base in baseNodes) {
            task.loopTask.repNode!.addFamily(Family.unary(base));
          }
        }
      } else if (task is _ContRepLoop) {
        if (!task.it.moveNext()) {
          valueStack.add(task.repNode != null ? [task.repNode!] : <ForestNode>[]);
        } else {
          var mid = task.it.current;
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
        var leftNodes = valueStack.removeLast()! as List<ForestNode>;
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
        var rightNodes = valueStack.removeLast()! as List<ForestNode>;
        if (rightNodes.isNotEmpty) {
          task.loopTask.repNode ??= nodeCache.intermediate(
            task.loopTask.start,
            task.loopTask.end,
            task.loopTask.pattern,
          );
          for (var l in task.leftNodes) {
            for (var r in rightNodes) {
              task.loopTask.repNode!.addFamily(Family.binary(l, r));
            }
          }
        }
      } else if (task is _ContOptChoose) {
        var childNodes = valueStack.removeLast()! as List<ForestNode>;
        if (childNodes.isNotEmpty) {
          valueStack.add(childNodes);
        } else if (task.start == task.end) {
          valueStack.add([nodeCache.epsilon(task.start, task.pattern)]);
        } else {
          valueStack.add(<ForestNode>[]);
        }
      }
    }

    return valueStack.removeLast() as SymbolicNode?;
  }

  void _executePatternTask(_EvalPattern task, List<_Task> taskStack, List<Object?> valueStack) {
    var start = task.start;
    var end = task.end;

    var split = _splitSymbol(task.pattern);
    if (split == null) {
      throw StateError("Couldn't parse symbol encoding for ${task.pattern}.");
    }
    var (prefix, suffix) = split;

    switch (prefix) {
      case "eps":
        valueStack.add(start == end ? [nodeCache.epsilon(start, task.pattern)] : <ForestNode>[]);
      case "bos":
        valueStack.add(
          start == end && start == 0 ? [nodeCache.epsilon(start, task.pattern)] : <ForestNode>[],
        );
      case "eof":
        valueStack.add(
          start == end && end == inputLength
              ? [nodeCache.epsilon(start, task.pattern)]
              : <ForestNode>[],
        );
      case "tok":
        {
          var token = bsr.tokenFor(task.pattern, start, end);
          if (token != null) {
            valueStack.add([nodeCache.terminal(start, end, task.pattern, token)]);
          } else {
            valueStack.add(const <ForestNode>[]);
          }
        }
      case "mar":
        {
          valueStack.add(
            (start == end) //
                ? [nodeCache.marker(start, task.pattern, suffix)]
                : const <ForestNode>[],
          );
        }
      case "las":
      case "lae":
        {
          valueStack.add(
            (start == end) //
                ? [nodeCache.marker(start, task.pattern, suffix)]
                : const <ForestNode>[],
          );
        }
      case "and":
      case "not":
        {
          valueStack.add(
            (start == end) //
                ? [nodeCache.epsilon(start, task.pattern)]
                : <ForestNode>[],
          );
        }
      case "neg":
        {
          // Negation is a leaf-style node in the forest. The parser has already
          // validated the span, so the forest only needs a placeholder child to
          // signal success to the build-node continuation.
          valueStack.add([nodeCache.epsilon(start, task.pattern)]);
        }
      case "alt":
        {
          taskStack.add(const _ContAltCombine());

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
          var pivots = bsr.pivotsFor(task.currentRule, start, end);
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
          var child = getChildrenOf(task.pattern).single;
          var split = _splitSymbol(child);
          Iterable<int> mids;
          if (split != null && split.$1 == "tok") {
            mids = bsr.terminalEndsFor(child, start);
          } else {
            // For general sub-patterns, we check if the child matched a span
            // starting at 'start'.
            mids = bsr.endsFor(child, start);
          }

          var loop = _ContRepLoop(
            task.currentRule,
            task.pattern,
            start,
            end,
            task.ruleStart,
            task.minPrecedenceLevel,
            mids.where((m) => m <= end).iterator,
          );
          taskStack.add(loop);
          if (start == end) {
            taskStack.add(_ContRepEpsilon(loop));
          }
        }
      case "plu":
        {
          var child = getChildrenOf(task.pattern).single;
          var split = _splitSymbol(child);
          Iterable<int> mids;
          if (split != null && split.$1 == "tok") {
            mids = bsr.terminalEndsFor(child, start);
          } else {
            mids = bsr.endsFor(child, start);
          }

          var loop = _ContRepLoop(
            task.currentRule,
            task.pattern,
            start,
            end,
            task.ruleStart,
            task.minPrecedenceLevel,
            mids.where((m) => m <= end).iterator,
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
      case "par":
      case "pac":
        {
          // Parameter references and parameter calls are dispatch wrappers.
          // The concrete rule-call structure is recorded separately in the BSR,
          // so forest reconstruction can treat these as zero-width aliases.
          valueStack.add([nodeCache.epsilon(start, task.pattern)]);
        }
      case "rca":
        {
          var effectivePrec = int.tryParse(suffix) ?? task.minPrecedenceLevel;
          var toCall = getChildrenOf(task.pattern).single;
          var key = '$toCall:$start:$end:${effectivePrec ?? 'null'}';

          taskStack.add(const _ContRuleCallFinish());
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
          var precedenceLevel = int.tryParse(suffix) ?? 0;
          if (task.minPrecedenceLevel != null && precedenceLevel < task.minPrecedenceLevel!) {
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
      default:
        throw StateError('Unsupported pattern prefix "$prefix" for ${task.pattern}.');
    }
  }
}
