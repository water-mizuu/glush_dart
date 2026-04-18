// ignore_for_file: comment_references

/// State machine-based parser implementation.
///
/// This module implements the core parsing engine for the Glush parser generator.
/// It converts an abstract grammar into a state machine and uses an LR-like algorithm
/// with support for:
/// - Recursive descent rule calls with Graph-Shared Stack (GSS) memoization
/// - Lookahead predicates for positive (&pattern) and negative (!pattern) assertions
/// - Operator precedence filtering for shift/reduce disambiguation
/// - Semantic actions and manual annotations (marks)
/// - Ambiguous parse paths
///
/// Key Classes:
/// - SMParser: Main parser interface with multiple parse methods
/// - Context: Parsing state carrying marks, caller info, and constraints
/// - Frame: A set of states to explore from a context
/// - Step: Processing state at a single input position
/// - Caller: Graph-Shared Stack node for rule call memoization
/// - PredicateTracker: Coordinator for lookahead predicate sub-parses
///
/// Parse Methods:
/// 1. recognize(): Boolean check (fastest)
/// 2. parse(): Marks-based parse with results
/// 3. parseAmbiguous(): All ambiguous interpretations merged
///
/// The parser uses a work-queue algorithm where frames at different input positions
/// can coexist, enabling proper handling of predicates without backtracking.
library glush.sm_parser;

import "dart:convert";

import "package:glush/glush.dart" show StateMachine;
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/common/parser_base.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:glush/src/parser/state_machine/state_machine_export.dart";

/// Main parser implementation using a state machine-based LR-like algorithm.
///
/// Converts an abstract grammar into a state machine (StateMachine) and drives
/// parsing using operator precedence filtering, memoization, and predicates.
/// Supports multiple parse modes: basic recognition and mark-based results.
///
/// Key capabilities:
/// - Fast [recognize] for boolean checks
/// - Marks-based [parse] for semantic annotations
/// - [parseAmbiguous] for ambiguity detection
/// - Lookahead predicates (&pattern, !pattern) for grammar constraints
/// - Operator precedence filtering for shift/reduce disambiguation
/// - Graph-Shared Stack (GSS) memoization for efficient rule processing
///
/// Critical for parsing complex grammars efficiently with support for
/// ambiguity and semantic actions.
final class SMParser extends GlushParserBase implements RecognizerAndMarksParser {
  /// Create a parser from a grammar.
  ///
  /// Builds the state machine on first use and initializes the parser state.
  /// The parser can then be reused across multiple parse() calls on different inputs.
  SMParser(GrammarInterface grammar) : stateMachine = StateMachine(grammar);
  SMParser.fromStateMachine(this.stateMachine);

  /// Create a parser from an imported state machine JSON.
  ///
  /// Quickly reconstructs a parser from a previously exported state machine
  /// without requiring grammar recompilation. Useful for production environments
  /// where fast startup is needed.
  ///
  /// Parameters:
  ///   [jsonString] - The exported state machine JSON from [StateMachine.exportToJson]
  ///   [grammar] - The grammar interface associated with this machine
  ///
  /// Returns:
  ///   An SMParser ready for immediate use
  factory SMParser.fromImported(String jsonString, [GrammarInterface? grammar]) {
    var stateMachine = importFromJson(jsonString, grammar);
    return SMParser.fromStateMachine(stateMachine);
  }

  static final Context _initialContext = Context(const RootCallerKey());

  /// The state machine constructed from the grammar.
  @override
  final StateMachine stateMachine;

  /// Returns the grammar used to construct this parser's state machine.
  @override
  GrammarInterface get grammar => stateMachine.grammar;

  /// Render the parser's compiled state machine as Graphviz DOT.
  String toDot() => stateMachine.toDot();

  @override
  List<Frame> get initialFrames {
    var initialFrame = Frame(_initialContext, const LazyGlushList<Mark>.empty());
    initialFrame.nextStates.addAll(stateMachine.initialStates);

    return [initialFrame];
  }

  /// Recognize input without building a parse tree (boolean result).
  ///
  /// Fast path that only checks if the input matches, without marking or
  /// other semantic computation. This method must remain independent of the
  /// BSR/SPPF pipeline and rely only on the State Machine execution and mark
  /// bookkeeping. Returns true iff the entire input is accepted.
  @override
  bool recognize(String input) {
    return GlushProfiler.measure("parser.recognize", () {
      var parseState = createParseState();

      for (var byte in utf8.encode(input)) {
        parseState.processToken(byte);
        // If no frames remain, the parser cannot recover from this prefix.
        if (!parseState.hasPendingWork) {
          return false;
        }
      }

      return parseState.finish().accept;
    });
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
  @override
  ParseOutcome parse(String input, {bool captureTokensAsMarks = false}) {
    return GlushProfiler.measure("parser.parse", () {
      var parseState = createParseState(captureTokensAsMarks: captureTokensAsMarks);

      for (var byte in utf8.encode(input)) {
        parseState.processToken(byte);
        // No active frames means the parse has already failed.
        if (!parseState.hasPendingWork) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();
      // Only a final accepted step counts as a successful parse.
      if (lastStep.accept) {
        var results = lastStep.acceptedContexts.values.first;
        var onlyPath = results.evaluate().allMarkPaths().first;

        return ParseSuccess(ParserResult(onlyPath, sppfTable: parseState.sppfTable));
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Parse input and return all ambiguous derivation paths.
  ///
  /// Like [parse], but records marks for all possible interpretations.
  /// In ambiguity mode, when multiple [state, caller, minPrec] tuples reach
  /// the same point, their mark lists are merged instead of deduplicated.
  /// This method must remain independent of the BSR/SPPF pipeline and derive
  /// ambiguity purely from the State Machine's marks system.
  ///
  /// Returns:
  /// - [ParseAmbiguousSuccess] if input matches (all interpretations merged)
  /// - [ParseError] if parsing fails
  @override
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks = false}) {
    return GlushProfiler.measure("parser.parse_ambiguous", () {
      var parseState = createParseState(
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks,
      );

      for (var byte in utf8.encode(input)) {
        parseState.processToken(byte);
        // No active frames means the parse has already failed.
        if (!parseState.hasPendingWork) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();

      // Ambiguous mode merges all accepted mark branches into one result.
      if (lastStep.accept) {
        var branches = lastStep.acceptedContexts.values.fold<LazyGlushList<Mark>>(
          const LazyGlushList.empty(),
          LazyGlushList.branched,
        );

        return ParseAmbiguousSuccess(branches);
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Count all possible parse trees without building them
  /// Internally count all derivations for a given input.
  ///
  /// Counts all possible parse trees without building them. Based on []
  /// and grammar-level recursion with memoization. Useful for understanding
  /// parser ambiguity without memory overhead.
  int countAllParses(String input) {
    return parseAmbiguous(input).ambiguousSuccess()!.forest.countDerivations();
  }
}
