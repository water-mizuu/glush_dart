import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/core/list.dart';
import 'package:glush/src/parser/state_machine.dart';
import 'common.dart';
import 'interface.dart';

/// Minimal version of [SMParser] that only supports recognize, parse, and parseAmbiguous.
///
/// Unlike the full [SMParser], this implementation does not build a Binary Subtree
/// Representation (BSR) or a Shared Packed Parse Forest (SPPF) by default. It is
/// optimized for cases where only the results (marks) are needed.
final class SMParserMini extends GlushParserBase implements RecognizerAndMarksParser {
  static const Context _initialContext = Context(
    RootCallerKey(),
    GlushList.empty(),
    predicateStack: GlushList.empty(),
  );

  final StateMachine stateMachine;

  @override
  bool captureTokensAsMarks;

  GrammarInterface get grammar => stateMachine.grammar;

  SMParserMini(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar);

  SMParserMini.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false});

  @override
  List<Frame> get initialFrames {
    final initialFrame = Frame(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    return [initialFrame];
  }

  /// Fast recognition that stays on the State Machine path only.
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and rely
  /// only on the State Machine execution plus marks bookkeeping.
  @override
  bool recognize(String input) {
    final parseState = this.createParseState(captureTokensAsMarks: captureTokensAsMarks);

    for (final codepoint in input.codeUnits) {
      parseState.processToken(codepoint);
      // If no frames remain, the parser cannot recover from this prefix.
      if (parseState.frames.isEmpty) return false;
    }

    return parseState.finish().accept;
  }

  /// Standard parsing that returns the first valid result found.
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and rely
  /// only on the State Machine execution plus marks bookkeeping.
  @override
  ParseOutcome parse(String input) {
    final parseState = this.createParseState(captureTokensAsMarks: captureTokensAsMarks);

    for (final codepoint in input.codeUnits) {
      parseState.processToken(codepoint);
      // No active frames means the parse has already failed.
      if (parseState.frames.isEmpty) {
        return ParseError(parseState.position - 1);
      }
    }

    final lastStep = parseState.finish();

    // Only a final accepted step counts as a successful parse.
    if (lastStep.accept) {
      return ParseSuccess(ParserResult(lastStep.marks));
    } else {
      return ParseError(parseState.position);
    }
  }

  /// Parses ambiguous input and returns a forest of all possible results (marks).
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and derive
  /// ambiguity from the State Machine's marks system only.
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    final shouldCapture = captureTokensAsMarks ?? this.captureTokensAsMarks;
    final parseState = this.createParseState(
      isSupportingAmbiguity: true,
      captureTokensAsMarks: shouldCapture,
    );

    for (final codepoint in input.codeUnits) {
      parseState.processToken(codepoint);
      // No active frames means the parse has already failed.
      if (parseState.frames.isEmpty) {
        return ParseError(parseState.position - 1);
      }
    }

    final lastStep = parseState.finish();

    // Ambiguous mode merges all accepted mark branches into one result.
    if (lastStep.accept) {
      final results = lastStep.acceptedContexts.map((entry) => entry.$2.marks).toList();
      return ParseAmbiguousForestSuccess(parseState.markCache.branched(results));
    } else {
      return ParseError(parseState.position);
    }
  }
}
