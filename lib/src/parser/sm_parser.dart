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
import "package:glush/src/parser/common/tracer.dart";
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
/// The primary implementation of the Glush parser using a state machine.
///
/// [SMParser] takes a compiled [StateMachine] and drives the parsing process
/// by feeding tokens into the machine and managing the resulting parse forest.
/// It supports various modes of operation, from simple input recognition to
/// full semantic forest construction.
final class SMParser extends GlushParserBase implements RecognizerAndMarksParser {
  /// Creates an [SMParser] from a [grammar].
  ///
  /// This constructor automatically compiles the grammar into a [StateMachine].
  SMParser(GrammarInterface grammar) : stateMachine = StateMachine(grammar);

  /// Creates an [SMParser] directly from a pre-compiled [stateMachine].
  SMParser.fromStateMachine(this.stateMachine);

  /// Creates an [SMParser] from a serialized state machine JSON string.
  ///
  /// This is useful for loading pre-compiled grammars without the overhead
  /// of re-compiling the grammar at runtime.
  factory SMParser.fromImported(String jsonString, [GrammarInterface? grammar]) {
    var stateMachine = importFromJson(jsonString, grammar);
    return SMParser.fromStateMachine(stateMachine);
  }

  static final Context _initialContext = Context(const RootCallerKey());

  /// The underlying [StateMachine] that defines the transitions and slots
  /// for this parser.
  @override
  final StateMachine stateMachine;

  /// Returns the grammar that this parser is based on.
  @override
  GrammarInterface get grammar => stateMachine.grammar;

  /// Returns a Graphviz DOT representation of the compiled state machine.
  ///
  /// This is useful for debugging and visualizing the structure of the
  /// grammar's transitions and slot assignments.
  String toDot() => stateMachine.toDot();

  /// Returns the initial set of parser [Frame]s to start a new parse.
  ///
  /// This sets up the root context and activates the initial states of the
  /// grammar.
  @override
  List<Frame> get initialFrames {
    var initialFrame = Frame(_initialContext, const LazyGlushList<Mark>.empty());
    initialFrame.nextStates.addAll(stateMachine.initialStates);

    return [initialFrame];
  }

  /// Checks if the given [input] is valid according to the grammar.
  ///
  /// This is the most efficient way to validate input, as it avoids building
  /// a full parse forest or calculating semantic marks.
  @override
  bool recognize(String input, {ParseTracer? tracer}) {
    return GlushProfiler.measure("parser.recognize", () {
      var parseState = createParseState(tracer: tracer);
      var bytes = utf8.encode(input);

      for (var i = 0; i < bytes.length; i++) {
        var byte = bytes[i];
        var lookahead = i + 1 < bytes.length ? bytes[i + 1] : null;
        parseState.processToken(byte, lookahead: lookahead);
        if (!parseState.hasPendingWork) {
          return false;
        }
      }

      return parseState.finish().accept;
    });
  }

  /// Parses the [input] and returns a single derivation path.
  ///
  /// If the grammar is ambiguous, this method will return one valid
  /// interpretation. Use [parseAmbiguous] if you need all possible paths.
  ///
  /// [captureTokensAsMarks] can be set to true to include raw tokens in the
  /// resulting mark stream.
  @override
  ParseOutcome parse(String input, {bool captureTokensAsMarks = false, ParseTracer? tracer}) {
    return GlushProfiler.measure("parser.parse", () {
      var parseState = createParseState(captureTokensAsMarks: captureTokensAsMarks, tracer: tracer);
      var bytes = utf8.encode(input);

      for (var i = 0; i < bytes.length; i++) {
        var byte = bytes[i];
        var lookahead = i + 1 < bytes.length ? bytes[i + 1] : null;
        parseState.processToken(byte, lookahead: lookahead);
        if (!parseState.hasPendingWork) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();
      if (lastStep.accept) {
        var results = lastStep.acceptedContexts.values.first;
        var onlyPath = results.evaluate().allMarkPaths().first;

        return ParseSuccess(onlyPath);
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Parses the [input] and returns a forest containing all valid interpretations.
  ///
  /// This is used for ambiguous grammars where multiple derivation paths may
  /// exist for the same input.
  @override
  ParseOutcome parseAmbiguous(
    String input, {
    bool captureTokensAsMarks = false,
    ParseTracer? tracer,
  }) {
    return GlushProfiler.measure("parser.parse_ambiguous", () {
      var parseState = createParseState(
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks,
        tracer: tracer,
      );
      var bytes = utf8.encode(input);

      for (var i = 0; i < bytes.length; i++) {
        var byte = bytes[i];
        var lookahead = i + 1 < bytes.length ? bytes[i + 1] : null;
        parseState.processToken(byte, lookahead: lookahead);
        if (!parseState.hasPendingWork) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();

      if (lastStep.accept) {
        var branches = lastStep
            .acceptedContexts
            .values //
            .fold<LazyGlushList<Mark>>(const LazyGlushList.empty(), LazyGlushList.branched);

        return ParseAmbiguousSuccess(branches);
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Calculates the total number of distinct derivation paths for the [input].
  ///
  /// This provides a quick way to gauge the level of ambiguity in a parse
  /// result without fully evaluating all paths.
  int countAllParses(String input) {
    return parseAmbiguous(input).ambiguousSuccess()!.forest.countDerivations();
  }
}
