import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/core/list.dart';
import 'package:glush/src/core/mark.dart';
import 'package:glush/src/parser/state_machine.dart';
import 'common.dart';
import 'interface.dart';

/// Minimal version of [SMParser] that only supports recognize, parse, and parseAmbiguous.
///
/// Unlike the full [SMParser], this implementation does not build a Binary Subtree
/// Representation (BSR) or a Shared Packed Parse Forest (SPPF) by default. It is
/// optimized for cases where only the results (marks) are needed.
class SMParserMini extends GlushParserBase with ParserCore implements RecognizerAndMarksParser {
  static const Context _initialContext = Context(
    RootCallerKey(),
    GlushList.empty(),
    predicateStack: GlushList.empty(),
  );

  final StateMachine stateMachine;
  late final List<Frame> _initialFrames;

  @override
  bool captureTokensAsMarks;

  GrammarInterface get grammar => stateMachine.grammar;

  SMParserMini(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar) {
    _initInitialFrames();
  }

  SMParserMini.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false}) {
    _initInitialFrames();
  }

  void _initInitialFrames() {
    final initialFrame = Frame(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  @override
  bool recognize(String input) {
    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        predecessors: {},
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
      predecessors: {},
      captureTokensAsMarks: captureTokensAsMarks,
    );
    return lastStep.accept;
  }

  /// Standard parsing that returns the first valid result found.
  @override
  ParseOutcome parse(String input) {
    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        predecessors: {},
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
      predecessors: {},
      captureTokensAsMarks: captureTokensAsMarks,
    );

    if (lastStep.accept) {
      return ParseSuccess(ParserResult(lastStep.marks));
    } else {
      return ParseError(position);
    }
  }

  /// Parses ambiguous input and returns a forest of all possible results (marks).
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    final Map<ParseNodeKey, Set<PredecessorInfo>> predecessors = {};

    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = processTokenInternal(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
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
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
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
}
