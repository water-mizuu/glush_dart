import 'package:glush/src/representation/bsr.dart' show BsrParseOutcome;
import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/core/list.dart';
import 'package:glush/src/core/mark.dart';
import 'package:glush/src/parser/state_machine.dart';

import 'common.dart';

abstract interface class GlushParser {
  StateMachine get stateMachine;
  Map<int, TokenNode> get historyByPosition;
  Map<PredicateKey, PredicateTracker> get predicateTrackers;
  bool get captureTokensAsMarks;
  GlushListManager<Mark> get markManager;
  GrammarInterface get grammar;
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
  Future<ParseOutcome> parseWithForestAsync(Stream<String> input, {int lookaheadWindowSize});
  BsrParseOutcome parseToBsr(String input);
}
