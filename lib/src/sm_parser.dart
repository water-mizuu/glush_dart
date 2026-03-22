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

import 'package:glush/src/grammar.dart';

import 'patterns.dart';
import 'state_machine.dart';
import 'mark.dart';
import 'list.dart';
import 'sppf.dart';
import 'bsr.dart';
export 'bsr.dart';

const isDebug = true;
void printDebug(String message) {
  if (isDebug) {
    print(message);
  }
}

// ---------------------------------------------------------------------------
// Parse result types — sealed hierarchy replaces dynamic return values
// ---------------------------------------------------------------------------

/// Sealed result type returned by [SMParser.parse] and [SMParser.parseWithForest].
/// Allows type-safe handling of success vs. failure outcomes.
///
/// This sealed class serves as the base for all parse operation outcomes,
/// enabling type-safe pattern matching to distinguish between parse success
/// (with various result representations) and parse failures.
sealed class ParseOutcome {}

/// Returned when parsing fails.
/// Contains the input position where parsing could not continue.
///
/// Critical for error reporting and diagnostics. Indicates that the input
/// does not conform to the grammar starting at the given position.
final class ParseError extends ParseOutcome implements Exception {
  /// The input position where parsing failed.
  /// Indicates where the parser could no longer match input to grammar rules.
  final int position;

  /// Constructs a ParseError at the given position.
  ParseError(this.position);

  /// Returns a human-readable error message showing the failure position.
  @override
  String toString() => 'ParseError at position $position';
}

/// Returned when parsing succeeds (marks-based parse).
/// Contains a [ParserResult] with all accumulated marks.
///
/// Used by the basic [parse] and [recognize] methods. Provides semantic
/// annotations (marks) from the parse, useful for simple parsing tasks
/// that don't need full forest enumeration.
final class ParseSuccess extends ParseOutcome {
  /// The result object containing accumulated marks from the successful parse.
  /// Access marks via [ParserResult.marks] for semantic annotations.
  final ParserResult result;

  /// Constructs a ParseSuccess with the given parser result.
  ParseSuccess(this.result);
}

/// Returned when parsing succeeds with an ambiguous forest.
/// Contains all possible parse tree derivations merged into a single list.
///
/// Used by [parseAmbiguous] to support grammar ambiguity detection.
/// Merges marks from all interpretations, allowing users to analyze
/// which derivations are possible for a given input.
final class ParseAmbiguousForestSuccess extends ParseOutcome {
  /// Merged marks from all possible parse interpretations.
  /// Represents the combined result of all ambiguous derivations.
  final GlushList<Mark> forest;

  /// Constructs a ParseAmbiguousForestSuccess with the merged forest.
  ParseAmbiguousForestSuccess(this.forest);
}

/// Returned when parsing succeeds with a full parse forest.
/// The forest enables enumeration of all derivations and evaluation of
/// semantic values. Forest extraction uses BSR (Binarised Shared Representation)
/// to constrain the search space to only reachable spans.
///
/// Most powerful parse result. Enables full control over derivation enumeration,
/// semantic evaluation, and ambiguity handling. Essential for complex applications
/// like compilers or grammar analysis tools.
final class ParseForestSuccess extends ParseOutcome {
  /// The parse forest supporting full derivation enumeration.
  /// Use for traversing all possible parses and their semantic values.
  final ParseForest forest;

  /// Constructs a ParseForestSuccess with the given forest.
  ParseForestSuccess(this.forest);

  /// Returns a string representation of the forest success.
  @override
  String toString() => 'ParseForestSuccess(forest=$forest)';
}

// ---------------------------------------------------------------------------

/// Holds the results of a basic [parse] operation.
///
/// Encapsulates accumulated semantic marks (NamedMark and StringMark)
/// and provides convenient access via the [marks] property which
/// aggregates consecutive string marks.
class ParserResult {
  /// Raw list of marks accumulated during parsing (before aggregation).
  /// Contains both NamedMark and StringMark objects in parse order.
  final List<Mark> _rawMarks;

  /// Creates a ParserResult with the given accumulated marks.
  ParserResult(this._rawMarks);

  /// Returns aggregated marks where consecutive StringMarks are concatenated.
  /// Each NamedMark acts as a delimiter.
  /// Use this for accessing the final semantic annotation sequence.
  List<String> get marks {
    final result = <String>[];
    String? currentStringMark;

    for (final mark in _rawMarks) {
      if (mark is NamedMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is StringMark) {
        currentStringMark = (currentStringMark ?? '') + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }

    return result;
  }

  /// Converts raw marks to nested list representation.
  /// Each mark becomes a list containing its components.
  List<List<Object?>> toList() => _rawMarks.map((m) {
    if (m is NamedMark) return m.toList();
    if (m is StringMark) return m.toList();
    return [];
  }).toList();
}

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

/// Node in a linked list of tokens, providing shared history for lagging frames.
///
/// Essential for supporting lookahead predicates that may backtrack.
/// Maintains a linked history of tokens processed, allowing frames at earlier
/// positions to move forward without losing access to past input.
class TokenNode {
  /// The character code (token) stored at this position.
  final int unit;

  /// Link to the next token in the history list.
  TokenNode? next;

  /// Creates a token node for the given character code.
  TokenNode(this.unit);
}

/// Tracks the status of a lookahead sub-parse (AND/NOT predicate).
///
/// When a predicate is encountered during parsing, a PredicateTracker coordinates
/// the sub-parse across multiple frames at potentially different positions.
/// Supports both positive (&pattern) and negative (!pattern) lookahead assertions.
///
/// Critical fields:
/// - symbol: the pattern to lookahead on
/// - startPos: input position where lookahead begins
/// - isAnd: true for positive lookahead, false for negative
/// - activeFrames: count of frames exploring this predicate (for completion detection)
/// - matched: whether the sub-parse found a match
/// - waiters: parent frames waiting for the predicate result
///
/// The tracker enables asynchronous completion of lookahead checks,
/// then resumes all dependent frames with the correct result.
class PredicateTracker {
  /// The pattern symbol to lookahead on.
  final PatternSymbol symbol;

  /// The input position where lookahead begins.
  final int startPos;

  /// True for positive lookahead (&pattern), false for negative (!pattern).
  final bool isAnd;

  /// Count of active frames currently exploring this predicate.
  /// Used to detect when the sub-parse is complete (reaches 0).
  int activeFrames = 0;

  /// Whether the sub-parse found a match.
  bool matched = false;

  /// Parent frames waiting for the predicate result (context, resuming state).
  final List<(Context, State)> waiters = [];

  /// Creates a predicate tracker for a sub-parse assertion.
  PredicateTracker(this.symbol, this.startPos, {required this.isAnd});
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
class SMParser {
  /// The state machine constructed from the grammar.
  /// Encodes grammar rules as states and transitions.
  final StateMachine stateMachine;

  /// Initial frames for starting fresh parses.
  /// Lazily initialized on first use.
  late final List<Frame> _initialFrames;

  /// Manager for GlushList mark allocation and branching.
  /// Optimizes memory usage for mark accumulation during parsing.
  final GlushListManager<Mark> _markManager = GlushListManager<Mark>();

  /// Manager for predicate stack deduplication.
  final GlushListManager<PredicateCallerKey> _predicateStackManager =
      GlushListManager<PredicateCallerKey>();

  /// Maps input position to token history nodes.
  /// Enables efficient access to past tokens for lookahead.
  final Map<int, TokenNode> _historyByPosition = {};

  /// Tail of the token history linked list.
  /// Points to the most recently processed token.
  TokenNode? _historyTail;

  /// Active predicate sub-parses keyed by (pattern symbol, start position).
  /// Tracks all lookahead assertions in progress.
  final Map<(PatternSymbol, int), PredicateTracker> _predicateTrackers = {};

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
    const initialContext = Context(
      RootCallerKey(),
      GlushList.empty(),
      predicateStack: GlushList.empty(),
    );
    final initialFrame = Frame(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  /// Create parser from a pre-built state machine (used for imported machines).
  ///
  /// Skips state machine construction (which has already been done elsewhere)
  /// and creates a parser ready to parse input using the provided machine.
  SMParser.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false}) {
    const initialContext = Context(
      RootCallerKey(),
      GlushList.empty(),
      predicateStack: GlushList.empty(),
    );
    final initialFrame = Frame(initialContext);
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
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks = false}) {
    final Map<_ParseNode, Set<_Predecessor>> predecessors = {};
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks,
        predecessors: predecessors,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) return ParseError(position);
      position++;
    }

    final lastStep = _processToken(
      null,
      position,
      frames,
      isSupportingAmbiguity: true,
      captureTokensAsMarks: captureTokensAsMarks,
      predecessors: predecessors,
    );

    if (lastStep.accept) {
      final memo = <_ParseNode, GlushList<Mark>>{};
      final results = <GlushList<Mark>>[];

      for (final (state, ctx) in lastStep._acceptedContexts) {
        final rootNode = (state.id, position, ctx.caller);
        results.add(_extractForestFromGraph(rootNode, memo, predecessors));
      }

      return ParseAmbiguousForestSuccess(_markManager.branched(results));
    } else {
      return ParseError(position);
    }
  }

  /// Extracts the parse forest from the predecessor graph.
  GlushList<Mark> _extractForestFromGraph(
    _ParseNode node,
    Map<_ParseNode, GlushList<Mark>> memo,
    Map<_ParseNode, Set<_Predecessor>> predecessors, [
    Set<_ParseNode>? visiting,
  ]) {
    if (memo.containsKey(node)) return memo[node]!;

    final currentVisiting = visiting ?? <_ParseNode>{};
    if (currentVisiting.contains(node)) {
      // Return empty list for cyclic path to avoid infinite recursion.
      // In a real SPPF, this would be a cyclic node, but GlushList is linear.
      return const GlushList<Mark>.empty();
    }

    currentVisiting.add(node);
    final preds = predecessors[node];
    if (preds == null) return memo[node] = const GlushList<Mark>.empty();

    final alts = <GlushList<Mark>>[];
    try {
      for (final (source, action, marks, callSite) in preds) {
        if (action is ReturnAction) {
          final ruleForest = _extractForestFromGraph(source!, memo, predecessors, currentVisiting);
          final parentForest = callSite != null
              ? _extractForestFromGraph(callSite, memo, predecessors, currentVisiting)
              : const GlushList<Mark>.empty();
          alts.add(parentForest.addList(_markManager, ruleForest));
        } else if (source != null) {
          final base = _extractForestFromGraph(source, memo, predecessors, currentVisiting);
          alts.add(base.addList(_markManager, marks));
        } else {
          alts.add(marks);
        }
      }
    } finally {
      currentVisiting.remove(node);
    }

    return memo[node] = _markManager.branched(alts);
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
    final bsrSet = bsrSuccess.bsrSet;
    final startSymbol = stateMachine.grammar.startSymbol;
    final nodeManager = ForestNodeManager();
    final root = bsrSet.buildSppf(grammar, startSymbol, input, nodeManager);
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
    final Map<_ParseNode, Set<_Predecessor>> predecessors = {};
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
      case "act":
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
        if (pattern == null) return null;

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

  /// Process a single token at the given position, advancing all active frames.
  ///
  /// This is the core parsing loop that manages the LR-parse-like state machine.
  /// It:
  /// 1. Maintains token history for lagging frames (frames that haven't caught up yet)
  /// 2. Creates/reuses Step objects for each input position
  /// 3. Processes frames using a work queue ordered by position (earliest first)
  /// 4. Validates that no frame tries to parse past the current token position
  /// 5. Checks for exhausted predicates after processing each position
  /// 6. Returns the step for the current position so results can be extracted
  ///
  /// The work queue allows frames at different positions to coexist, enabling
  /// proper handling of lookahead predicates that may backtrack and lookahead.
  ///
  /// Returns: A [Step] object containing the parse state and results for [position].
  Step _processToken(
    int? token,
    int position,
    List<Frame> frames, {
    BsrSet? bsr,
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
    required Map<_ParseNode, Set<_Predecessor>> predecessors,
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
      _historyByPosition[position] = node;
    }

    // _historyByPosition updated via currentPosition check in lagging logic if needed
    // or handled by the Step constructor.
    if (_historyTail != null) {
      _historyByPosition[position] = _historyTail!;
    }

    final stepsAtPosition = <int, Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    void addFramesToQueue(List<Frame> newFrames) {
      for (final f in newFrames) {
        final pos = f.context.pivot ?? 0;
        workQueue.putIfAbsent(pos, () => []).add(f);

        if (f.context.predicateStack.lastOrNull case var pk?) {
          _predicateTrackers[(pk.pattern, pk.startPos)]?.activeFrames++;
        }
      }
    }

    addFramesToQueue(frames);

    while (workQueue.isNotEmpty) {
      final pos = workQueue.firstKey()!;
      if (pos > position) break; // Don't process ahead of current token

      final posFrames = workQueue.remove(pos)!;

      final currentStep = stepsAtPosition.putIfAbsent(pos, () {
        final posToken = (pos == position) ? token : _historyByPosition[pos]?.unit;
        return Step(
          this,
          posToken,
          pos,
          bsr: bsr,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
          requeue: addFramesToQueue, // Pass the adder directly
          predecessors: predecessors,
        );
      });

      for (final f in posFrames) {
        if (f.context.predicateStack.lastOrNull case var pk?) {
          _predicateTrackers[(pk.pattern, pk.startPos)]?.activeFrames--;
        }
        currentStep._processFrame(f);
      }

      // Check for exhausted predicates only when all work at or before this position is done
      if (workQueue.isEmpty || workQueue.firstKey()! > position) {
        _checkExhaustedPredicates(workQueue, position);
      }

      if (pos < position) {
        for (final f in currentStep.nextFrames) {
          if (f.context.predicateStack.lastOrNull case var pk?) {
            _predicateTrackers[(pk.pattern, pk.startPos)]?.activeFrames--;
          }
        }
        addFramesToQueue(currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }
    }

    // Return the step for the current position so the parser can extract results
    return stepsAtPosition[position] ??
        Step(
          this,
          token,
          position,
          bsr: bsr,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
          requeue: addFramesToQueue, // Add required callback
          predecessors: predecessors,
        );
  }

  /// Check if a pattern matches at a given position in the input without consuming.
  /// Used for AND/NOT lookahead predicates.
  ///
  /// This is a fast check that determines if a pattern would match at startPos
  /// without actually advancing the parser state. Lookahead sub-parses are
  /// triggered via PredicateAction in _process and complete via _finishPredicate.
  void _checkExhaustedPredicates(SplayTreeMap<int, List<Frame>> workQueue, int currentPosition) {
    bool changed = true;
    while (changed) {
      changed = false;
      final toRemove = <(PatternSymbol, int)>{};
      for (final entry in _predicateTrackers.entries) {
        final tracker = entry.value;

        if (tracker.activeFrames == 0 && !tracker.matched) {
          for (final (parentCtx, nextState) in tracker.waiters) {
            final pk = parentCtx.predicateStack.lastOrNull;
            if (pk != null) {
              final parentTracker = _predicateTrackers[(pk.pattern, pk.startPos)];
              if (parentTracker != null) {
                parentTracker.activeFrames--;
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              final targetPos = parentCtx.pivot ?? 0;
              workQueue
                  .putIfAbsent(targetPos, () => [])
                  .add(Frame(parentCtx)..nextStates.add(nextState));

              if (parentCtx.predicateStack.lastOrNull case var ppk?) {
                _predicateTrackers[(ppk.pattern, ppk.startPos)]?.activeFrames++;
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
        _predicateTrackers.remove(key);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Internal parsing machinery
// ---------------------------------------------------------------------------

/// Strongly typed key to identify a call site in the parsing state machine.
///
/// Sealed base type for different caller contexts: root parse, predicate sub-parse,
/// or rule invocation. Enables type-safe discrimination of caller types without
/// runtime type checks. Essential for proper memoization and context tracking.
sealed class CallerKey {
  const CallerKey();
}

/// Represents the root call context (top-level parse, not a rule call).
///
/// Singleton key used when parsing starts at the grammar's start symbol.
/// Indicates frames that are not within a rule call or predicate sub-parse.
final class RootCallerKey extends CallerKey {
  const RootCallerKey();

  @override
  int get hashCode => 0;

  @override
  bool operator ==(Object other) => other is RootCallerKey;
}

/// Caller key for a lookahead predicate sub-parse.
///
/// Identifies frames operating within a predicate (&pattern or !pattern).
/// Links predicate results back to their original call sites.
final class PredicateCallerKey extends CallerKey {
  /// The pattern symbol being tested by the lookahead assertion.
  final PatternSymbol pattern;

  /// The input position where the lookahead assertion starts.
  final int startPos;

  /// Creates a caller key for a predicate sub-parse.
  const PredicateCallerKey(this.pattern, this.startPos);

  /// Checks equality based on pattern and position.
  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKey && pattern == other.pattern && startPos == other.startPos;

  /// Hashes based on pattern and position.
  @override
  int get hashCode => Object.hash(pattern, startPos);
}

/// Graph-Shared Stack (GSS) node for memoizing rule call results.
///
/// The GSS is a critical memoization structure that avoids re-parsing the same
/// rule from the same position multiple times. When a rule is invoked from the
/// same position with the same precedence level, only one Caller is created.
///
/// Multiple frames waiting for the rule result register as "waiters". When the
/// rule completes successfully, all waiters are resumed with the return context,
/// ensuring derivations are shared rather than recomputed.
///
/// Key invariants:
/// - (rule, startPos, minPrecedenceLevel) uniquely identifies a Caller
/// - All waiters are resumed with the same returns
/// - Cycles (left recursion) are handled via memoization checks
/// - Precedence filtering prevents invalid returns
///
/// Critical for parsing efficiency: without GSS memoization, left-recursive
/// grammars would cause exponential reprocessing.
///
/// Fields:
/// - rule: the Rule being invoked
/// - pattern: Pattern object (debugging)
/// - startPos: input position of call
/// - minPrecedenceLevel: precedence constraint
/// - waiters: parent frames waiting for rule result
/// - returns: successful rule completion contexts
final class Caller extends CallerKey {
  /// The rule being invoked.
  final Rule rule;

  /// Pattern object associated with this rule call (for debugging).
  final Pattern pattern;

  /// The input position where this rule was called.
  final int startPos;

  /// Precedence constraint for filtering invalid return values.
  /// Only returns with equal or higher precedence are accepted.
  final int? minPrecedenceLevel;

  /// Waiting frames: (parent caller, return state, min precedence, parent context, call site node).
  /// Each waiter will be resumed with the rule's completion context.
  final List<(CallerKey?, State, int?, Context, _ParseNode)> waiters = [];

  /// Successful rule completions: contexts representing valid return states.
  /// When the rule completes, all waiters are resumed with each return context.
  final List<Context> returns = [];

  /// Creates a GSS node for a rule call.
  Caller(this.rule, this.pattern, this.startPos, this.minPrecedenceLevel);

  /// Registers a waiter for the result of this rule call.
  /// Returns true if the waiter was added (new), false if duplicate.
  bool addWaiter(CallerKey? parent, State next, int? minPrec, Context cctx, _ParseNode node) {
    for (final w in waiters) {
      if (w.$1 == parent && w.$2 == next && w.$3 == minPrec && w.$4 == cctx) return false;
    }
    waiters.add((parent, next, minPrec, cctx, node));
    return true;
  }

  /// Registers a successful rule completion as a return context.
  /// Returns true if the return was added (new), false if duplicate.
  bool addReturn(Context ctx) {
    if (returns.contains(ctx)) return false;
    returns.add(ctx);
    return true;
  }

  /// Invokes a callback for each waiter, passing its components.
  /// Used to trigger all waiters when a return is recorded.
  void forEach(void Function(CallerKey?, State, int?, Context, _ParseNode) callback) {
    for (final (key, state, minPrec, ctx, node) in waiters) {
      callback(key, state, minPrec, ctx, node);
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
/// Parsing state context carrying marks, caller info, and parse constraints.
///
/// Contexts are immutable snapshots of parsing state, copied and evolved as
/// parsing progresses. They carry all information needed to resume parsing
/// after lookahead, rule calls, or other complex control flow.
///
/// Key responsibilities:
/// - caller: identifies who initiated this parse (root, rule call, predicate sub-parse)
/// - marks: accumulated semantic annotations (NamedMark and StringMark)
/// - callStart: input position where current rule was invoked (for BSR recording)
/// - pivot: input position of last matched symbol (for BSR midPoints)
/// - tokenHistory: link to token history for backtracking support
/// - minPrecedenceLevel: constraint for operator precedence filtering
/// - precedenceLevel: precedence of current result (set by ReturnAction)
/// - predicateStack: stack of active lookahead predicates
///
/// Critical for:
/// - Memoization: contexts must match for cached results to apply
/// - Semantic actions: marks accumulate through the context
/// - Precedence filtering: minPrecedenceLevel constrains valid parses
/// - Error recovery: contexts preserve parse state for diagnostics
class Context {
  /// The caller that initiated this parse (root, rule call, or predicate sub-parse).
  /// Used to match returns from sub-parses to their call sites for proper memoization.
  final CallerKey caller;

  /// Accumulated semantic annotations (NamedMark and StringMark) in order.
  /// Marks represent semantic values produced during parsing.
  final GlushList<Mark> marks;

  /// Stack of active lookahead predicates.
  /// Ensures correct activeFrames tracking through rule calls.
  final GlushList<PredicateCallerKey> predicateStack;

  /// The input position where the current rule call began.
  /// Essential for BSR recording to identify rule completion spans.
  final int? callStart;

  /// The input position of the last matched symbol.
  /// Used as the midPoint in BSR entries for separating parsing phases.
  final int? pivot;

  /// Reference to the token history node at this parsing position.
  /// Enables backtracking and lookahead by accessing past tokens.
  final TokenNode? tokenHistory;

  /// Minimum precedence level constraint for accepting returns.
  /// Used for operator precedence filtering in precedence-aware grammars.
  final int? minPrecedenceLevel;

  /// Precedence level of the parse result in this context.
  /// Set by ReturnAction when completing a precedence-constrained rule.
  final int? precedenceLevel;

  /// Creates a parsing context with the given caller and accumulated marks.
  const Context(
    this.caller,
    this.marks, {
    this.predicateStack = const GlushList.empty(),
    this.callStart,
    this.pivot,
    this.tokenHistory,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  });

  /// Creates a copy of this context with selected fields replaced.
  /// Immutability is maintained by creating a new Context.
  Context copyWith({
    CallerKey? caller,
    GlushList<Mark>? marks,
    GlushList<PredicateCallerKey>? predicateStack,
    int? callStart,
    int? pivot,
    TokenNode? tokenHistory,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    return Context(
      caller ?? this.caller,
      marks ?? this.marks,
      predicateStack: predicateStack ?? this.predicateStack,
      callStart: callStart ?? this.callStart,
      pivot: pivot ?? this.pivot,
      tokenHistory: tokenHistory ?? this.tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
    );
  }
}

/// Set of parsing states to explore from a single context.
///
/// Frames are the primary work units in the parser. Each frame represents
/// a set of state machine states ready to process from the same (caller, marks) pair.
///
/// The parser processes frames at each position by enqueueing their states
/// into a work list, then draining the list completely before moving to the
/// next position. This ensures proper parse order and predicate handling.
///
/// Critical invariants:
/// - All states in a frame share the same context
/// - Frames are process in position order (work queue sorts by position)
/// - Frame finalization groups results by (state, caller, precedence)
///
/// Essential for: managing parse alternatives, grouping results, and
/// controlling the exploration order in LR-like parsing.
class Frame {
  /// The parsing context shared by all states in this frame.
  /// Carries marks, caller information, and precedence constraints.
  final Context context;

  /// State machine states to explore in this frame.
  /// All states are processed with the same context before finalizing.
  final Set<State> nextStates;

  /// Creates a frame with the given context and empty state set.
  Frame(this.context) : nextStates = {};

  /// Creates a shallow copy of this frame with the same context.
  Frame copy() => Frame(context);

  /// Returns the caller from the frame's context.
  /// Shorthand for accessing context.caller.
  CallerKey? get caller => context.caller;

  /// Returns the accumulated marks from the frame's context.
  /// Shorthand for accessing context.marks.
  GlushList<Mark> get marks => context.marks;
}

/// Single parsing step at one input position.
///
/// Encapsulates all parse work for a single input position. Steps manage:
/// - Work list of (state, context) pairs to process
/// - Active contexts for deduplication (in non-ambiguous mode)
/// - Caller (GSS) nodes for rule memoization
/// - Predicate tracking and completion
/// - Frame grouping and finalization for next position
///
/// Critical responsibilities:
/// - Process all states from all frames at current position
/// - Handle rule calls via GSS memoization (Caller objects)
/// - Track lookahead predicates and their state
/// - Build next frames for subsequent positions
/// - Record BSR for forest extraction
///
/// Key invariant: frames at earlier positions are processed before frames at
/// the current position, ensuring correct parse order and predicate semantics.
///
/// Essential for:
/// - Core parsing algorithm execution
/// - Memoization and deduplication
/// - Predicate sub-parse coordination
/// - Result aggregation and forest construction
typedef _ParseNode = (int stateId, int pos, Object? caller);
typedef _Predecessor = (
  _ParseNode? source,
  StateAction? action,
  GlushList<Mark> marks,
  _ParseNode? callSite,
);

class Step {
  /// Reference to the parent parser for accessing global state.
  final SMParser parser;

  /// The current input token (character code) or null for end-of-input.
  final int? token;

  /// The input position this step processes.
  final int position;

  /// BSR (Binarised Shared Representation) set being built during parsing.
  /// Null in basic parse modes, populated for forest construction.
  final BsrSet? bsr;

  /// Whether this step supports ambiguous parsing (merges marks from all derivations).
  final bool isSupportingAmbiguity;

  /// Whether tokens should be captured as semantic mark annotations.
  final bool captureTokensAsMarks;

  /// Manager for allocating and merging GlushList<Mark> objects.
  final GlushListManager<Mark> markManager;

  /// Predecessor graph for forest extraction (maps parse nodes to their sources).
  final Map<_ParseNode, Set<_Predecessor>> predecessors;

  /// Frames to process in the next parsing step.
  final List<Frame> nextFrames = [];

  /// Groups marks by (state, caller, precedence, predicateStack) for deduplication and merging.
  final Map<(State, CallerKey, int?, GlushList<PredicateCallerKey>), List<GlushList<Mark>>>
  _nextFrameGroups = {};

  /// Groups predecessors by (state, caller, precedence, predicateStack) for forest construction.
  final Map<(State, CallerKey, int?, GlushList<PredicateCallerKey>), Set<_Predecessor>>
  _nextPredecessorGroups = {};

  /// Active contexts to prevent duplicate processing in non-ambiguous mode.
  final Map<(State, CallerKey, int?, GlushList<PredicateCallerKey>), GlushList<Mark>>
  _activeContexts = {};

  /// Work queue of (state, context) pairs to process at this position.
  final Queue<(State, Context)> _currentWorkList = DoubleLinkedQueue();

  /// Caller (GSS) nodes for rule memoization at this position and call position.
  final Map<(Rule, int, int?), Caller> _callers = {};

  /// Tracks which callers have already returned to avoid duplicate processing.
  final Set<CallerKey> _returnedCallers = {};

  /// Accepted contexts that successfully parsed the input up to this position.
  final List<(State, Context)> _acceptedContexts = [];

  /// Callback to requeue frames for processing at earlier positions (for lookahead).
  final void Function(List<Frame>) requeue;

  /// Creates a step for parsing at the given position.
  /// Creates a step for parsing at the given position.
  Step(
    this.parser,
    this.token,
    this.position, {
    this.bsr,
    required this.markManager,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    required this.requeue,
    required this.predecessors,
  });

  /// Completes a lookahead predicate assertion, resuming waiting frames.
  /// Handles both positive (&pattern) and negative (!pattern) completion.
  void _finishPredicate(PredicateTracker tracker, bool matched) {
    if (matched) {
      tracker.matched = true;
      for (final (parentCtx, nextState) in tracker.waiters) {
        final pk = parentCtx.predicateStack.lastOrNull;
        if (pk != null) {
          final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
          parentTracker?.activeFrames--;
        }

        if (tracker.isAnd) {
          requeue([Frame(parentCtx)..nextStates.add(nextState)]);
        }
      }
      tracker.waiters.clear();
    } else if (tracker.activeFrames == 0) {
      for (final (parentCtx, nextState) in tracker.waiters) {
        final pk = parentCtx.predicateStack.lastOrNull;
        if (pk != null) {
          final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
          parentTracker?.activeFrames--;
        }

        if (!tracker.isAnd) {
          requeue([Frame(parentCtx)..nextStates.add(nextState)]);
        }
      }
      tracker.waiters.clear();
    }
  }

  /// Returns the token at the given frame's position.
  /// Uses current token if frame is at current position, otherwise looks in history.
  int? _getTokenFor(Frame frame) {
    final framePos = frame.context.pivot ?? 0;
    if (framePos == position) return token;
    return parser._historyByPosition[framePos]?.unit;
  }

  /// Returns true if this step contains at least one accepted context.
  /// Indicates successful parse completion at the start symbol.
  bool get accept => _acceptedContexts.isNotEmpty;

  /// Returns the semantic marks from the first accepted context.
  /// Used for accessing parse results in non-ambiguous mode.
  List<Mark> get marks {
    if (_acceptedContexts.isEmpty) return [];
    return _acceptedContexts[0].$2.marks.toList().cast<Mark>();
  }

  /// Enqueues a state with a context for processing in this step.
  /// Handles deduplication, predicate tracking, and predecessor recording.
  void _enqueue(
    State state,
    Context context, {
    _ParseNode? source,
    StateAction? action,
    GlushList<Mark> marks = const GlushList.empty(),
    _ParseNode? callSite,
  }) {
    final targetPos = context.pivot ?? 0;
    if (targetPos != position) {
      requeue([Frame(context)..nextStates.add(state)]);
      return;
    }

    final key = (state, context.caller, context.minPrecedenceLevel, context.predicateStack);
    if (isSupportingAmbiguity) {
      if (source != null) {
        final target = (state.id, position, context.caller);
        predecessors.putIfAbsent(target, () => {}).add((source, action, marks, callSite));
      }

      final existingMarks = _activeContexts[key];
      if (existingMarks != null) return;
      _activeContexts[key] = context.marks;
    } else {
      if (_activeContexts.containsKey(key)) return;
      _activeContexts[key] = context.marks;
    }

    final pk = context.predicateStack.lastOrNull;
    if (pk != null) {
      final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
      if (tracker != null) {
        tracker.activeFrames++;
      }
    }

    _currentWorkList.add((state, context));
  }

  /// Processes all state actions, enqueuing new states and handling lookahead.
  /// Dispatches to specific action handlers (TokenAction, MarkAction, etc.).
  void _process(Frame frame, State state) {
    for (final action in state.actions) {
      switch (action) {
        case SemanticAction():
          _enqueue(
            action.nextState,
            Context(
              frame.caller ?? const RootCallerKey(),
              frame.marks,
              predicateStack: frame.context.predicateStack,
              callStart: frame.context.callStart,
              pivot: frame.context.pivot,
              tokenHistory: frame.context.tokenHistory,
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
          );
        case TokenAction():
          final token = _getTokenFor(frame);
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.marks;
            final pattern = action.pattern;
            bool shouldCapture = captureTokensAsMarks;
            if (pattern is Token && pattern.choice is! ExactToken) {
              shouldCapture = true;
            }

            if (shouldCapture) {
              newMarks = newMarks.add(
                markManager,
                StringMark(String.fromCharCode(token), position),
              );
            }

            if (bsr != null && frame.caller is Caller) {
              final rule = (frame.caller as Caller).rule;
              bsr!.add(rule.symbolId!, frame.context.callStart!, position, position + 1);
            }

            final nextKey = (
              action.nextState,
              frame.caller ?? const RootCallerKey(),
              frame.context.minPrecedenceLevel,
              frame.context.predicateStack,
            );
            _nextFrameGroups.putIfAbsent(nextKey, () => []).add(newMarks);
            if (isSupportingAmbiguity) {
              final source = (state.id, position, frame.context.caller);
              final deltaMarks = shouldCapture
                  ? const GlushList<Mark>.empty().add(
                      markManager,
                      StringMark(String.fromCharCode(token), position),
                    )
                  : const GlushList<Mark>.empty();
              _nextPredecessorGroups.putIfAbsent(nextKey, () => {}).add((
                source,
                action,
                deltaMarks,
                null,
              ));
            }
          }
        case MarkAction():
          final mark = NamedMark(action.name, position);
          final deltaMarks = const GlushList<Mark>.empty().add(markManager, mark);
          _enqueue(
            action.nextState,
            Context(
              frame.caller ?? const RootCallerKey(),
              frame.marks.add(markManager, mark),
              predicateStack: frame.context.predicateStack,
              callStart: frame.context.callStart,
              pivot: frame.context.pivot,
              tokenHistory: frame.context.tokenHistory,
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
            marks: deltaMarks,
          );
        case PredicateAction():
          final symbol = action.symbol;
          final subParseKey = (symbol, position);
          final isFirst = !parser._predicateTrackers.containsKey(subParseKey);
          final tracker = parser._predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTracker(symbol, position, isAnd: action.isAnd),
          );

          if (tracker.matched) {
            if (tracker.isAnd) {
              requeue([Frame(frame.context)..nextStates.add(action.nextState)]);
            }
          } else {
            tracker.waiters.add((frame.context, action.nextState));
          }

          final pk = frame.context.predicateStack.lastOrNull;
          if (pk != null) {
            final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
            parentTracker?.activeFrames++;
          }

          if (isFirst && !tracker.matched) {
            final states = parser.stateMachine.ruleFirst[symbol];
            if (states == null) {
              throw StateError('Predicate symbol must resolve to a rule: $symbol');
            }
            final newPredicateKey = PredicateCallerKey(symbol, position);
            final nextStack = parser._predicateStackManager.push(
              frame.context.predicateStack,
              newPredicateKey,
            );

            for (final firstState in states) {
              _enqueue(
                firstState,
                Context(
                  newPredicateKey,
                  const GlushList.empty(),
                  predicateStack: nextStack,
                  callStart: position,
                  pivot: position,
                  tokenHistory: frame.context.tokenHistory,
                ),
              );
            }
          }
        case CallAction():
          final key = (action.rule, position, action.minPrecedenceLevel);
          final isNewCaller = !_callers.containsKey(key);
          final caller = _callers.putIfAbsent(
            key,
            () => Caller(action.rule, action.pattern, position, action.minPrecedenceLevel),
          );
          final isNewWaiter = caller.addWaiter(
            frame.caller,
            action.returnState,
            action.minPrecedenceLevel,
            frame.context,
            (state.id, position, frame.context.caller),
          );

          if (isNewCaller) {
            final states = parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
            for (final fs in states) {
              _enqueue(
                fs,
                Context(
                  caller,
                  const GlushList.empty(),
                  predicateStack: frame.context.predicateStack,
                  callStart: position,
                  pivot: position,
                  tokenHistory: frame.context.tokenHistory,
                  minPrecedenceLevel: action.minPrecedenceLevel,
                ),
              );
            }
          } else if (isNewWaiter) {
            for (final rctx in caller.returns) {
              _triggerReturn(
                caller,
                frame.caller,
                action.returnState,
                action.minPrecedenceLevel,
                frame.context,
                rctx,
                source: (state.id, position, caller),
                action: action,
                callSite: (state.id, position, frame.context.caller),
              );
            }
          }
        case ReturnAction():
          if (frame.context.minPrecedenceLevel != null &&
              action.precedenceLevel != null &&
              action.precedenceLevel! < frame.context.minPrecedenceLevel!)
            continue;
          if (_getTokenFor(frame) case var t?
              when action.rule.guard != null && !action.rule.guard!.match(t))
            continue;

          final caller = frame.caller;
          final callStart = frame.context.callStart ?? (caller is Caller ? caller.startPos : null);
          if (bsr != null && callStart != null)
            bsr!.add(action.rule.symbolId!, callStart, frame.context.pivot ?? callStart, position);

          if (caller is PredicateCallerKey) {
            final tracker = parser._predicateTrackers[(caller.pattern, caller.startPos)];
            if (tracker != null) {
              _finishPredicate(tracker, true);
            }
            continue;
          }

          if (bsr != null && caller is Caller) {
            caller.forEach((p, s, mp, pc, node) {
              if (p is Caller) bsr!.add(p.rule.symbolId!, pc.callStart!, caller.startPos, position);
            });
          }

          if (!isSupportingAmbiguity && !_returnedCallers.add(caller ?? const RootCallerKey()))
            continue;

          if (caller is Caller) {
            final returnContext = frame.context.copyWith(precedenceLevel: action.precedenceLevel);
            if (caller.addReturn(returnContext)) {
              for (final waiter in caller.waiters) {
                _triggerReturn(
                  caller,
                  waiter.$1,
                  waiter.$2,
                  waiter.$3,
                  waiter.$4,
                  returnContext,
                  source: (state.id, position, caller),
                  action: action,
                  callSite: waiter.$5,
                );
              }
            }
          }
        case AcceptAction():
          _acceptedContexts.add((state, frame.context));
      }
    }
  }

  /// Resumes a waiting frame when a rule call completes.
  /// Merges marks from the rule result with the parent context's marks.
  /// Records BSR entries if forest construction is enabled.
  void _triggerReturn(
    Caller caller,
    CallerKey? parent,
    State nextState,
    int? minPrecedence,
    Context parentContext,
    Context returnContext, {
    _ParseNode? source,
    StateAction? action,
    _ParseNode? callSite,
  }) {
    if (minPrecedence != null &&
        returnContext.precedenceLevel != null &&
        returnContext.precedenceLevel! < minPrecedence) {
      return;
    }
    final nextMarks = markManager
        .branched([parentContext.marks])
        .addList(markManager, returnContext.marks);

    final nextContext = Context(
      parent ?? const RootCallerKey(),
      nextMarks,
      predicateStack: parentContext.predicateStack,
      callStart: parentContext.callStart,
      pivot: returnContext.pivot,
      tokenHistory: parentContext.tokenHistory,
      minPrecedenceLevel: parentContext.minPrecedenceLevel,
    );
    if (bsr != null && parent is Caller) {
      bsr!.add(
        parent.rule.symbolId!,
        parentContext.callStart!,
        caller.startPos,
        returnContext.pivot ?? position,
      );
    }
    _enqueue(nextState, nextContext, source: source, action: action, callSite: callSite);
  }

  /// Groups results from _nextFrameGroups into Frame objects for the next position.
  /// Handles mark merging, caller initialization, and predicate tracking.
  void _finalize(Frame parentFrame) {
    for (final entry in _nextFrameGroups.entries) {
      final (state, caller, minP, pStack) = entry.key;
      final merged = markManager.branched(entry.value);
      int? nCS = (caller is Caller) ? caller.startPos : (caller is RootCallerKey ? 0 : null);
      final nextFrame = Frame(
        Context(
          caller,
          merged,
          predicateStack: pStack,
          callStart: nCS,
          pivot: position + 1,
          tokenHistory: parser._historyByPosition[position],
          minPrecedenceLevel: minP,
        ),
      );
      nextFrame.nextStates.add(state);
      if (pStack.lastOrNull case PredicateCallerKey pk) {
        final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
        tracker?.activeFrames++;
      }

      if (isSupportingAmbiguity) {
        final target = (state.id, position + 1, caller);
        if (_nextPredecessorGroups[entry.key] case var preds?)
          predecessors.putIfAbsent(target, () => {}).addAll(preds);
      }
      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
    _nextPredecessorGroups.clear();
  }

  /// Processes a frame by enqueueing its states and draining the work list.
  /// Finalizes results into next frames after all states are processed.
  void _processFrame(Frame frame) {
    for (final state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_currentWorkList.isNotEmpty) {
      final (state, context) = _currentWorkList.removeFirst();
      if (context.predicateStack.lastOrNull case PredicateCallerKey pk) {
        final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
        tracker?.activeFrames--;
      }
      final currentMarks = isSupportingAmbiguity
          ? _activeContexts[(
              state,
              context.caller,
              context.minPrecedenceLevel,
              context.predicateStack,
            )]!
          : context.marks;
      _process(
        Frame(
          Context(
            context.caller,
            currentMarks,
            predicateStack: context.predicateStack,
            callStart: context.callStart,
            pivot: context.pivot,
            tokenHistory: context.tokenHistory,
            minPrecedenceLevel: context.minPrecedenceLevel,
          ),
        ),
        state,
      );
    }
    _finalize(frame);
  }
}
