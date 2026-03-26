import 'package:glush/src/representation/bsr.dart';
import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/parser/state_machine.dart';

import 'common.dart';

/// Key for tracking one structural derivation edge in ambiguous mode.
typedef DerivationKey = (ParseNodeKey? source, Object branchKey, ParseNodeKey? callSite);

abstract interface class GlushParser {
  StateMachine get stateMachine;
  bool get captureTokensAsMarks;
  GrammarInterface get grammar;
  List<Frame> get initialFrames;
  Step processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    required ParseState parseState,
    BsrSet? bsr,
    bool isSupportingAmbiguity,
    bool? captureTokensAsMarks,
  });
}

abstract interface class Recognizer {
  bool recognize(String input);
}

abstract interface class MarksParser {
  ParseOutcome parse(String input);
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks});
}

abstract interface class ForestParser {
  ParseOutcome parseWithForest(String input);
  Future<ParseOutcome> parseWithForestAsync(Stream<String> input);
  BsrParseOutcome parseToBsr(String input);
}

abstract interface class RecognizerAndMarksParser implements Recognizer, MarksParser {}
