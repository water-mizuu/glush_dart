import "package:glush/glush.dart" show SMParser;
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/common/parser_base.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/sm_parser.dart" show SMParser;

/// Minimal version of [SMParser] that only supports recognize, parse, and parseAmbiguous.
///
/// Unlike the full [SMParser], this implementation does not build a Binary Subtree
/// Representation (BSR) or a Shared Packed Parse Forest (SPPF) by default. It is
/// optimized for cases where only the results (marks) are needed.
final class SMParserMini extends GlushParserBase implements RecognizerAndMarksParser {
  SMParserMini(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar);

  SMParserMini.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false});
  static final Context _initialContext = Context(const RootCallerKey());

  @override
  final StateMachine stateMachine;

  @override
  bool captureTokensAsMarks;

  @override
  GrammarInterface get grammar => stateMachine.grammar;

  @override
  List<Frame> get initialFrames {
    var initialFrame = Frame(_initialContext, const GlushList.empty());
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    return [initialFrame];
  }

  /// Fast recognition that stays on the State Machine path only.
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and rely
  /// only on the State Machine execution plus marks bookkeeping.
  @override
  bool recognize(String input) {
    return GlushProfiler.measure("parser.recognize", () {
      var parseState = createParseState(captureTokensAsMarks: captureTokensAsMarks);

      for (var codepoint in input.codeUnits) {
        parseState.processToken(codepoint);
        if (parseState.frames.isEmpty) {
          return false;
        }
      }

      return parseState.finish().accept;
    });
  }

  /// Standard parsing that returns the first valid result found.
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and rely
  /// only on the State Machine execution plus marks bookkeeping.
  @override
  ParseOutcome parse(String input) {
    return GlushProfiler.measure("parser.parse", () {
      var parseState = createParseState(captureTokensAsMarks: captureTokensAsMarks);

      for (var codepoint in input.codeUnits) {
        parseState.processToken(codepoint);
        if (parseState.frames.isEmpty) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();
      if (lastStep.accept) {
        var results = lastStep.acceptedContexts.values.first;
        var onlyPath = results.allPaths().first;

        return ParseSuccess(ParserResult(onlyPath));
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Parses ambiguous input and returns a forest of all possible results (marks).
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and derive
  /// ambiguity from the State Machine's marks system only.
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    return GlushProfiler.measure("parser.parse_ambiguous", () {
      var shouldCapture = captureTokensAsMarks ?? this.captureTokensAsMarks;
      var parseState = createParseState(
        isSupportingAmbiguity: true,
        captureTokensAsMarks: shouldCapture,
      );

      for (var codepoint in input.codeUnits) {
        parseState.processToken(codepoint);
        if (parseState.frames.isEmpty) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();
      if (lastStep.accept) {
        var results = lastStep.acceptedContexts.values.toList();
        var branches = results.fold(const GlushList<Mark>.empty(), GlushList.branched);

        return ParseAmbiguousSuccess(branches);
      } else {
        return ParseError(parseState.position);
      }
    });
  }
}
