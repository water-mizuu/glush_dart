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
final class SMParserMini extends GlushParserBase
    with ParserCore
    implements RecognizerAndMarksParser {
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

  List<Frame> get _initialFrames {
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
    clearState();
    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        captureTokensAsMarks: captureTokensAsMarks,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) return false;
      position++;
    }

    final lastStep = processTokenInternal(
      null,
      position,
      frames,
      captureTokensAsMarks: captureTokensAsMarks,
    );
    return lastStep.accept;
  }

  /// Standard parsing that returns the first valid result found.
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and rely
  /// only on the State Machine execution plus marks bookkeeping.
  @override
  ParseOutcome parse(String input) {
    clearState();
    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        captureTokensAsMarks: captureTokensAsMarks,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) return ParseError(position);
      position++;
    }

    final lastStep = processTokenInternal(
      null,
      position,
      frames,
      captureTokensAsMarks: captureTokensAsMarks,
    );

    if (lastStep.accept) {
      return ParseSuccess(ParserResult(lastStep.marks));
    } else {
      return ParseError(position);
    }
  }

  /// Parses ambiguous input and returns a forest of all possible results (marks).
  ///
  /// This method must remain independent of the BSR/SPPF pipeline and derive
  /// ambiguity from the State Machine's marks system only.
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    clearState();

    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
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
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
    );

    if (lastStep.accept) {
      final results = lastStep.acceptedContexts.map((entry) => entry.$2.marks).toList();
      return ParseAmbiguousForestSuccess(markCache.branched(results));
    } else {
      return ParseError(position);
    }
  }
}
