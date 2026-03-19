/// Auto-generated standalone state machine for MinimalMath grammar
/// Generated: 2026-03-20 02:00:38.353353
import 'dart:convert';

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
  const CallActionSpec(this.ruleName, this.nextStateId);
  @override
  Map<String, dynamic> toJson() => {'type': 'call', 'ruleName': ruleName, 'nextStateId': nextStateId};
  static CallActionSpec fromJson(Map<String, dynamic> json) => CallActionSpec(json['ruleName'], json['nextStateId']);
}
class ReturnActionSpec extends StateActionSpec {
  final String ruleName;
  const ReturnActionSpec(this.ruleName);
  @override
  Map<String, dynamic> toJson() => {'type': 'return', 'ruleName': ruleName};
  static ReturnActionSpec fromJson(Map<String, dynamic> json) => ReturnActionSpec(json['ruleName']);
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
  const CallAction(this.ruleName, this.returnState);
}
class ReturnAction extends StateAction {
  final String ruleName;
  const ReturnAction(this.ruleName);
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
    if (aSpec is CallActionSpec) return CallAction(aSpec.ruleName, stateMap[aSpec.nextStateId]!);
    if (aSpec is ReturnActionSpec) return ReturnAction(aSpec.ruleName);
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

class SMParser {
  final StateMachine machine;
  final PredicateLookaheadBuffer _buffer = PredicateLookaheadBuffer();
  SMParser(this.machine);

  ParseOutcome parse(String input) {
    _buffer.initialize(input);
    var frames = machine.initialStates.map((s) => Frame(const Context(RootCallerKey(), null, 0), {s})).toList();
    int pos = 0;
    for (final unit in input.codeUnits) {
      final step = _process(unit, pos, frames);
      frames = step.nextFrames;
      if (frames.isEmpty) return ParseError(pos);
      pos++;
    }
    final finalStep = _process(null, pos, frames);
    return finalStep.accept ? ParseSuccess(ParserResult(finalStep.marks), finalStep.semanticValue) : ParseError(pos);
  }

  _Step _process(int? token, int pos, List<Frame> frames) {
    final step = _Step(this, token, pos);
    for (final f in frames) step._processFrame(f);
    return step;
  }

  bool _checkPredicate(PatternSymbol symbol, int pos) {
    final s = symbol.symbol;
    if (s == 'eps') return true;
    final split = s.split(':');
    if (split.length < 3) return true;
    final prefix = split[0];
    final suffix = split[2];
    if (prefix == 'tok') {
      if (pos >= _buffer.length) return false;
      final unit = _buffer.codeUnitAt(pos);
      if (suffix.isEmpty) return false;
      return switch (suffix[0]) {
        '.' => true,
        ';' => unit == int.parse(suffix.substring(1)),
        '<' => unit <= int.parse(suffix.substring(1)),
        '>' => unit >= int.parse(suffix.substring(1)),
        '[' => () {
          final parts = suffix.substring(1).split(',');
          return unit >= int.parse(parts[0]) && unit <= int.parse(parts[1]);
        }(),
        _ => false,
      };
    }
    return true;
  }
}

sealed class CallerKey { const CallerKey(); }
class RootCallerKey extends CallerKey { const RootCallerKey(); }
class Caller extends CallerKey {
  final String ruleName;
  final Map<(CallerKey, State), List<Context>> _grouped = {};
  Caller(this.ruleName);
  void addReturn(Context ctx, State next) => _grouped.putIfAbsent((ctx.caller, next), () => []).add(ctx);
}

class Context {
  final CallerKey caller;
  final GlushList<Mark>? marks;
  final Object? semanticValue;
  final int callStart;
  const Context(this.caller, this.marks, this.callStart, [this.semanticValue]);
}

class Frame {
  final Context context;
  final Set<State> nextStates;
  Frame(this.context, [Set<State>? states]) : nextStates = states ?? {};
}

class _Step {
  final SMParser parser;
  final int? token;
  final int position;
  final List<Frame> nextFrames = [];
  final Map<String, Caller> _callers = {};
  final Set<CallerKey> _returned = {};
  final List<Context> _accepted = [];

  _Step(this.parser, this.token, this.position);
  bool get accept => _accepted.isNotEmpty;
  List<Mark> get marks => _accepted.isEmpty ? [] : _accepted[0].marks?.toList().cast<Mark>() ?? [];
  Object? get semanticValue => _accepted.isEmpty ? null : _accepted[0].semanticValue;

  void _processFrame(Frame f) {
    for (final s in f.nextStates) _run(f.context, s);
  }

  void _run(Context ctx, State s) {
    for (final a in s.actions) {
      if (a is TokenAction) {
        if (token != null && a.match(token)) {
          final val = String.fromCharCode(token!);
          final nextVal = ctx.semanticValue == null ? val : [ctx.semanticValue, val];
          nextFrames.add(Frame(Context(ctx.caller, ctx.marks, ctx.callStart, nextVal), {a.nextState}));
        }
      } else if (a is MarkAction) {
        _run(Context(ctx.caller, (ctx.marks ?? const GlushList.empty()).add(NamedMark(a.name, position)), ctx.callStart, ctx.semanticValue), a.nextState);
      } else if (a is SemanticAction) {
        final res = <Object?>[ctx.semanticValue];
        final span = (ctx.callStart < parser._buffer.length && position <= parser._buffer.length) ? String.fromCharCodes(parser._buffer._buffer.sublist(ctx.callStart, position)) : '';
        final val = a.callback(span, res);
        _run(Context(ctx.caller, ctx.marks, ctx.callStart, val), a.nextState);
      } else if (a is PredicateAction) {
        if (parser._checkPredicate(a.symbol, position) == a.isAnd) _run(ctx, a.nextState);
      } else if (a is CallAction) {
        final c = _callers.putIfAbsent(a.ruleName, () => Caller(a.ruleName));
        final exists = c._grouped.isNotEmpty;
        c.addReturn(ctx, a.returnState);
        if (!exists) {
          for (final start in parser.machine.ruleFirst[a.ruleName] ?? []) _run(Context(c, const GlushList.empty(), position), start);
        }
      } else if (a is ReturnAction) {
        final c = ctx.caller;
        if (!_returned.add(c)) continue;
        if (c is Caller) {
          for (var entry in c._grouped.entries) {
            for (var cctx in entry.value) {
              final nextMarks = cctx.marks == null ? ctx.marks : GlushList.branched<Mark>([cctx.marks!]).addList(ctx.marks ?? const GlushList.empty());
              final nextVal = cctx.semanticValue == null ? ctx.semanticValue : [cctx.semanticValue, ctx.semanticValue];
              _run(Context(entry.key.$1, nextMarks, cctx.callStart, nextVal), entry.key.$2);
            }
          }
        }
      } else if (a is AcceptAction) {
        _accepted.add(ctx);
      }
    }
  }
}

/// Exported state machine specification as JSON
const String _MinimalMathStateMachineJson = r"""
{"version":2,"initialStates":[0],"startSymbol":"rul:S0:","childrenRegistry":{"rul:S0:":["alt:S1:"],"alt:S1:":["alt:S2:","cal:S15:"],"alt:S2:":["act:S3:","act:S9:"],"act:S3:":["seq:S4:"],"seq:S4:":["seq:S5:","cal:S8:"],"seq:S5:":["cal:S6:","tok:S7:;43"],"cal:S6:":["rul:S0:"],"tok:S7:;43":[],"cal:S8:":["rul:S16:"],"act:S9:":["seq:S10:"],"seq:S10:":["seq:S11:","cal:S14:"],"seq:S11:":["cal:S12:","tok:S13:;45"],"cal:S12:":["rul:S0:"],"tok:S13:;45":[],"cal:S14:":["rul:S16:"],"cal:S15:":["rul:S16:"],"rul:S16:":["act:S17:"],"act:S17:":["rca:S18:"],"rca:S18:":["rul:S19:"],"rul:S19:":["alt:S20:"],"alt:S20:":["act:S21:","tok:S25:[48,57"],"act:S21:":["seq:S22:"],"seq:S22:":["rca:S23:","tok:S24:[48,57"],"rca:S23:":["rul:S19:"],"tok:S24:[48,57":[],"tok:S25:[48,57":[]},"states":[{"id":0,"actions":[{"type":"call","ruleName":"expr","nextStateId":1}]},{"id":1,"actions":[{"type":"accept"}]},{"id":2,"actions":[{"type":"call","ruleName":"expr","nextStateId":3},{"type":"call","ruleName":"expr","nextStateId":4},{"type":"call","ruleName":"term","nextStateId":5}]},{"id":3,"actions":[{"type":"token","tokenSpec":{"type":"exact","value":43},"nextStateId":6}]},{"id":4,"actions":[{"type":"token","tokenSpec":{"type":"exact","value":45},"nextStateId":9}]},{"id":5,"actions":[{"type":"return","ruleName":"expr"}]},{"id":6,"actions":[{"type":"call","ruleName":"term","nextStateId":7}]},{"id":7,"actions":[{"type":"semantic","actionId":"act:S3:","nextStateId":8}]},{"id":8,"actions":[{"type":"return","ruleName":"expr"}]},{"id":9,"actions":[{"type":"call","ruleName":"term","nextStateId":10}]},{"id":10,"actions":[{"type":"semantic","actionId":"act:S9:","nextStateId":11}]},{"id":11,"actions":[{"type":"return","ruleName":"expr"}]},{"id":12,"actions":[{"type":"call","ruleName":"__0","nextStateId":13}]},{"id":13,"actions":[{"type":"semantic","actionId":"act:S17:","nextStateId":14}]},{"id":14,"actions":[{"type":"return","ruleName":"term"}]},{"id":15,"actions":[{"type":"call","ruleName":"__0","nextStateId":16},{"type":"token","tokenSpec":{"type":"range","start":48,"end":57},"nextStateId":17}]},{"id":16,"actions":[{"type":"token","tokenSpec":{"type":"range","start":48,"end":57},"nextStateId":18}]},{"id":17,"actions":[{"type":"return","ruleName":"__0"}]},{"id":18,"actions":[{"type":"semantic","actionId":"act:S21:","nextStateId":19}]},{"id":19,"actions":[{"type":"return","ruleName":"__0"}]}],"rules":{"expr":{"name":"expr","firstStateIds":[2],"isEmpty":false},"term":{"name":"term","firstStateIds":[12],"isEmpty":false},"__0":{"name":"__0","firstStateIds":[15],"isEmpty":false}}}
""";

/// Load the exported state machine specification
ExportedStateMachine loadMinimalmathStateMachine() => ExportedStateMachine.fromJson(_MinimalMathStateMachineJson);


/// Create an imported state machine with action stubs
class MinimalmathActions {
  /// Override these methods with your semantic actions

  /// Semantic action stub for: act:S17:
  static Object? act_S17_Action(String span, List results) {
    // TODO: Implement semantic action
    // span: the matched substring
    // results: list of child semantic values
    throw UnimplementedError("Action not implemented for act:S17:");
  }

  /// Semantic action stub for: act:S21:
  static Object? act_S21_Action(String span, List results) {
    // TODO: Implement semantic action
    // span: the matched substring
    // results: list of child semantic values
    throw UnimplementedError("Action not implemented for act:S21:");
  }

  /// Semantic action stub for: act:S3:
  static Object? act_S3_Action(String span, List results) {
    // TODO: Implement semantic action
    // span: the matched substring
    // results: list of child semantic values
    throw UnimplementedError("Action not implemented for act:S3:");
  }

  /// Semantic action stub for: act:S9:
  static Object? act_S9_Action(String span, List results) {
    // TODO: Implement semantic action
    // span: the matched substring
    // results: list of child semantic values
    throw UnimplementedError("Action not implemented for act:S9:");
  }

}

/// Create a parser using the Minimalmath grammar
class MinimalmathParser {
  late final ImportedStateMachine _machine;
  late final SMParser _parser;

  MinimalmathParser({Map<String, Function>? actions}) {
    final spec = loadMinimalmathStateMachine();
    _machine = ImportedStateMachine(spec);

    // Attach default actions
    _machine.attachAction("act:S17:", MinimalmathActions.act_S17_Action);
    _machine.attachAction("act:S21:", MinimalmathActions.act_S21_Action);
    _machine.attachAction("act:S3:", MinimalmathActions.act_S3_Action);
    _machine.attachAction("act:S9:", MinimalmathActions.act_S9_Action);

    // Override with user-provided actions
    actions?.forEach((id, fn) => _machine.attachAction(id, fn));

    _parser = _machine.createParser();
  }

  SMParser get parser => _parser;
  ImportedStateMachine get machine => _machine;

  ParseOutcome parse(String input) => _parser.parse(input);
}
