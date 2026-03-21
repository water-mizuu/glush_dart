/// Code generation for exported state machines
library glush.state_machine_codegen;

import 'state_machine_export.dart';

class StateMachineCodeGenerator {
  final ExportedStateMachine exported;
  final String grammarName;

  StateMachineCodeGenerator(this.exported, {required this.grammarName});

  /// Generate a standalone Dart file that can be imported and used
  String generateStandalone() {
    final buffer = StringBuffer();
    final pascalName = _toPascalCase(grammarName);

    buffer.writeln('/// Auto-generated state machine for $grammarName grammar');
    buffer.writeln('/// Generated: ${DateTime.now()}');
    buffer.writeln("import 'package:glush/glush.dart';");
    buffer.writeln();

    // Generate state machine data
    _generateStateData(buffer, pascalName);
    buffer.writeln();

    // Generate loader function
    _generateLoaderFunction(buffer, pascalName);
    buffer.writeln();

    // Generate parser factory
    _generateParserFactory(buffer, pascalName);

    return buffer.toString();
  }

  /// Generate a standalone Dart file that includes a minimal runtime
  String generateMinimalStandalone() {
    final buffer = StringBuffer();
    final pascalName = _toPascalCase(grammarName);

    buffer.writeln('/// Auto-generated standalone state machine for $grammarName grammar');
    buffer.writeln('/// Generated: ${DateTime.now()}');
    buffer.writeln("import 'dart:convert';");
    buffer.writeln("import 'dart:collection';");
    buffer.writeln();

    buffer.write(_minimalRuntimeSource);
    buffer.writeln();

    // Generate state machine data
    _generateStateData(buffer, pascalName);
    buffer.writeln();

    // Generate loader function
    _generateLoaderFunction(buffer, pascalName);
    buffer.writeln();

    // Generate parser factory
    _generateParserFactory(buffer, pascalName, minimal: true);

    return buffer.toString();
  }

  void _generateStateData(StringBuffer buffer, String pascalName) {
    // Export as JSON constant for easy serialization
    buffer.writeln('/// Exported state machine specification as JSON');
    buffer.writeln('const String _${grammarName}StateMachineJson = r"""');
    buffer.writeln(exported.toJson());
    buffer.writeln('""";');
  }

  void _generateLoaderFunction(StringBuffer buffer, String pascalName) {
    buffer.writeln('/// Load the exported state machine specification');
    buffer.writeln(
      'ExportedStateMachine load${pascalName}StateMachine() => '
      'ExportedStateMachine.fromJson(_${grammarName}StateMachineJson);',
    );
  }

  void _generateParserFactory(StringBuffer buffer, String pascalName, {bool minimal = false}) {
    // Collect all semantic action IDs used in the state machine
    final actionIds = <String>{};
    for (final state in exported.states) {
      for (final action in state.actions) {
        if (action is SemanticActionCallSpec) {
          actionIds.add(action.actionId);
        }
      }
    }

    buffer.writeln();
    buffer.writeln('/// Create an imported state machine with action stubs');
    buffer.writeln('class ${pascalName}Actions {');
    buffer.writeln('  /// Override these methods with your semantic actions');
    buffer.writeln();

    // Generate stub methods for each semantic action
    final sortedActionIds = actionIds.toList()..sort();
    for (final actionId in sortedActionIds) {
      // Clean up the action ID for method name (remove prefixes/suffixes if present)
      final methodName = _toSnakeCase(actionId.replaceAll(':', '_'));

      buffer.writeln('  /// Semantic action stub for: $actionId');
      buffer.writeln('  static Object? ${methodName}Action(String span, List results) {');
      buffer.writeln('    // TODO: Implement semantic action');
      buffer.writeln('    // span: the matched substring');
      buffer.writeln('    // results: list of child semantic values');
      buffer.writeln('    throw UnimplementedError("Action not implemented for $actionId");');
      buffer.writeln('  }');
      buffer.writeln();
    }

    buffer.writeln('}');
    buffer.writeln();

    buffer.writeln('/// Create a parser using the ${pascalName} grammar');
    buffer.writeln('class ${pascalName}Parser {');
    buffer.writeln('  late final ImportedStateMachine _machine;');
    buffer.writeln('  late final SMParser _parser;');
    buffer.writeln();
    buffer.writeln('  ${pascalName}Parser({Map<String, Function>? actions}) {');
    buffer.writeln('    final spec = load${pascalName}StateMachine();');
    buffer.writeln('    _machine = ImportedStateMachine(spec);');
    buffer.writeln();
    buffer.writeln('    // Attach default actions');
    for (final actionId in sortedActionIds) {
      final methodName = _toSnakeCase(actionId.replaceAll(':', '_'));
      buffer.writeln(
        '    _machine.attachAction("$actionId", ${pascalName}Actions.${methodName}Action);',
      );
    }
    buffer.writeln();
    buffer.writeln('    // Override with user-provided actions');
    buffer.writeln('    actions?.forEach((id, fn) => _machine.attachAction(id, fn));');
    buffer.writeln();
    buffer.writeln('    _parser = _machine.createParser();');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  SMParser get parser => _parser;');
    buffer.writeln('  ImportedStateMachine get machine => _machine;');
    buffer.writeln();
    buffer.writeln('  ParseOutcome parse(String input) => _parser.parse(input);');

    if (!minimal) {
      buffer.writeln('  Iterable<ParseDerivation> enumerateAllParses(String input) =>');
      buffer.writeln('    _parser.enumerateAllParses(input);');
      buffer.writeln(
        '  Iterable<ParseDerivationWithValue> '
        'enumerateAllParsesWithResults(String input) =>',
      );
      buffer.writeln('    _parser.enumerateAllParsesWithResults(input);');
    }

    buffer.writeln('}');
  }

  String _toPascalCase(String input) {
    return input
        .split('_')
        .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
        .join('');
  }

  String _toSnakeCase(String input) {
    return input.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (m) => '${m[1]}_${m[2]}'.toLowerCase(),
    );
  }
}

const String _minimalRuntimeSource = r'''
// ============================================================================
// MINIMAL GLUSH RUNTIME
// ============================================================================

// --- PatternSymbol ---
extension type const PatternSymbol(String symbol) {}

// --- GlushList ---
sealed class GlushList<T> {
  static GlushList<T> branched<T>(List<GlushList<T>> alternatives) {
    if (alternatives.isEmpty) return EmptyList<T>._();
    if (alternatives.length == 1) return alternatives[0];
    return BranchedList<T>._(alternatives);
  }

  const GlushList();
  const factory GlushList.empty() = EmptyList<T>._;

  GlushList<T> add(T data) => Push<T>._(this, data);

  GlushList<T> addList(GlushList<T> list) {
    if (list is EmptyList<T>) return this;
    if (this is EmptyList<T>) return list;
    return Concat<T>._(this, list);
  }

  List<T> toList() {
    final result = <T>[];
    forEach(result.add);
    return result;
  }

  void forEach(void Function(T) callback);
  bool get isEmpty;
}

class EmptyList<T> extends GlushList<T> {
  const EmptyList._();
  @override
  void forEach(void Function(T) callback) {}
  @override
  bool get isEmpty => true;
}

class BranchedList<T> extends GlushList<T> {
  final List<GlushList<T>> alternatives;
  const BranchedList._(this.alternatives);
  @override
  void forEach(void Function(T) callback) {
    for (final alt in alternatives) alt.forEach(callback);
  }
  @override
  bool get isEmpty => alternatives.every((a) => a.isEmpty);
}

class Push<T> extends GlushList<T> {
  final GlushList<T> parent;
  final T data;
  const Push._(this.parent, this.data);
  @override
  void forEach(void Function(T) callback) {
    parent.forEach(callback);
    callback(data);
  }
  @override
  bool get isEmpty => false;
}

class Concat<T> extends GlushList<T> {
  final GlushList<T> left;
  final GlushList<T> right;
  const Concat._(this.left, this.right);
  @override
  void forEach(void Function(T) callback) {
    left.forEach(callback);
    right.forEach(callback);
  }
  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;
}

// --- Marks ---
sealed class Mark {}
class NamedMark extends Mark {
  final String name;
  final int position;
  NamedMark(this.name, this.position);
  List<Object> toList() => [name, position];
  @override
  String toString() => 'NamedMark($name, $position)';
}
class StringMark extends Mark {
  final String value;
  final int position;
  StringMark(this.value, this.position);
  List<Object> toList() => [value, position];
  @override
  String toString() => 'StringMark($value, $position)';
}

// --- Errors ---
class GrammarError implements Exception {
  final String message;
  GrammarError(this.message);
  @override
  String toString() => 'GrammarError: $message';
}

// --- Token Specs ---
sealed class TokenSpec {
  const TokenSpec();
  bool matches(int? codeUnit);
  Map<String, dynamic> toJson();
  static TokenSpec fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'any' => const AnyTokenSpec(),
      'exact' => ExactTokenSpec(json['value'] as int),
      'range' => RangeTokenSpec(json['start'] as int, json['end'] as int),
      _ => throw UnsupportedError('Unknown token type: $type'),
    };
  }
}
class AnyTokenSpec extends TokenSpec {
  const AnyTokenSpec();
  @override
  bool matches(int? codeUnit) => codeUnit != null;
  @override
  Map<String, dynamic> toJson() => {'type': 'any'};
}
class ExactTokenSpec extends TokenSpec {
  final int value;
  const ExactTokenSpec(this.value);
  @override
  bool matches(int? codeUnit) => codeUnit == value;
  @override
  Map<String, dynamic> toJson() => {'type': 'exact', 'value': value};
}
class RangeTokenSpec extends TokenSpec {
  final int start;
  final int end;
  const RangeTokenSpec(this.start, this.end);
  @override
  bool matches(int? codeUnit) => codeUnit != null && codeUnit >= start && codeUnit <= end;
  @override
  Map<String, dynamic> toJson() => {'type': 'range', 'start': start, 'end': end};
}

// --- Exported Specs ---
class StateActionSpec {
  const StateActionSpec();
  Map<String, dynamic> toJson() => {};
  static StateActionSpec fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'token' => TokenActionSpec.fromJson(json),
      'mark' => MarkActionSpec.fromJson(json),
      'call' => CallActionSpec.fromJson(json),
      'return' => ReturnActionSpec.fromJson(json),
      'accept' => const AcceptActionSpec(),
      'predicate' => PredicateActionSpec.fromJson(json),
      'semantic' => SemanticActionCallSpec.fromJson(json),
      _ => throw UnsupportedError('Unknown action type: $type'),
    };
  }
}
class TokenActionSpec extends StateActionSpec {
  final TokenSpec tokenSpec;
  final int nextStateId;
  const TokenActionSpec(this.tokenSpec, this.nextStateId);
  @override
  Map<String, dynamic> toJson() => {'type': 'token', 'tokenSpec': tokenSpec.toJson(), 'nextStateId': nextStateId};
  static TokenActionSpec fromJson(Map<String, dynamic> json) => 
    TokenActionSpec(TokenSpec.fromJson(json['tokenSpec']), json['nextStateId']);
}
class MarkActionSpec extends StateActionSpec {
  final String name;
  final int nextStateId;
  const MarkActionSpec(this.name, this.nextStateId);
  @override
  Map<String, dynamic> toJson() => {'type': 'mark', 'name': name, 'nextStateId': nextStateId};
  static MarkActionSpec fromJson(Map<String, dynamic> json) => MarkActionSpec(json['name'], json['nextStateId']);
}
class CallActionSpec extends StateActionSpec {
  final String ruleName;
  final int nextStateId;
  final int? minPrecedenceLevel;
  const CallActionSpec(this.ruleName, this.nextStateId, [this.minPrecedenceLevel]);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'call',
    'ruleName': ruleName,
    'nextStateId': nextStateId,
    if (minPrecedenceLevel != null) 'minPrecedenceLevel': minPrecedenceLevel,
  };
  static CallActionSpec fromJson(Map<String, dynamic> json) => 
    CallActionSpec(json['ruleName'], json['nextStateId'], json['minPrecedenceLevel']);
}
class ReturnActionSpec extends StateActionSpec {
  final String ruleName;
  final int? precedenceLevel;
  const ReturnActionSpec(this.ruleName, [this.precedenceLevel]);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'return',
    'ruleName': ruleName,
    if (precedenceLevel != null) 'precedenceLevel': precedenceLevel,
  };
  static ReturnActionSpec fromJson(Map<String, dynamic> json) => 
    ReturnActionSpec(json['ruleName'], json['precedenceLevel']);
}
class AcceptActionSpec extends StateActionSpec {
  const AcceptActionSpec();
  @override
  Map<String, dynamic> toJson() => {'type': 'accept'};
}
class PredicateActionSpec extends StateActionSpec {
  final bool isAnd;
  final PatternSymbol symbol;
  final int nextStateId;
  const PredicateActionSpec({required this.isAnd, required this.symbol, required this.nextStateId});
  @override
  Map<String, dynamic> toJson() => {'type': 'predicate', 'isAnd': isAnd, 'symbol': symbol, 'nextStateId': nextStateId};
  static PredicateActionSpec fromJson(Map<String, dynamic> json) => 
    PredicateActionSpec(isAnd: json['isAnd'], symbol: PatternSymbol(json['symbol']), nextStateId: json['nextStateId']);
}
class SemanticActionCallSpec extends StateActionSpec {
  final String actionId;
  final int nextStateId;
  const SemanticActionCallSpec(this.actionId, this.nextStateId);
  @override
  Map<String, dynamic> toJson() => {'type': 'semantic', 'actionId': actionId, 'nextStateId': nextStateId};
  static SemanticActionCallSpec fromJson(Map<String, dynamic> json) => SemanticActionCallSpec(json['actionId'], json['nextStateId']);
}

class StateSpec {
  final int id;
  final List<StateActionSpec> actions;
  const StateSpec(this.id, this.actions);
  Map<String, dynamic> toJson() => {'id': id, 'actions': actions.map((a) => a.toJson()).toList()};
  static StateSpec fromJson(Map<String, dynamic> json) =>
    StateSpec(json['id'], (json['actions'] as List).map((a) => StateActionSpec.fromJson(a)).toList());
}

class RuleMetadataSpec {
  final String name;
  final List<int> firstStateIds;
  final bool isEmpty;
  const RuleMetadataSpec({required this.name, required this.firstStateIds, required this.isEmpty});
  Map<String, dynamic> toJson() => {'name': name, 'firstStateIds': firstStateIds, 'isEmpty': isEmpty};
  static RuleMetadataSpec fromJson(Map<String, dynamic> json) =>
    RuleMetadataSpec(name: json['name'], firstStateIds: (json['firstStateIds'] as List).cast<int>(), isEmpty: json['isEmpty']);
}

class ExportedStateMachine {
  final List<StateSpec> states;
  final List<int> initialStateIds;
  final PatternSymbol startSymbol;
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;
  final Map<String, RuleMetadataSpec> rules;
  const ExportedStateMachine({required this.states, required this.initialStateIds, required this.startSymbol, required this.childrenRegistry, required this.rules});

  String toJson() => jsonEncode({
    'initialStates': initialStateIds,
    'startSymbol': startSymbol,
    'childrenRegistry': childrenRegistry.map((k, v) => MapEntry(k as String, v)),
    'states': states.map((s) => s.toJson()).toList(),
    'rules': rules.map((k, v) => MapEntry(k, v.toJson())),
  });

  static ExportedStateMachine fromJson(String jsonString) {
    final json = jsonDecode(jsonString);
    return ExportedStateMachine(
      states: (json['states'] as List).map((s) => StateSpec.fromJson(s)).toList(),
      initialStateIds: (json['initialStates'] as List).cast<int>(),
      startSymbol: PatternSymbol(json['startSymbol']),
      childrenRegistry: (json['childrenRegistry'] as Map).map((k, v) => MapEntry(PatternSymbol(k), (v as List).cast<String>().map(PatternSymbol.new).toList())),
      rules: (json['rules'] as Map).map((k, v) => MapEntry(k, RuleMetadataSpec.fromJson(v))),
    );
  }
}

// --- Runtime ---
sealed class StateAction { const StateAction(); }
class TokenAction extends StateAction {
  final bool Function(int?) match;
  final State nextState;
  const TokenAction(this.match, this.nextState);
}
class MarkAction extends StateAction {
  final String name;
  final State nextState;
  const MarkAction(this.name, this.nextState);
}
class CallAction extends StateAction {
  final String ruleName;
  final State returnState;
  final int? minPrecedenceLevel;
  const CallAction(this.ruleName, this.returnState, [this.minPrecedenceLevel]);
}
class ReturnAction extends StateAction {
  final String ruleName;
  final int? precedenceLevel;
  const ReturnAction(this.ruleName, [this.precedenceLevel]);
}
class AcceptAction extends StateAction { const AcceptAction(); }
class PredicateAction extends StateAction {
  final bool isAnd;
  final PatternSymbol symbol;
  final State nextState;
  const PredicateAction({required this.isAnd, required this.symbol, required this.nextState});
}
class SemanticAction extends StateAction {
  final Object? Function(String span, List<Object?> results) callback;
  final State nextState;
  const SemanticAction(this.callback, this.nextState);
}

class State {
  final int id;
  final List<StateAction> actions = [];
  State(this.id);
}

class StateMachine {
  final List<State> states;
  final List<State> initialStates;
  final Map<String, List<State>> ruleFirst;
  StateMachine({required this.states, required this.initialStates, required this.ruleFirst});
}

class ImportedStateMachine {
  final ExportedStateMachine spec;
  final Map<String, Function?> _actionCallbacks = {};
  late final StateMachine _rebuilt;
  ImportedStateMachine(this.spec) { _rebuilt = _rebuild(); }
  void attachAction(String id, Function cb) { _actionCallbacks[id] = cb; }
  SMParser createParser() => SMParser(_rebuilt);

  StateMachine _rebuild() {
    final stateMap = {for (var s in spec.states) s.id: State(s.id)};
    for (var sSpec in spec.states) {
      final state = stateMap[sSpec.id]!;
      for (var aSpec in sSpec.actions) {
        state.actions.add(_reconstruct(aSpec, stateMap));
      }
    }
    final ruleFirst = spec.rules.map((name, rule) => MapEntry(name, rule.firstStateIds.map((id) => stateMap[id]!).toList()));
    return StateMachine(states: stateMap.values.toList(), initialStates: spec.initialStateIds.map((id) => stateMap[id]!).toList(), ruleFirst: ruleFirst);
  }

  StateAction _reconstruct(StateActionSpec aSpec, Map<int, State> stateMap) {
    if (aSpec is TokenActionSpec) return TokenAction(aSpec.tokenSpec.matches, stateMap[aSpec.nextStateId]!);
    if (aSpec is MarkActionSpec) return MarkAction(aSpec.name, stateMap[aSpec.nextStateId]!);
    if (aSpec is CallActionSpec) return CallAction(aSpec.ruleName, stateMap[aSpec.nextStateId]!, aSpec.minPrecedenceLevel);
    if (aSpec is ReturnActionSpec) return ReturnAction(aSpec.ruleName, aSpec.precedenceLevel);
    if (aSpec is AcceptActionSpec) return const AcceptAction();
    if (aSpec is PredicateActionSpec) return PredicateAction(isAnd: aSpec.isAnd, symbol: aSpec.symbol, nextState: stateMap[aSpec.nextStateId]!);
    if (aSpec is SemanticActionCallSpec) return SemanticAction((span, results) {
      final cb = _actionCallbacks[aSpec.actionId];
      return cb != null ? Function.apply(cb, [span, results]) : null;
    }, stateMap[aSpec.nextStateId]!);
    throw UnimplementedError();
  }
}

// --- Parser ---
sealed class ParseOutcome {}
class ParseError extends ParseOutcome {
  final int position;
  ParseError(this.position);
  @override String toString() => 'ParseError at $position';
}
class ParseSuccess extends ParseOutcome {
  final ParserResult result;
  final Object? semanticValue;
  ParseSuccess(this.result, [this.semanticValue]);
}
class ParserResult {
  final List<Mark> _marks;
  ParserResult(this._marks);
  List<String> get marks {
    final res = <String>[];
    String? cur;
    for (final m in _marks) {
      if (m is NamedMark) {
        if (cur != null) { res.add(cur); cur = null; }
        res.add(m.name);
      } else if (m is StringMark) {
        cur = (cur ?? '') + m.value;
      }
    }
    if (cur != null) res.add(cur);
    return res;
  }
}

class PredicateLookaheadBuffer {
  final List<int> _buffer = [];
  void initialize(String s) { _buffer.clear(); _buffer.addAll(s.codeUnits); }
  int codeUnitAt(int p) => (p < 0 || p >= _buffer.length) ? -1 : _buffer[p];
  int get length => _buffer.length;
}

// --- Token History Node ---
class TokenNode {
  final int unit;
  TokenNode? next;
  TokenNode(this.unit);
}

class Context {
  final CallerKey caller;
  final GlushList<Mark>? marks;
  final int? callStart;
  final int pivot;
  final TokenNode? tokenHistory;
  final int? minPrecedenceLevel;
  final Object? semanticValue;
  final GlushList<PredicateFrame> predicateStack;

  const Context(
    this.caller,
    this.marks, {
    this.callStart,
    this.pivot = 0,
    this.tokenHistory,
    this.minPrecedenceLevel,
    this.semanticValue,
    this.predicateStack = const GlushList.empty(),
  });
}

class PredicateFrame {
  final PatternSymbol symbol;
  final int startPos;
  final bool isAnd;
  const PredicateFrame(this.symbol, this.startPos, {required this.isAnd});
}

class Frame {
  final Context context;
  final Set<State> nextStates;
  Frame(this.context, [Set<State>? states]) : nextStates = states ?? {};
}

class CallerKey { const CallerKey(); }
class RootCallerKey extends CallerKey { const RootCallerKey(); }
class PredicateCallerKey extends CallerKey {
  final PatternSymbol symbol;
  final int startPos;
  const PredicateCallerKey(this.symbol, this.startPos);
}

class Caller extends CallerKey {
  final String ruleName;
  final Map<(CallerKey, State, int?), List<Context>> _grouped = {};
  int? callStart;
  Caller(this.ruleName);
  void addReturn(Context ctx, State next) => _grouped.putIfAbsent((ctx.caller, next, ctx.minPrecedenceLevel), () => []).add(ctx);
}

class SMParser {
  final StateMachine machine;
  final PredicateLookaheadBuffer _buffer = PredicateLookaheadBuffer();

  TokenNode? _historyTail;
  final Map<int, TokenNode> _historyByPosition = {};
  final Map<(PatternSymbol, int), bool> _predicateResults = {};

  SMParser(this.machine);

  ParseOutcome parse(String input) {
    _buffer.initialize(input);
    _historyTail = null;
    _historyByPosition.clear();
    _predicateResults.clear();

    var frames = machine.initialStates.map((s) => Frame(const Context(RootCallerKey(), null, callStart: 0, pivot: 0), {s})).toList();
    int pos = 0;
    while (true) {
      final unit = pos < input.length ? input.codeUnitAt(pos) : null;
      final step = _processToken(unit, pos, frames);
      if (pos >= input.length) {
        return step.accept ? ParseSuccess(ParserResult(step.marks), step.semanticValue) : ParseError(pos);
      }
      frames = step.nextFrames;
      if (frames.isEmpty) return ParseError(pos);
      pos++;
    }
  }

  _Step _processToken(int? token, int position, List<Frame> frames) {
    if (token != null) {
      final node = TokenNode(token);
      if (_historyTail == null) {
        _historyTail = node;
      } else {
        _historyTail!.next = node;
        _historyTail = node;
      }
      _historyByPosition[position] = node;
    }

    final stepsAtPosition = <int, _Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    void addFramesToQueue(List<Frame> newFrames) {
      for (final f in newFrames) {
        final pos = f.context.pivot;
        workQueue.putIfAbsent(pos, () => []).add(f);
      }
    }

    addFramesToQueue(frames);

    while (workQueue.isNotEmpty) {
      final pos = workQueue.firstKey()!;
      if (pos > position) break;

      final posFrames = workQueue.remove(pos)!;
      final currentStep = stepsAtPosition.putIfAbsent(pos, () {
        final posToken = (pos == position) ? token : _historyByPosition[pos]?.unit;
        return _Step(this, posToken, pos);
      });

      for (final f in posFrames) {
        currentStep._processFrame(f);
      }

      if (pos < position) {
        currentStep.finalize();
        addFramesToQueue(currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }
    }

    final resultStep = stepsAtPosition[position] ?? _Step(this, token, position);
    resultStep.finalize();
    return resultStep;
  }
}

class _Step {
  final SMParser parser;
  final int? token;
  final int position;
  final List<Frame> nextFrames = [];
  final Map<String, Caller> _callers = {};
  final Set<(State, CallerKey, int?)> _active = {};
  final List<Context> _accepted = [];

  final Map<(State, CallerKey, int?), List<(GlushList<Mark>?, Object?)>> _nextGroups = {};

  _Step(this.parser, this.token, this.position);
  bool get accept => _accepted.isNotEmpty;
  List<Mark> get marks => _accepted.isEmpty ? [] : _accepted[0].marks?.toList().cast<Mark>() ?? [];
  Object? get semanticValue => _accepted.isEmpty ? null : _accepted[0].semanticValue;

  int? _getTokenFor(Context ctx) {
    if (ctx.pivot == position) return token;
    return parser._historyByPosition[ctx.pivot]?.unit;
  }

  void _processFrame(Frame f) {
    for (final s in f.nextStates) _enqueue(s, f.context);
  }

  void _enqueue(State s, Context ctx) {
    final key = (s, ctx.caller, ctx.minPrecedenceLevel);
    if (!_active.add(key)) return;
    _run(ctx, s);
  }

  void _run(Context ctx, State s) {
    for (final a in s.actions) {
      if (a is TokenAction) {
        final t = _getTokenFor(ctx);
        if (t != null && a.match(t)) {
          final val = String.fromCharCode(t);
          final nextVal = ctx.semanticValue == null ? val : [ctx.semanticValue, val];
          final nextKey = (a.nextState, ctx.caller, ctx.minPrecedenceLevel);
          _nextGroups.putIfAbsent(nextKey, () => []).add((ctx.marks, nextVal));
        }
      } else if (a is MarkAction) {
        _run(Context(ctx.caller, (ctx.marks ?? const GlushList.empty()).add(NamedMark(a.name, position)), callStart: ctx.callStart, pivot: position, tokenHistory: ctx.tokenHistory, minPrecedenceLevel: ctx.minPrecedenceLevel, semanticValue: ctx.semanticValue, predicateStack: ctx.predicateStack), a.nextState);
      } else if (a is SemanticAction) {
        final res = <Object?>[ctx.semanticValue];
        final span = (ctx.callStart != null && ctx.callStart! < parser._buffer.length && position <= parser._buffer.length) ? String.fromCharCodes(parser._buffer._buffer.sublist(ctx.callStart!, position)) : '';
        final val = a.callback(span, res);
        _run(Context(ctx.caller, ctx.marks, callStart: ctx.callStart, pivot: position, tokenHistory: ctx.tokenHistory, minPrecedenceLevel: ctx.minPrecedenceLevel, semanticValue: val, predicateStack: ctx.predicateStack), a.nextState);
      } else if (a is PredicateAction) {
        final res = parser._predicateResults[(a.symbol, position)];
        if (res != null) {
          if (res == a.isAnd) _run(ctx, a.nextState);
          continue;
        }
        
        // Integrated sub-parse for lookahead
        final subParser = SMParser(parser.machine);
        // Copy buffer and history
        subParser._buffer._buffer.addAll(parser._buffer._buffer);
        subParser._historyByPosition.addAll(parser._historyByPosition);
        
        final subResult = subParser._checkRuleAt(a.symbol, position);
        parser._predicateResults[(a.symbol, position)] = subResult;
        if (subResult == a.isAnd) _run(ctx, a.nextState);
      } else if (a is CallAction) {
        final c = _callers.putIfAbsent(a.ruleName, () => Caller(a.ruleName));
        final exists = c._grouped.isNotEmpty;
        c.addReturn(ctx, a.returnState);
        if (!exists) {
          c.callStart = position;
          for (final start in parser.machine.ruleFirst[a.ruleName] ?? []) _run(Context(c, const GlushList.empty(), callStart: position, pivot: position, tokenHistory: parser._historyByPosition[position], minPrecedenceLevel: a.minPrecedenceLevel, predicateStack: ctx.predicateStack), start);
        }
      } else if (a is ReturnAction) {
        if (ctx.minPrecedenceLevel != null && a.precedenceLevel != null && a.precedenceLevel! < ctx.minPrecedenceLevel!) continue;
        final c = ctx.caller;
        if (c is Caller) {
          for (var entry in c._grouped.entries) {
            for (var cctx in entry.value) {
              final nextMarks = cctx.marks == null ? ctx.marks : GlushList.branched<Mark>([cctx.marks!]).addList(ctx.marks ?? const GlushList.empty());
              final nextVal = cctx.semanticValue == null ? ctx.semanticValue : [cctx.semanticValue, ctx.semanticValue];
              _run(Context(entry.key.$1, nextMarks, callStart: cctx.callStart, pivot: position, tokenHistory: cctx.tokenHistory, minPrecedenceLevel: entry.key.$3, semanticValue: nextVal, predicateStack: ctx.predicateStack), entry.key.$2);
            }
          }
        } else if (c is PredicateCallerKey) {
          // Handled by _checkRuleAt
        }
      } else if (a is AcceptAction) {
        _accepted.add(ctx);
      }
    }
  }

  void finalize() {
    for (final e in _nextGroups.entries) {
      final key = e.key;
      final items = e.value;
      final mergedMarks = GlushList.branched<Mark>(items.map((i) => i.$1 ?? const GlushList.empty()).toList());
      final mergedVal = items.length == 1 ? items[0].$2 : items.map((i) => i.$2).toList();
      
      int? nextCallStart;
      if (key.$2 is Caller) nextCallStart = (key.$2 as Caller).callStart;
      else if (key.$2 is RootCallerKey) nextCallStart = 0;

      nextFrames.add(Frame(Context(key.$2, mergedMarks, callStart: nextCallStart, pivot: position + 1, tokenHistory: parser._historyByPosition[position], minPrecedenceLevel: key.$3, semanticValue: mergedVal), {key.$1}));
    }
  }
}

extension on SMParser {
  bool _checkRuleAt(PatternSymbol symbol, int pos) {
    var frames = machine.ruleFirst[symbol.symbol]?.map((s) => Frame(Context(PredicateCallerKey(symbol, pos), null, callStart: pos, pivot: pos), {s})).toList() ?? [];
    if (frames.isEmpty) return false;
    
    int current = pos;
    final inputLen = _buffer.length;
    
    while (true) {
      final unit = current < inputLen ? _buffer.codeUnitAt(current) : null;
      final step = _processToken(unit, current, frames);
      if (step.accept) return true;
      if (current >= inputLen) return false;
      frames = step.nextFrames;
      if (frames.isEmpty) return false;
      current++;
    }
  }
}
''';
