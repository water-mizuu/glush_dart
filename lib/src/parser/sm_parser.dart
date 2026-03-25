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

import 'package:glush/src/core/grammar.dart';

import '../core/patterns.dart';
import 'state_machine.dart';
import '../core/mark.dart';
import '../core/list.dart';
import '../representation/sppf.dart';
import '../representation/bsr.dart';
import '../representation/evaluator.dart';
import 'common.dart';
import 'interface.dart';

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
final class SMParser extends GlushParserBase
    with ParserCore
    implements RecognizerAndMarksParser, ForestParser {
  static const Context _initialContext = Context(
    RootCallerKey(),
    GlushList.empty(),
    predicateStack: GlushList.empty(),
  );

  /// The state machine constructed from the grammar.
  final StateMachine stateMachine;

  @override
  bool captureTokensAsMarks;

  /// Returns the grammar used to construct this parser's state machine.
  GrammarInterface get grammar => stateMachine.grammar;

  /// Create a parser from a grammar.
  ///
  /// Builds the state machine on first use and initializes the parser state.
  /// The parser can then be reused across multiple parse() calls on different inputs.
  SMParser(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar);

  SMParser.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false});

  List<Frame> get _initialFrames {
    final initialFrame = Frame(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    return [initialFrame];
  }

  /// Recognize input without building a parse tree (boolean result).
  ///
  /// Fast path that only checks if the input matches, without marking or
  /// other semantic computation. This method must remain independent of the
  /// BSR/SPPF pipeline and rely only on the State Machine execution and mark
  /// bookkeeping. Returns true iff the entire input is accepted.
  bool recognize(String input) {
    clearState();
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        captureTokensAsMarks: captureTokensAsMarks,
        predecessors: {},
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return false;
      }
      position++;
    }

    final lastStep = processTokenInternal(
      null,
      position,
      frames,
      captureTokensAsMarks: captureTokensAsMarks,
      predecessors: {},
    );
    return lastStep.accept;
  }

  /// Parse input and return a [ParseSuccess] or [ParseError].
  ///
  /// This is the basic parsing method: runs the state machine on the input
  /// and returns true only if the entire input is accepted. This method must
  /// remain independent of the BSR/SPPF pipeline and rely only on the State
  /// Machine's marks system.
  ///
  /// Returns:
  /// - [ParseSuccess] if the entire input matches the grammar
  /// - [ParseError] if parsing fails at some position
  ParseOutcome parse(String input) {
    clearState();
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        captureTokensAsMarks: captureTokensAsMarks,
        predecessors: {},
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = processTokenInternal(
      null,
      position,
      frames,
      captureTokensAsMarks: captureTokensAsMarks,
      predecessors: {},
    );
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
  /// This method must remain independent of the BSR/SPPF pipeline and derive
  /// ambiguity purely from the State Machine's marks and predecessor graph.
  ///
  /// Returns:
  /// - [ParseAmbiguousForestSuccess] if input matches (all interpretations merged)
  /// - [ParseError] if parsing fails
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    clearState();
    final shouldCapture = captureTokensAsMarks ?? this.captureTokensAsMarks;
    final Map<ParseNodeKey, Set<PredecessorInfo>> predecessors = {};

    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: shouldCapture,
        predecessors: predecessors,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = processTokenInternal(
      null,
      position,
      frames,
      isSupportingAmbiguity: true,
      captureTokensAsMarks: shouldCapture,
      predecessors: predecessors,
    );

    if (lastStep.accept) {
      final Map<ParseNodeKey, GlushList<Mark>> memo = {};
      final results = <GlushList<Mark>>[];

      for (final (state, context) in lastStep.acceptedContexts) {
        final rootNode = (state.id, position, context.caller);
        results.add(extractForestFromGraphInternal(rootNode, memo, predecessors));
      }

      return ParseAmbiguousForestSuccess(markManager.branched(results));
    } else {
      return ParseError(position);
    }
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
    final forest = ParseForest(nodeManager, root);
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
    clearState();

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
            final stepResult = processTokenInternal(
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
            final lastStep = processTokenInternal(
              null,
              globalPosition,
              frames,
              bsr: bsr,
              captureTokensAsMarks: captureTokensAsMarks,
              predecessors: predecessors,
            );

            if (lastStep.accept) {
              // Build SPPF from the recorded BSR
              final startSymbol = stateMachine.grammar.startSymbol;
              final nodeManager = ForestNodeManager();
              final fullInput = String.fromCharCodes(allInput);
              final root = bsr.buildSppf(grammar, startSymbol, fullInput, nodeManager);
              final forest = ParseForest(nodeManager, root);
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
    clearState();
    final bsr = BsrSet();
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        bsr: bsr,
        predecessors: {},
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return BsrParseError(position);
      }
      position++;
    }

    final lastStep = processTokenInternal(null, position, frames, bsr: bsr, predecessors: {});

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
      case "las":
      case "lae":
        return start == end ? 1 : 0;
      case "alt":
        return _countAlternatives(children.first, input, start, end, memo, inProgress) +
            _countAlternatives(children.last, input, start, end, memo, inProgress);
      case "lab":
        return _countAlternatives(children.single, input, start, end, memo, inProgress);
      case "opt":
        {
          final childCount = _countAlternatives(
            children.single,
            input,
            start,
            end,
            memo,
            inProgress,
          );
          if (childCount > 0) {
            return childCount;
          }
          return start == end ? 1 : 0;
        }
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
      case "sta":
        return _countRepetition(
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: false,
        );
      case "plu":
        return _countRepetition(
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: true,
        );
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

  int _countRepetition({
    required PatternSymbol symbol,
    required PatternSymbol child,
    required String input,
    required int start,
    required int end,
    required Map<String, int> memo,
    required Map<String, bool> inProgress,
    required bool isPlus,
  }) {
    int totalCount = 0;

    if (!isPlus && start == end) {
      totalCount += 1;
    }

    if (isPlus) {
      totalCount += _countAlternatives(child, input, start, end, memo, inProgress);
    }

    // Force progress in the recursive branch to avoid epsilon loops.
    for (int mid = start + 1; mid <= end; mid++) {
      final leftCount = _countAlternatives(child, input, start, mid, memo, inProgress);
      if (leftCount == 0) continue;
      final rightCount = _countAlternatives(symbol, input, mid, end, memo, inProgress);
      totalCount += leftCount * rightCount;
    }

    return totalCount;
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
      case "las":
      case "lae":
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
      case "lab":
        {
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
        }
      case "opt":
        {
          final childList = _enumerateAlternatives(
            bsr,
            children.single,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          ).toList();
          if (childList.isNotEmpty) {
            for (final child in childList) {
              yield ParseDerivation(symbol, start, end, [child]);
            }
          } else if (start == end) {
            yield ParseDerivation(symbol, start, end, []);
          }
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
      case "sta":
        yield* _enumerateRepetition(
          bsr: bsr,
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: false,
          minPrecedenceLevel: minPrecedenceLevel,
        );
      case "plu":
        yield* _enumerateRepetition(
          bsr: bsr,
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: true,
          minPrecedenceLevel: minPrecedenceLevel,
        );
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

  Iterable<ParseDerivation> _enumerateRepetition({
    required BsrSet bsr,
    required PatternSymbol symbol,
    required PatternSymbol child,
    required String input,
    required int start,
    required int end,
    required Map<String, List<ParseDerivation>?> memo,
    required Map<String, bool> inProgress,
    required bool isPlus,
    required int? minPrecedenceLevel,
  }) sync* {
    if (!isPlus && start == end) {
      yield ParseDerivation(symbol, start, end, []);
    }

    if (isPlus) {
      for (final base in _enumerateAlternatives(
        bsr,
        child,
        input,
        start,
        end,
        memo,
        inProgress,
        minPrecedenceLevel: minPrecedenceLevel,
      )) {
        yield ParseDerivation(symbol, start, end, [base]);
      }
    }

    // Force progress in the recursive branch to avoid epsilon loops.
    for (int mid = start + 1; mid <= end; mid++) {
      final leftList = _enumerateAlternatives(
        bsr,
        child,
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
        symbol,
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
      case "las":
        return LabelStartMark(suffix, tree.start);
      case "lae":
        return LabelEndMark(suffix, tree.start);
      case "alt":
      case "lab":
      case "opt":
      case "pre":
      case "rca":
      case "rul":
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case "seq":
      case "plu":
      case "sta":
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
      case "las":
        return LabelStartMark(suffix, tree.start);
      case "lae":
        return LabelEndMark(suffix, tree.start);
      case "rca":
      case "rul":
      case "lab":
        if (tree.children.isNotEmpty) {
          return _extractParseTreeMarks(tree.children[0], input);
        }
        return null;
      case "alt":
      case "opt":
      case "act":
      case "pre":
      case "seq":
      case "plu":
      case "sta":
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

  /// Extract full raw marks (NamedMark/StringMark/LabelStartMark/LabelEndMark)
  /// from a parse tree in-order.
  List<Mark> extractParseTreeRawMarks(
    ParseTree tree,
    String input, {
    bool captureTokensAsMarks = true,
  }) {
    final derivation = parseTreeToDerivation(tree, input);
    final extracted = _extractParseTreeRawMarks(
      derivation,
      input,
      captureTokensAsMarks: captureTokensAsMarks,
    );

    // Hygiene fallback:
    // Current SPPF extraction can miss zero-width marker/label structure in some
    // grammars. When that happens for a full-input root tree, recover marks from
    // the standard parse pipeline so evaluator APIs remain usable.
    final hasStructuralMarks = extracted.any(
      (m) => m is NamedMark || m is LabelStartMark || m is LabelEndMark,
    );

    if (!hasStructuralMarks && tree.node.start == 0 && tree.node.end == input.length) {
      final outcome = parse(input);
      if (outcome is ParseSuccess) {
        return outcome.result.rawMarks;
      }
    }

    return extracted;
  }

  /// Build a structured labeled tree directly from a parse tree.
  ParseResult structuredFromParseTree(ParseTree tree, String input) {
    return _structuredFromParseTreeNoMarks(tree, input);
  }

  /// Evaluate a parse tree using the same mark/tree evaluator API used by parse().
  T evaluateParseTreeWith<T>(ParseTree tree, String input, Evaluator<T> evaluator) {
    return evaluator.evaluate(structuredFromParseTree(tree, input));
  }

  ParseResult _structuredFromParseTreeNoMarks(ParseTree tree, String input) {
    final stack = <_ForestStructuredFrame>[_ForestStructuredFrame('')];

    void visit(ParseTree current) {
      final parts = _splitSymbol(current.node.symbol.symbol);
      final prefix = parts?.$1;
      final suffix = parts?.$2 ?? '';

      if (prefix == 'las') {
        stack.add(_ForestStructuredFrame(suffix));
        return;
      }

      if (prefix == 'lae') {
        if (stack.length > 1) {
          final frame = stack.removeLast();
          stack.last.addChild(frame.name, frame.toResult());
        }
        return;
      }

      if (prefix == 'tok') {
        stack.last.addToken(_safeSpan(input, current.node.start, current.node.end));
        return;
      }

      if (prefix == 'lab') {
        stack.add(_ForestStructuredFrame(suffix));
        for (final child in current.children) {
          visit(child);
        }
        final frame = stack.removeLast();
        stack.last.addChild(frame.name, frame.toResult());
        return;
      }

      if (prefix == 'mar') {
        if (stack.last.children.isNotEmpty) {
          final lastChild = stack.last.children.removeLast();
          final wrapped = ParseResult([(lastChild.$1, lastChild.$2)], lastChild.$2.span);
          stack.last.children.add((suffix, wrapped));
        } else {
          stack.last.children.add((suffix, ParseResult([], stack.last.spanBuffer.toString())));
        }
        return;
      }

      for (final child in current.children) {
        visit(child);
      }
    }

    visit(tree);

    while (stack.length > 1) {
      final frame = stack.removeLast();
      stack.last.addChild(frame.name, frame.toResult());
    }

    return stack.first.toResult();
  }

  (String prefix, String suffix)? _splitSymbol(String symbol) {
    final split = symbol.split(':');
    if (split.length < 3) return null;
    return (split[0], split[2]);
  }

  String _safeSpan(String input, int start, int end) {
    final s = start.clamp(0, input.length);
    final e = end.clamp(0, input.length);
    if (s >= e) return '';
    return input.substring(s, e);
  }

  List<Mark> _extractParseTreeRawMarks(
    ParseDerivation tree,
    String input, {
    required bool captureTokensAsMarks,
  }) {
    final symbol = tree.symbol.symbol;
    final split = symbol.split(":");
    if (split.length < 3) return const <Mark>[];
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
      case "and":
      case "not":
        return const <Mark>[];
      case "tok":
        final pattern = grammar.symbolRegistry[tree.symbol];
        if (captureTokensAsMarks || pattern is Token && pattern.choice is! ExactToken) {
          return [StringMark(tree.getMatchedText(input), tree.start)];
        }
        return const <Mark>[];
      case "mar":
        return [NamedMark(suffix, tree.start)];
      case "las":
        return [LabelStartMark(suffix, tree.start)];
      case "lae":
        return [LabelEndMark(suffix, tree.start)];
      case "alt":
      case "opt":
      case "act":
      case "pre":
      case "seq":
      case "plu":
      case "sta":
      case "rca":
      case "rul":
      case "lab":
        final out = <Mark>[];
        if (prefix == "lab") {
          out.add(LabelStartMark(suffix, tree.start));
        }
        for (final child in tree.children) {
          out.addAll(
            _extractParseTreeRawMarks(child, input, captureTokensAsMarks: captureTokensAsMarks),
          );
        }
        if (prefix == "lab") {
          out.add(LabelEndMark(suffix, tree.start));
        }
        return out;
      default:
        final pattern = grammar.symbolRegistry[tree.symbol];
        if (pattern == null) return const <Mark>[];
        return switch (pattern) {
          Marker(:var name) => [NamedMark(name, tree.start)],
          LabelStart(:var name) => [LabelStartMark(name, tree.start)],
          LabelEnd(:var name) => [LabelEndMark(name, tree.start)],
          Token() =>
            captureTokensAsMarks
                ? [StringMark(tree.getMatchedText(input), tree.start)]
                : const <Mark>[],
          _ =>
            tree.children
                .expand(
                  (c) => _extractParseTreeRawMarks(
                    c,
                    input,
                    captureTokensAsMarks: captureTokensAsMarks,
                  ),
                )
                .toList(),
        };
    }
  }
}

class _ForestStructuredFrame {
  final String name;
  final List<(String label, ParseNode node)> children = [];
  final StringBuffer spanBuffer = StringBuffer();

  _ForestStructuredFrame(this.name);

  void addChild(String label, ParseNode node) {
    children.add((label, node));
    spanBuffer.write(node.span);
  }

  void addToken(String value) {
    spanBuffer.write(value);
  }

  ParseResult toResult() => ParseResult(children, spanBuffer.toString());
}
