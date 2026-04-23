import "package:glush/src/core/grammar.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/incremental/interval_tree.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// The core internal interface for the Glush parser engine.
///
/// [GlushParser] defines the low-level contract for processing tokens and
/// managing parser frames. It acts as the bridge between the high-level
/// grammar definition and the state machine execution.
abstract interface class GlushParser {
  /// The compiled state machine used by this parser.
  StateMachine get stateMachine;

  /// The grammar interface providing access to rules and symbols.
  GrammarInterface get grammar;

  /// The initial set of frames used to start the parsing process.
  List<Frame> get initialFrames;

  /// Processes a single [token] at [currentPosition] against a set of [frames].
  ///
  /// This is the heart of the incremental parsing loop. It calculates the next
  /// set of valid parser states based on the current input and active frames.
  Step processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    required ParseState parseState,
    bool isSupportingAmbiguity,
    bool captureTokensAsMarks,
  });

  /// Creates a new [ParseState] initialized with this parser's grammar and
  /// configuration.
  ParseState createParseState({
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
    ParseTracer? tracer,
    IntervalTree<CachedRuleResult>? previousIntervalIndex,
    IntervalTree<ParseCheckpoint>? previousCheckpointIndex,
  });
}

/// A high-level interface for simple input recognition.
///
/// [Recognizer] is used when you only need to know if a string is valid
/// according to the grammar, without needing to reconstruct the parse tree.
abstract interface class Recognizer {
  /// Returns true if [input] is valid according to the grammar.
  bool recognize(String input);
}

/// A high-level interface for parsing input into a semantic mark stream.
///
/// [MarksParser] is the primary interface for most users. It produces a
/// [ParseOutcome] which contains the semantic results of the parse.
abstract interface class MarksParser {
  /// Parses the [input] and returns the resulting [ParseOutcome].
  ParseOutcome parse(String input);

  /// Parses the [input], supporting ambiguous grammars if requested.
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks});
}

/// A combined interface that provides both recognition and full parsing.
abstract interface class RecognizerAndMarksParser implements Recognizer, MarksParser {}
