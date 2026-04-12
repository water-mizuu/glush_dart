import "package:glush/src/core/grammar.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

abstract interface class GlushParser {
  StateMachine get stateMachine;
  GrammarInterface get grammar;
  List<Frame> get initialFrames;

  Step processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    required ParseState parseState,
    bool isSupportingAmbiguity,
    bool captureTokensAsMarks,
  });
}

abstract interface class Recognizer {
  bool recognize(String input);
}

abstract interface class MarksParser {
  ParseOutcome parse(String input);
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks});
}

abstract interface class RecognizerAndMarksParser implements Recognizer, MarksParser {}
