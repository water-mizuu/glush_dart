/// State machine-based parser implementation.
///
/// This module implements the core parsing engine for the Glush parser generator.
/// It converts an abstract grammar into a state machine and uses an LR-like algorithm
/// with support for:
/// - Recursive descent rule calls with Graph-Shared Stack (GSS) memoization
/// - Lookahead predicates for positive (&pattern) and negative (!pattern) assertions
/// - Operator precedence filtering for shift/reduce disambiguation
/// - Binarised Shared Representation (BSR) for forest extraction
/// - Semantic actions and manual annotations (marks)
/// - Ambiguous parse forests with enumeration of all derivations
/// - Streaming parse support for large inputs
///
/// Key Classes:
/// - [SMParser]: Main parser interface with multiple parse methods
/// - [Context]: Parsing state carrying marks, caller info, and constraints
/// - [Frame]: A set of states to explore from a context
/// - [Step]: Processing state at a single input position
/// - [Caller]: Graph-Shared Stack node for rule call memoization
/// - [PredicateTracker]: Coordinator for lookahead predicate sub-parses
///
/// Parse Methods (in increasing complexity):
/// 1. [recognize]: Boolean check (fastest)
/// 2. [parse]: Marks-based parse with results
/// 3. [parseAmbiguous]: All ambiguous interpretations merged
/// 4. [parseWithForest]: Full SPPF forest for enumeration/evaluation
/// 5. [parseWithForestAsync]: Streaming version for large inputs
/// 6. [parseToBsr]: Intermediate BSR representation (for testing/analysis)
///
/// The parser uses a work-queue algorithm where frames at different input positions
/// can coexist, enabling proper handling of lookahead and backtracking.
library glush.sm_parser;

import 'dart:async';
import 'dart:collection';

import 'package:glush/src/core/grammar.dart';

import '../core/patterns.dart';
import 'state_machine.dart';
import '../core/mark.dart';
import '../core/list.dart';
import '../representation/sppf.dart';
import '../representation/bsr.dart';
import 'common.dart';
import 'interface.dart';

const isDebug = true;
void printDebug(String message) {
  if (isDebug) {
    print(message);
  }
}

// ---------------------------------------------------------------------------

/// Represents a single parse tree derivation.
///
/// An immutable tree structure representing one complete parse of the input.
/// Each node contains a symbol, span [start:end], and child derivations.
/// Used by enumeration methods ([enumerateAllParses]) and for evaluating
/// semantic values. Supports conversion to strings and precedence analysis.
class ParseDerivation {
  /// The grammar symbol or pattern that this node represents.
  final PatternSymbol symbol;

  /// Start position in the input where this derivation begins.
  final int start;

  /// End position in the input where this derivation ends.
  final int end;

  /// Child derivations for the child symbols of this pattern.
  final List<ParseDerivation> children;

  /// Creates a parse derivation for a symbol spanning [start] to [end].
  /// Creates a parse derivation for a symbol spanning [start] to [end].
  const ParseDerivation(this.symbol, this.start, this.end, this.children);

  /// Returns the substring of the input that this derivation matched.
  /// Safe for out-of-bounds positions.
  String getMatchedText(String input) {
    if (input.isEmpty || start >= input.length) {
      return '';
    }
    final actualEnd = end > input.length ? input.length : end;
    return input.substring(start, actualEnd);
  }

  /// Converts the derivation tree to a formatted string with indentation.
  /// Useful for debugging and visualizing parse trees.
  String toTreeString(String input, [int indent = 0]) {
    final prefix = '  ' * indent;
    final str = '$prefix$this${children.isEmpty ? '  ${input.substring(start, end)}' : ''}\n';
    return str + children.map((c) => c.toTreeString(input, indent + 1)).join('');
  }

  /// Converts the derivation to a parenthesized string representation.
  /// Useful for displaying operator precedence structure.
  String toPrecedenceString(String input) {
    if (children.isEmpty) {
      return input.substring(start, end);
    }

    List<String> mapped = children
        .where((c) => c.start != c.end)
        .map((c) => c.toPrecedenceString(input))
        .toList();

    if (mapped.length == 1) {
      return mapped.single;
    }

    return "(${mapped.join("")})";
  }

  /// Returns a simplified parse tree by collapsing single-child chains.
  /// Useful for removing internal structural nodes from the derivation.
  Object? getSimplified(String input) {
    if (children.isEmpty) {
      return input.substring(start, end);
    }

    if (children.length == 1) {
      return children.single.getSimplified(input);
    }

    return children.map((c) => c.getSimplified(input)).toList();
  }

  /// Returns a compact string representation showing symbol and span.
  @override
  String toString() => '$symbol[$start:$end]';
}

/// Represents a parse tree with its evaluated semantic value.
///
/// Combines a [ParseDerivation] tree with a computed semantic value (T).
/// Provides convenient access to both the tree structure and its evaluated result,
/// useful when iterating over all parse interpretations with [enumerateAllParsesWithResults].
class ParseDerivationWithValue<T> {
  /// The underlying parse tree structure.
  final ParseDerivation tree;

  /// The computed semantic value from evaluating the parse tree.
  final T value;

  /// Optional reference to the grammar for symbol resolution.
  final GrammarInterface? grammar;

  /// Creates a parse derivation with its evaluated semantic value.
  /// Creates a parse derivation with its evaluated semantic value.
  ParseDerivationWithValue(this.tree, this.value, {this.grammar});

  /// Returns the substring of input that this derivation matched.
  String getMatchedText(String input) => tree.getMatchedText(input);

  /// Returns the grammar symbol that this derivation represents.
  PatternSymbol get symbol => tree.symbol;

  /// Returns the resolved pattern object from the grammar registry.
  /// Returns null if grammar is unavailable or pattern not found.
  Pattern? get pattern {
    if (grammar case var grammar?) {
      return grammar.symbolRegistry[tree.symbol];
    }
    return null;
  }

  /// Returns the start position in the input where this derivation begins.
  int get start => tree.start;

  /// Returns the end position in the input where this derivation ends.
  int get end => tree.end;

  /// Returns the child derivations of this tree node.
  List<ParseDerivation> get children => tree.children;

  /// Returns a string showing the symbol, span, and semantic value.
  @override
  String toString() => '$symbol[$start:$end]=$value';
}

/// Main parser implementation using a state machine-based LR-like algorithm.
///
/// Converts an abstract grammar into a state machine (StateMachine) and drives
/// parsing using lookahead, operator precedence filtering, and memoization.
/// Supports multiple parse modes: basic recognition, mark-based results, ambiguous
/// forest extraction, full forest construction, and streaming input.
///
/// Key capabilities:
/// - Fast [recognize] for boolean checks
/// - Marks-based [parse] for semantic annotations
/// - [parseAmbiguous] for ambiguity detection
/// - [parseWithForest] for full parse forests and derivation enumeration
/// - [parseWithForestAsync] for streaming inputs
/// - Lookahead predicates (&pattern, !pattern) for grammar constraints
/// - Operator precedence filtering for shift/reduce disambiguation
/// - Graph-Shared Stack (GSS) memoization for efficient rule processing
/// - Binarised Shared Representation (BSR) for forest construction
///
/// Critical for parsing complex grammars efficiently with support for
/// ambiguity, semantic actions, and advanced parsing features.
class SMParser implements GlushParser, Recognizer, MarksParser, ForestParser {
  static const Context _initialContext = Context(
    RootCallerKey(),
    GlushList.empty(),
    predicateStack: GlushList.empty(),
  );

  /// The state machine constructed from the grammar.
  /// Encodes grammar rules as states and transitions.
  final StateMachine stateMachine;

  /// Initial frames for starting fresh parses.
  /// Lazily initialized on first use.
  late final List<Frame> _initialFrames;

  @override
  final GlushListManager<Mark> markManager = GlushListManager<Mark>();

  @override
  final Map<int, TokenNode> historyByPosition = {};

  /// Tail of the token history linked list.
  /// Points to the most recently processed token.
  TokenNode? _historyTail;

  @override
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};

  /// Whether to capture tokens as StringMark semantic annotations.
  bool captureTokensAsMarks;

  /// Returns the grammar used to construct this parser's state machine.
  GrammarInterface get grammar => stateMachine.grammar;

  /// Create a parser from a grammar.
  ///
  /// Builds the state machine on first use and initializes the parser state.
  /// The parser can then be reused across multiple parse() calls on different inputs.
  SMParser(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar) {
    final initialFrame = Frame(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  /// Create parser from a pre-built state machine (used for imported machines).
  ///
  /// Skips state machine construction (which has already been done elsewhere)
  /// and creates a parser ready to parse input using the provided machine.
  SMParser.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false}) {
    final initialFrame = Frame(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  /// Recognize input without building a parse tree (boolean result).
  ///
  /// Fast path that only checks if the input matches, without marking or
  /// other semantic computation. Returns true iff the entire input is accepted.
  bool recognize(String input) {
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames, predecessors: {});
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return false;
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames, predecessors: {});
    return lastStep.accept;
  }

  /// Parse input and return a [ParseSuccess] or [ParseError].
  ///
  /// This is the basic parsing method: runs the state machine on the input
  /// and returns true only if the entire input is accepted.
  ///
  /// Returns:
  /// - [ParseSuccess] if the entire input matches the grammar
  /// - [ParseError] if parsing fails at some position
  ParseOutcome parse(String input) {
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames, predecessors: {});
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames, predecessors: {});

    if (lastStep.accept) {
      return ParseSuccess(ParserResult(lastStep.marks));
    } else {
      return ParseError(position);
    }
  }

  /// Parse input and return all ambiguous derivation paths.
  ///
  /// Like [parse], but records marks for all possible interpretations.
  /// In ambiguity mode, when multiple [state, caller, minPrec] tuples reach
  /// the same point, their mark lists are merged instead of deduplicated.
  ///
  /// Returns:
  /// - [ParseAmbiguousForestSuccess] if input matches (all interpretations merged)
  /// - [ParseError] if parsing fails
  @override
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks = false}) {
    final Map<ParseNodeKey, Set<PredecessorInfo>> predecessors = {};

    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks,
        predecessors: predecessors,
        bsr: null,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(
      null,
      position,
      frames,
      isSupportingAmbiguity: true,
      captureTokensAsMarks: captureTokensAsMarks,
      predecessors: predecessors,
      bsr: null,
    );

    if (lastStep.accept) {
      final Map<ParseNodeKey, GlushList<Mark>> memo = {};
      final results = <GlushList<Mark>>[];

      for (final (state, context) in lastStep.acceptedContexts) {
        final rootNode = (state.id, position, context.caller);
        results.add(_extractForestFromGraph(rootNode, memo, predecessors));
      }

      return ParseAmbiguousForestSuccess(markManager.branched(results));
    } else {
      return ParseError(position);
    }
  }

  /// Extracts the parse forest from the predecessor graph.
  GlushList<Mark> _extractForestFromGraph(
    ParseNodeKey node,
    Map<ParseNodeKey, GlushList<Mark>> memo,
    Map<ParseNodeKey, Set<PredecessorInfo>> predecessors, [
    Set<ParseNodeKey>? visiting,
  ]) {
    if (memo.containsKey(node)) return memo[node]!;

    final currentVisiting = visiting ?? <ParseNodeKey>{};
    if (currentVisiting.contains(node)) {
      // Return empty list for cyclic path to avoid infinite recursion.
      // In a real SPPF, this would be a cyclic node, but GlushList is linear.
      return const GlushList<Mark>.empty();
    }

    currentVisiting.add(node);
    final predecessorsForNode = predecessors[node];
    if (predecessorsForNode == null) return memo[node] = const GlushList<Mark>.empty();

    final alternatives = <GlushList<Mark>>[];
    for (final (source, action, marks, callSite) in predecessorsForNode) {
      if (action is ReturnAction) {
        final ruleForest = _extractForestFromGraph(source!, memo, predecessors, currentVisiting);
        final parentForest = callSite != null
            ? _extractForestFromGraph(callSite, memo, predecessors, currentVisiting)
            : const GlushList<Mark>.empty();

        alternatives.add(parentForest.addList(markManager, ruleForest));
      } else if (source != null) {
        final base = _extractForestFromGraph(source, memo, predecessors, currentVisiting);
        alternatives.add(base.addList(markManager, marks));
      } else {
        alternatives.add(marks);
      }
    }
    currentVisiting.remove(node);

    return memo[node] = markManager.branched(alternatives);
  }

  /// Parse with forest extraction enabled.
  ///
  /// Internally uses BSR (Binarised Shared Representation) recorded during
  /// parsing to restrict the SPPF construction to spans proven reachable by
  /// the parser, rather than exhaustively searching the whole grammar.
  ///
  /// The returned [ParseForest] can be queried to enumerate all derivations
  /// and compute semantic values for each. This is the most general form of
  /// parsing, supporting full ambiguity handling.
  ///
  /// Returns:
  /// - [ParseForestSuccess] if the entire input matches the grammar
  /// - [ParseError] if parsing fails
  ParseOutcome parseWithForest(String input) {
    final bsrOutcome = parseToBsr(input);
    if (bsrOutcome is BsrParseError) {
      return ParseError(bsrOutcome.position);
    }

    final bsrSuccess = bsrOutcome as BsrParseSuccess;
    final startSymbol = stateMachine.grammar.startSymbol;
    final nodeManager = ForestNodeManager();
    final root = bsrSuccess.bsrSet.buildSppf(grammar, startSymbol, input, nodeManager);
    final effectiveRoot = root ?? nodeManager.symbolic(0, input.length, startSymbol);
    final forest = ParseForest(nodeManager, effectiveRoot);
    return ParseForestSuccess(forest);
  }

  /// Parse a stream of input chunks with forest extraction.
  ///
  /// Processes input incrementally as chunks arrive without buffering the entire
  /// stream in memory. Uses a bounded sliding-window buffer for predicate lookahead
  /// (default 1MB). Suitable for streaming large files.
  ///
  /// WARNING: If the grammar has predicates that require lookahead beyond the
  /// buffer window, results may be incorrect. Adjust [lookaheadWindowSize] if needed.
  ///
  /// Implementation details:
  /// - Maintains all input for a second pass (required for correct SPPF construction)
  /// - Records BSR (Binarised Shared Representation) during parsing
  /// - Defers finalization to avoid blocking stream listeners
  /// - Total memory usage: 2 * input size + lookaheadWindowSize
  ///
  /// Returns a Future that completes with:
  /// - [ParseForestSuccess] if the entire stream matches the grammar
  /// - [ParseError] if parsing fails
  /// - Error if stream processing fails
  Future<ParseOutcome> parseWithForestAsync(
    Stream<String> input, {
    int lookaheadWindowSize = 1048576,
  }) {
    final Map<ParseNodeKey, Set<PredecessorInfo>> predecessors = {};
    final completer = Completer<ParseOutcome>();
    var frames = _initialFrames;
    int globalPosition = 0;

    // Bounded buffer for lookahead: prevents unbounded memory growth
    final lookaheadWindow = <int>[];

    // Keep all input for a second pass to get marks (required for correct SPPF construction)
    final allInput = <int>[];

    // BSR recording happens as we parse
    final bsr = BsrSet();

    input.listen(
      (chunk) {
        try {
          // Feed chunk data into the parser token-by-token
          for (final codeUnit in chunk.codeUnits) {
            // Store for second pass
            allInput.add(codeUnit);

            // Maintain bounded window: keep only recent data for lookahead
            lookaheadWindow.add(codeUnit);
            if (lookaheadWindow.length > lookaheadWindowSize) {
              lookaheadWindow.removeAt(0);
            }

            // Process this token with BSR recording
            final stepResult = _processToken(
              codeUnit,
              globalPosition,
              frames,
              bsr: bsr,
              predecessors: predecessors,
            );
            frames = stepResult.nextFrames;

            // If parsing fails, complete with error
            if (frames.isEmpty) {
              completer.complete(ParseError(globalPosition));
              return;
            }

            globalPosition++;
          }
        } catch (e) {
          completer.completeError(e);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () {
        // Defer finalization to avoid blocking
        Future.microtask(() {
          try {
            if (completer.isCompleted) return;

            // Process end-of-stream token
            final lastStep = _processToken(
              null,
              globalPosition,
              frames,
              bsr: bsr,
              predecessors: predecessors,
            );

            if (lastStep.accept) {
              // Build SPPF from the recorded BSR
              final startSymbol = stateMachine.grammar.startSymbol;
              final nodeManager = ForestNodeManager();
              final fullInput = String.fromCharCodes(allInput);
              final root = bsr.buildSppf(grammar, startSymbol, fullInput, nodeManager);
              if (root == null) {
                print(
                  'DEBUG: buildSppf returned null for symbol=$startSymbol, span=0:$globalPosition',
                );
                print('DEBUG: BSR total entries: ${bsr.entries.length}');
                // Print some sample entries
                final samples = bsr.entries.take(10).toList();
                print('DEBUG: BSR Sample entries: $samples');
              }
              final effectiveRoot = root ?? nodeManager.symbolic(0, globalPosition, startSymbol);

              final forest = ParseForest(nodeManager, effectiveRoot);
              completer.complete(ParseForestSuccess(forest));
            } else {
              completer.complete(ParseError(globalPosition));
            }
          } catch (e) {
            if (!completer.isCompleted) {
              completer.completeError(e);
            }
          }
        });
      },
    );

    return completer.future;
  }

  /// Parse and return the BSR set of all proven rule-completion spans.
  ///
  /// Returns [BsrParseSuccess] with the [BsrSet] on success, or
  /// [BsrParseError] if the input does not conform to the grammar.
  /// Parse and return the BSR set of all proven rule-completion spans.
  ///
  /// BSR (Binarised Shared Representation) records which rule applications
  /// succeeded during parsing. Each entry is (symbol, callStart, midPoint, end),
  /// representing a rule match from [callStart] to [end].
  ///
  /// Used as the foundation for forest extraction ([parseWithForest]) and
  /// for counting/enumerating all derivations ([enumerateAllParses]).
  ///
  /// Returns:
  /// - [BsrParseSuccess] with the recorded BSR set if input matches
  /// - [BsrParseError] if parsing fails
  BsrParseOutcome parseToBsr(String input) {
    final bsr = BsrSet();
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames, bsr: bsr, predecessors: {});
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return BsrParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames, bsr: bsr, predecessors: {});

    if (lastStep.accept) {
      return BsrParseSuccess(bsr, lastStep.marks);
    } else {
      return BsrParseError(position);
    }
  }

  /// Count all possible parse trees without building them
  /// Internally count all derivations for a given input.
  ///
  /// Counts all possible parse trees without building them. Based on [parseToBsr]
  /// and grammar-level recursion with memoization. Useful for understanding
  /// parser ambiguity without memory overhead.
  int countAllParses(String input) {
    final startSymbol = stateMachine.grammar.startSymbol;
    return _countDerivations(startSymbol, input, 0, input.length, {}, {});
  }

  /// Enumerate all possible parse trees lazily, yielding each as a [ParseDerivation].
  /// Enumerate all possible parse trees as [ParseDerivation] objects.
  ///
  /// Returns a lazy iterable of all parse derivations for the input.
  /// Each derivation is a tree of (symbol, start, end, children) tuples.
  ///
  /// Based on BSR (Binarised Shared Representation) from [parseToBsr],
  /// so only explores spans proven reachable by the parser (not all grammar possibilities).
  Iterable<ParseDerivation> enumerateAllParses(String input) sync* {
    final bsrOutcome = parseToBsr(input);
    if (bsrOutcome is! BsrParseSuccess) return;

    final bsrSet = bsrOutcome.bsrSet;
    final startSymbol = stateMachine.grammar.startSymbol;
    final memo = <String, List<ParseDerivation>?>{};

    yield* _enumerateDerivations(bsrSet, startSymbol, 0, input.length, input, memo);
  }

  /// Enumerate all possible parse trees with evaluated semantic values.
  /// Actions are executed bottom-up with child results.
  /// Enumerate all possible parse trees with evaluated semantic values.
  ///
  /// For each parse derivation from [enumerateAllParses], evaluates the
  /// semantic actions to produce a value. Returns an iterable of
  /// [ParseDerivationWithValue] objects containing both the derivation
  /// and its evaluated result.
  Iterable<ParseDerivationWithValue<dynamic>> enumerateAllParsesWithResults(String input) sync* {
    for (final derivation in enumerateAllParses(input)) {
      final value = evaluateParseDerivation(derivation, input);
      yield ParseDerivationWithValue(derivation, value, grammar: grammar);
    }
  }

  /// Convert a [ParseTree] (forest representation) to a [ParseDerivation] (enumeration representation).
  ///
  /// Transforms the shared forest structure back to the recursive tree format
  /// used by enumeration and evaluation methods.
  static ParseDerivation parseTreeToDerivation(ParseTree tree, String input) {
    final childDerivations = tree
        .children //
        .map((c) => parseTreeToDerivation(c, input))
        .toList();

    return ParseDerivation(tree.node.symbol, tree.node.start, tree.node.end, childDerivations);
  }

  /// Count the total number of parse trees for a rule without building them.
  ///
  /// This traverses the grammar recursively with memoization to count all possible
  /// derivations for a symbol spanning [start:end] in the input.
  ///
  /// The inProgress map detects cycles (left-recursive patterns) and breaks them
  /// by returning 0 when a cycle is detected. This prevents infinite loops.
  ///
  /// Used by [countAllParses] to give insight into parse ambiguity without
  /// the memory cost of building all trees.
  int _countDerivations(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    final key = '$symbol:$start:$end';

    if (memo.containsKey(key)) {
      return memo[key]!;
    }

    if (inProgress[key] == true) {
      return 0; // Avoid cycles
    }

    inProgress[key] = true;
    int totalCount = 0;

    final children = grammar.childrenRegistry[symbol] ?? [];

    if (symbol.symbol.startsWith('rul:')) {
      if (children.isNotEmpty) {
        totalCount = _countAlternatives(children.single, input, start, end, memo, inProgress);
      }
    } else {
      totalCount = _countAlternatives(symbol, input, start, end, memo, inProgress);
    }

    inProgress[key] = false;
    memo[key] = totalCount;
    return totalCount;
  }

  /// Count all derivations for a single pattern (matched against input[start:end]).
  ///
  /// Dispatches based on the pattern type:
  /// - eps: epsilon (empty) matches iff start == end
  /// - tok: token matches based on the token constraint (exact, range, etc.)
  /// - mar: marker (semantic annotation) matches iff start == end
  /// - alt: alternative - count both branches and sum
  /// - seq: sequence - sum over all split points (Earley-style)
  /// - plu: one-or-more - count one match, then star matches
  /// - sta: star - delegate to _countStar
  /// - cal/rca/rul/act: wrapper patterns - recurse on child
  /// - and/not: predicates - check child at start, return 1 or 0
  ///
  /// This structure mirrors the grammar representation where each pattern type
  /// has a defined strategy for counting derivations.
  int _countAlternatives(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    final pattern = symbol.symbol;
    final children = grammar.childrenRegistry[symbol] ?? [];
    final split = pattern.split(":");
    if (split.length < 3) return 0;
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          return start == end ? 1 : 0;
        }
      case "tok":
        {
          if (start + 1 != end) return 0;
          final unit = input.codeUnitAt(start);
          bool isMatching = switch (suffix[0]) {
            "." => true,
            ";" => unit == int.parse(suffix.substring(1)),
            "<" => unit <= int.parse(suffix.substring(1)),
            ">" => unit >= int.parse(suffix.substring(1)),
            "[" => () {
              final parts = suffix.substring(1).split(",");
              final min = int.parse(parts[0]);
              final max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
          return isMatching ? 1 : 0;
        }
      case "mar":
        return start == end ? 1 : 0;
      case "alt":
        return _countAlternatives(children.first, input, start, end, memo, inProgress) +
            _countAlternatives(children.last, input, start, end, memo, inProgress);
      case "seq":
        {
          int totalCount = 0;
          for (int mid = start; mid <= end; mid++) {
            final leftCount = _countAlternatives(
              children.first,
              input,
              start,
              mid,
              memo,
              inProgress,
            );
            if (leftCount > 0) {
              final rightCount = _countAlternatives(
                children.last,
                input,
                mid,
                end,
                memo,
                inProgress,
              );
              totalCount += leftCount * rightCount;
            }
          }
          return totalCount;
        }
      case "rca" || "rul" || "act" || "pre":
        return _countDerivations(children.single, input, start, end, memo, inProgress);
      case "and":
      case "not":
        if (start == end) {
          final childCount = _countDerivations(
            children.single,
            input,
            start,
            start,
            memo,
            inProgress,
          );
          if ((childCount > 0) == (prefix == "and")) {
            return 1;
          }
        }
        return 0;
      default:
        return 0;
    }
  }

  /// Enumerate all parse derivations for a rule (or pattern with rules).
  ///
  /// Uses the BSR (Binarised Shared Representation) to constrain search:
  /// only explores spans that the parser proved reachable.
  ///
  /// For rules, delegates to [_enumerateAlternatives] on the rule's body.
  /// For other patterns, directly enumerates.
  ///
  /// Memoization prevents redundant work; in-progress tracking detects cycles
  /// (which should not occur in grammars, but is defensive).
  ///
  /// Respects minPrecedenceLevel constraints for operator precedence filtering.
  Iterable<ParseDerivation> _enumerateDerivations(
    BsrSet bsr,
    PatternSymbol symbol,
    int start,
    int end,
    String input,
    Map<String, List<ParseDerivation>?> memo, {
    int? minPrecedenceLevel,
    Map<String, bool>? inProgress,
  }) sync* {
    final key = '$symbol:$start:$end:${minPrecedenceLevel ?? ""}';
    if (memo.containsKey(key)) {
      final results = memo[key];
      if (results != null) yield* results;
      return;
    }

    inProgress ??= {};
    if (inProgress[key] == true) return;

    inProgress[key] = true;

    // For rules or other patterns, we check their children
    final children = grammar.childrenRegistry[symbol] ?? [];

    if (symbol.symbol.startsWith('rul:')) {
      // It's a rule, evaluate its body (the single child)
      if (children.isNotEmpty) {
        yield* _enumerateAlternatives(
          bsr,
          children.single,
          input,
          start,
          end,
          memo,
          inProgress,
          minPrecedenceLevel: minPrecedenceLevel,
        );
      }
    } else {
      yield* _enumerateAlternatives(
        bsr,
        symbol,
        input,
        start,
        end,
        memo,
        inProgress,
        minPrecedenceLevel: minPrecedenceLevel,
      );
    }

    inProgress[key] = false;
  }

  /// Enumerate all derivations for a single pattern.
  ///
  /// Like [_countAlternatives], dispatches based on pattern type:
  /// - Yields all (symbol, start, end, children) combinations
  /// - For seq, tries all split points and yields cartesian product of children
  /// - For plu/sta, yields hierarchical tree structures
  /// - For predicates (and/not), yields single-node trees
  /// - Respects minPrecedenceLevel for filtering
  ///
  /// The resulting [ParseDerivation] trees can be transformed to intermediate
  /// representations or evaluated to semantic values.
  Iterable<ParseDerivation> _enumerateAlternatives(
    BsrSet bsr,
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress, {
    int? minPrecedenceLevel,
  }) sync* {
    final pattern = symbol.symbol;
    final children = grammar.childrenRegistry[symbol] ?? [];
    final split = pattern.split(":");
    if (split.length < 3) return;
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          if (start == end) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "tok":
        {
          late bool isMatching = switch (suffix[0]) {
            "." => true,
            ";" => input.codeUnitAt(start) == int.parse(suffix.substring(1)),
            "<" => input.codeUnitAt(start) <= int.parse(suffix.substring(1)),
            ">" => input.codeUnitAt(start) >= int.parse(suffix.substring(1)),
            "[" => () {
              final unit = input.codeUnitAt(start);
              final parts = suffix.substring(1).split(",");
              final min = int.parse(parts[0]);
              final max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
          if (start + 1 == end && isMatching) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "mar":
        if (start == end) yield ParseDerivation(symbol, start, end, []);
      case "pre":
        {
          final prec = int.parse(suffix);
          if (minPrecedenceLevel != null && prec < minPrecedenceLevel) return;
          yield* _enumerateAlternatives(
            bsr,
            children.single,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
        }
      case "alt":
        {
          yield* _enumerateAlternatives(
            bsr,
            children.first,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
          yield* _enumerateAlternatives(
            bsr,
            children.last,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
        }
      case "seq":
        {
          for (int mid = start; mid <= end; mid++) {
            final leftList = _enumerateAlternatives(
              bsr,
              children.first,
              input,
              start,
              mid,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (leftList.isEmpty) continue;

            final rightList = _enumerateAlternatives(
              bsr,
              children.last,
              input,
              mid,
              end,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (rightList.isEmpty) continue;

            for (final left in leftList) {
              for (final right in rightList) {
                yield ParseDerivation(symbol, start, end, [left, right]);
              }
            }
          }
        }
      case "rca":
        {
          final prec = suffix.isEmpty ? null : int.parse(suffix);
          yield* _enumerateDerivations(
            bsr,
            children.single,
            start,
            end,
            input,
            memo,
            minPrecedenceLevel: prec,
            inProgress: inProgress,
          );
        }
      case "act":
        for (final child in _enumerateAlternatives(
          bsr,
          children.single,
          input,
          start,
          end,
          memo,
          inProgress,
          minPrecedenceLevel: minPrecedenceLevel,
        )) {
          yield ParseDerivation(symbol, start, end, [child]);
        }
      case "and":
        if (_enumerateDerivations(
          bsr,
          children.single,
          start,
          start,
          input,
          memo,
          inProgress: inProgress,
        ).any((_) => true)) {
          yield ParseDerivation(symbol, start, start, []);
        }
      case "not":
        if (!_enumerateDerivations(
          bsr,
          children.single,
          start,
          start,
          input,
          memo,
          inProgress: inProgress,
        ).any((_) => true)) {
          yield ParseDerivation(symbol, start, start, []);
        }
      case "con":
        // Simplified check for conjunction
        if (start + 1 == end) {
          // This would need more logic to check both children match
          yield ParseDerivation(symbol, start, end, []);
        }
    }
  }

  /// Evaluate a [ParseDerivation] with evaluated semantic values.
  /// Evaluate a [ParseDerivation] with evaluated semantic values.
  ///
  /// Takes a parse tree and computes its semantic value by recursively
  /// evaluating child values and applying semantic actions.
  ///
  /// Returns: The semantic value (String, Mark, List, or other type) from
  /// evaluating the tree's actions, or null if no clear value is defined.
  Object? evaluateParseDerivation(ParseDerivation derivation, String input) {
    return _evaluateParseDerivation(derivation, input);
  }

  /// Directly evaluate a [ParseTree] extracted from the forest.
  /// Directly evaluate a [ParseTree] extracted from the forest.
  ///
  /// Convenience method that converts a forest tree to a derivation, then evaluates it.
  Object? evaluateParseTree(ParseTree tree, String input) {
    return _evaluateParseDerivation(parseTreeToDerivation(tree, input), input);
  }

  /// Evaluate a parse derivation by recursively evaluating its children.
  ///
  /// Handles the internal grammar format (prefix:id:suffix patterns) and
  /// applies semantic actions to yield final values.
  ///
  /// Pattern types:
  /// - eps: returns ""
  /// - tok: returns the matched input substring
  /// - mar: returns a NamedMark
  /// - seq/plu/sta: returns a list of child values
  /// - and/not: returns []
  /// - Others: pass through to child or fallback to pattern registry
  Object? _evaluateParseDerivation(ParseDerivation tree, String input) {
    final symbol = tree.symbol.symbol;
    final split = symbol.split(":");
    if (split.length < 3) {
      // Fallback for symbols that don't follow the prefix:id:suffix format
      return null;
    }
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        return "";
      case "tok":
        return tree.getMatchedText(input);
      case "mar":
        return NamedMark(suffix, tree.start);
      case "alt":
      case "pre":
      case "rca":
      case "rul":
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case "seq":
        final results = <Object?>[];
        for (final child in tree.children) {
          results.add(_evaluateParseDerivation(child, input));
        }
        return results;
      case "and":
      case "not":
        return [];
      default:
        // Try fallback to symbolRegistry if it exists
        final pattern = grammar.symbolRegistry[tree.symbol];
        if (pattern == null) {
          print('MISSING: ${tree.symbol.symbol}');
          return null;
        }

        return switch (pattern) {
          Token() => tree.getMatchedText(input),
          Marker(:var name) => NamedMark(name, tree.start),
          Eps() => "",
          Action action => () {
            final childResults = tree.children
                .map((c) => _evaluateParseDerivation(c, input))
                .toList();
            final span = tree.getMatchedText(input);
            if (childResults case List(length: 1, :List<Object?> single)) {
              return action.callback(span, single);
            }
            return action.callback(span, childResults);
          }(),
          _ => tree.children.isNotEmpty ? _evaluateParseDerivation(tree.children[0], input) : null,
        };
    }
  }

  /// Extract all semantic marks from a parse tree in order.
  ///
  /// Walks the tree to collect all NamedMark and StringMark objects,
  /// then aggregates consecutive StringMarks to form complete string content.
  ///
  /// Returns: A list of mark names and strings representing the semantic
  /// annotations in the order they were parsed.
  List<String> extractParseTreeMarks(ParseTree tree, String input) {
    ParseDerivation derivation = parseTreeToDerivation(tree, input);
    Object? extracted = _extractParseTreeMarks(derivation, input);
    List<Mark> marks = _flattenParseTreeMarks(extracted);

    return _aggregateMarks(marks);
  }

  /// Aggregate marks by concatenating consecutive StringMarks.
  ///
  /// Takes a flat list of Mark objects and produces a simplified list where:
  /// - Consecutive StringMarks are concatenated into a single entry
  /// - NamedMarks are kept separate (they act as delimiters)
  ///
  /// This produces the final mark sequence used for semantic annotations.
  List<String> _aggregateMarks(List<Mark> marks) {
    final List<String> result = [];

    StringMark? builtMark;
    for (int i = 0; i < marks.length; ++i) {
      Object? current = marks[i];

      if (current is StringMark) {
        if (builtMark == null) {
          builtMark = current;
        } else {
          builtMark = StringMark(builtMark.value + current.value, builtMark.position);
        }
      } else if (current is NamedMark) {
        if (builtMark != null) {
          result.add(builtMark.value);
          builtMark = null;
        }
        result.add(current.name);
      }
    }

    // Add any remaining built mark at the end
    if (builtMark != null) {
      result.add(builtMark.value);
    }

    return result;
  }

  /// Flatten a nested mark structure into a flat list.
  ///
  /// Recursively walks a tree of marks (from [_extractParseTreeMarks]) and
  /// flattens it into a single list in parse order. Handles Mark objects
  /// and lists of marks.
  List<Mark> _flattenParseTreeMarks(Object? marks) {
    if (marks is StringMark) return [marks];
    if (marks is NamedMark) return [marks];
    if (marks is List<Object?>) return marks.expand((v) => _flattenParseTreeMarks(v)).toList();
    return [];
  }

  /// Extract semantic marks from a parse derivation (nested lists of marks).
  ///
  /// Like [_evaluateParseDerivation], but returns Mark objects instead of values.
  /// Used by [extractParseTreeMarks] to collect all marks in parse order.
  Object? _extractParseTreeMarks(ParseDerivation tree, String input) {
    final symbol = tree.symbol.symbol;
    final split = symbol.split(":");
    if (split.length < 3) {
      // Fallback for symbols that don't follow the prefix:id:suffix format
      return null;
    }

    final [prefix, _, suffix] = split;
    switch (prefix) {
      case "eps":
        return "";
      case "tok":
        return StringMark(tree.getMatchedText(input), tree.start);
      case "mar":
        return NamedMark(suffix, tree.start);
      case "rca":
      case "rul":
        if (tree.children.isNotEmpty) {
          return _extractParseTreeMarks(tree.children[0], input);
        }
        return null;
      case "alt":
      case "act":
      case "pre":
      case "seq":
        final results = <Object?>[];
        for (final child in tree.children) {
          results.add(_extractParseTreeMarks(child, input));
        }
        return results;
      case "and":
      case "not":
        return [];
      case _:
        throw Error();
    }
  }

  Step _processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    BsrSet? bsr,
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
    required Map<ParseNodeKey, Set<PredecessorInfo>> predecessors,
  }) {
    // Update global token history linked list
    if (token != null) {
      final node = TokenNode(token);
      if (_historyTail == null) {
        _historyTail = node;
      } else {
        _historyTail!.next = node;
        _historyTail = node;
      }
      historyByPosition[currentPosition] = node;
    }

    // historyByPosition updated via currentPosition check in lagging logic if needed
    // or handled by the Step constructor.
    if (_historyTail != null) {
      historyByPosition[currentPosition] = _historyTail!;
    }

    final stepsAtPosition = <int, Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    _enqueueFramesForPosition(workQueue, frames);

    while (workQueue.isNotEmpty) {
      final position = workQueue.firstKey()!;
      if (position > currentPosition) break; // Don't process ahead of current token

      final positionFrames = workQueue.remove(position)!;

      final currentStep = stepsAtPosition.putIfAbsent(position, () {
        final positionToken = (position == currentPosition)
            ? token
            : historyByPosition[position]?.unit;
        return Step(
          this,
          positionToken,
          position,
          bsr: bsr,
          markManager: markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
          predecessors: predecessors,
        );
      });

      for (final frame in positionFrames) {
        if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
          predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]?.activeFrames--;
        }
        currentStep.processFrame(frame);
      }

      // Check for exhausted predicates only when all work at or before this position is done
      if (workQueue.isEmpty || workQueue.firstKey()! > currentPosition) {
        _checkExhaustedPredicates(workQueue, currentPosition);
      }

      if (position < currentPosition) {
        _enqueueFramesForPosition(workQueue, currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }

      _enqueueFramesForPosition(workQueue, currentStep.requeued);
      currentStep.requeued.clear();
    }

    // Return the step for the current position so the parser can extract results
    return stepsAtPosition[currentPosition] ??
        Step(
          this,
          token,
          currentPosition,
          bsr: bsr,
          markManager: markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
          predecessors: predecessors,
        );
  }

  void _enqueueFramesForPosition(SplayTreeMap<int, List<Frame>> workQueue, List<Frame> frames) {
    for (final frame in frames) {
      final position = frame.context.pivot ?? 0;
      final list = workQueue[position];
      if (list == null) {
        workQueue[position] = [frame];
      } else {
        list.add(frame);
      }
    }
  }

  void _checkExhaustedPredicates(SplayTreeMap<int, List<Frame>> workQueue, int currentPosition) {
    bool changed = true;
    while (changed) {
      changed = false;
      final toRemove = <PredicateKey>{};
      for (final entry in predicateTrackers.entries) {
        final tracker = entry.value;

        if (tracker.activeFrames == 0 && !tracker.matched) {
          for (final (parentContext, nextState) in tracker.waiters) {
            final predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              final parentTracker =
                  predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              if (parentTracker != null) {
                parentTracker.activeFrames--;
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              final targetPosition = parentContext.pivot ?? 0;
              workQueue
                  .putIfAbsent(targetPosition, () => [])
                  .add(Frame(parentContext)..nextStates.add(nextState));

              if (parentContext.predicateStack.lastOrNull case var parentPredicateKey?) {
                predicateTrackers[(parentPredicateKey.pattern, parentPredicateKey.startPosition)]
                    ?.activeFrames++;
              }
            }
          }
          toRemove.add(entry.key);
          changed = true;
        } else if (tracker.matched) {
          toRemove.add(entry.key);
        }
      }
      for (final key in toRemove) {
        predicateTrackers.remove(key);
      }
    }
  }
}
