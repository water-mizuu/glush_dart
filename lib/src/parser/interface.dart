import 'package:glush/src/representation/bsr.dart' show BsrParseOutcome;
import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/core/list.dart';
import 'package:glush/src/core/mark.dart';
import 'package:glush/src/parser/state_machine.dart';

import 'common.dart';

/// Key for tracking one structural derivation edge in ambiguous mode.
typedef DerivationKey = (ParseNodeKey? source, Object branchKey, ParseNodeKey? callSite);

/// Mutable runtime storage used by a parser during one parse session.
///
/// Keeping all parse-time mutable structures in one object makes reset cheap:
/// replacing this object discards all previous runtime state at once.
final class GlushParserRuntimeState {
  final Map<int, TokenNode> historyByPosition = {};
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};
  final Map<CallerCacheKey, Caller> callers = {};
  final GlushListManager<Mark> markManager = GlushListManager<Mark>();
  final GlushListManager<DerivationKey> derivationManager = GlushListManager<DerivationKey>();
  TokenNode? historyTail;
}

abstract interface class GlushParser {
  StateMachine get stateMachine;
  GlushParserRuntimeState get runtimeState;
  Map<int, TokenNode> get historyByPosition;
  Map<PredicateKey, PredicateTracker> get predicateTrackers;
  Map<CallerCacheKey, Caller> get callers;
  bool get captureTokensAsMarks;
  GlushListManager<Mark> get markManager;
  GlushListManager<DerivationKey> get derivationManager;
  GrammarInterface get grammar;

  /// Clear any state from previous parses
  void clearState();
}

abstract base class GlushParserBase implements GlushParser {
  GlushParserRuntimeState _runtimeState = GlushParserRuntimeState();

  @override
  GlushParserRuntimeState get runtimeState => _runtimeState;

  @override
  Map<int, TokenNode> get historyByPosition => _runtimeState.historyByPosition;

  @override
  Map<PredicateKey, PredicateTracker> get predicateTrackers => _runtimeState.predicateTrackers;

  @override
  Map<CallerCacheKey, Caller> get callers => _runtimeState.callers;

  @override
  GlushListManager<Mark> get markManager => _runtimeState.markManager;

  @override
  GlushListManager<DerivationKey> get derivationManager => _runtimeState.derivationManager;

  TokenNode? get historyTail => _runtimeState.historyTail;
  set historyTail(TokenNode? value) => _runtimeState.historyTail = value;

  @override
  void clearState() {
    historyByPosition.clear();
    predicateTrackers.clear();
    callers.clear();
    markManager.clear();
    derivationManager.clear();
    _runtimeState = GlushParserRuntimeState();
  }
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

abstract interface class RecognizerAndMarksParser implements Recognizer, MarksParser {}
