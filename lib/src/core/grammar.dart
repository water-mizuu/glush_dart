/// Grammar definition and building
library glush.grammar;

import "dart:collection";

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

typedef GrammarBuilder = Rule Function();

// Grammar interface to avoid circular import
sealed class GrammarInterface {
  /// Maps symbol IDs back to patterns for this grammar
  Map<PatternSymbol, Pattern> get registry;
  Map<PatternSymbol, List<PatternSymbol>> get childrenRegistry;

  RuleCall get startCall;
  PatternSymbol get startSymbol;
  List<Rule> get rules;
  Map<PatternSymbol, Rule> get allRules;
  bool isEmpty();
}

class Grammar implements GrammarInterface {
  Grammar(GrammarBuilder builder) {
    var result = builder();
    finalize(result.call());
  }

  @override
  final List<Rule> rules = [];

  @override
  late final RuleCall startCall;

  Map<Pattern, List<Pattern>>? transitions;

  StateMachine? _stateMachine;

  final Map<(Pattern, String), Rule> _hoistedPatternRules = {};

  @override
  final Map<PatternSymbol, Pattern> registry = {};

  @override
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry = {};

  @override
  final Map<PatternSymbol, Rule> allRules = {};

  @override
  PatternSymbol get startSymbol => startCall.rule.symbolId!;

  void finalize(RuleCall start) {
    startCall = start.consume() as RuleCall;

    // Discover all rules referenced from the start call
    var discoveredRules = <Rule>{startCall.rule};
    var toProcess = Queue.of([startCall.rule]);

    // Recursively discover rules by examining their bodies
    while (toProcess.isNotEmpty) {
      var rule = toProcess.removeFirst();

      // Now safe to call body() since rule is registered
      var body = rule.body();
      var referencedRules = <Rule>{};
      body.collectRules(referencedRules);

      for (var ref in referencedRules) {
        if (!discoveredRules.contains(ref)) {
          discoveredRules.add(ref);
          toProcess.addLast(ref);
        }
      }
    }

    rules.addAll(discoveredRules);
    _normalizePredicates();
    _normalizeHigherOrderPatterns();

    // Discover and assign symbol IDs to all patterns used in this grammar
    _assignPatternSymbols();
    _fillChildrenMapping();

    _computeEmpty();
    _computeTransitions();
  }

  /// Discovers all patterns in the grammar and assigns them symbol IDs
  void _assignPatternSymbols() {
    var allPatterns = <Pattern>{};

    // Collect all patterns from the grammar's rules, including the rules themselves
    for (var rule in rules) {
      allPatterns.add(rule); // Add the rule itself
      _collectPatternsFromRule(rule, allPatterns);
    }

    int symbolCounter = 0;
    // Assign symbol IDs to each pattern in discovery order
    for (var pattern in allPatterns) {
      pattern.symbolId ??= symbolCounter++;
      var actualSymbolId = pattern.symbolId!;
      registry[actualSymbolId] = pattern;
      if (pattern is Rule) {
        allRules[actualSymbolId] = pattern;
      }
    }
  }

  void _fillChildrenMapping() {
    for (var pattern in allPatterns) {
      childrenRegistry[pattern.symbolId!] = switch (pattern) {
        Token() ||
        Marker() ||
        StartAnchor() ||
        EofAnchor() ||
        Eps() ||
        ParameterRefPattern() ||
        ParameterCallPattern() ||
        LabelStart() ||
        LabelEnd() ||
        Backreference() => [],
        Alt(:var left, :var right) ||
        Seq(:var left, :var right) ||
        Conj(:var left, :var right) => [left.symbolId!, right.symbolId!],
        Label(:var child) ||
        Action(:var child) ||
        Prec(:var child) ||
        Opt(:var child) ||
        Plus(:var child) ||
        Star(:var child) => [child.symbolId!],
        Rule rule => [rule.body().symbolId!],
        RuleCall(:var rule) => [rule.symbolId!],
        And(:var pattern) || Not(:var pattern) => [pattern.symbolId!],
        IfCond(:var pattern) => [pattern.symbolId!],
      };
    }
  }

  /// Recursively collects all patterns used in a rule's body
  void _collectPatternsFromRule(Rule rule, Set<Pattern> patterns) {
    var body = rule.body();
    _collectPatternsFromPattern(body, patterns);
  }

  /// Recursively collects patterns from a pattern structure
  static int _syntheticRuleCounter = 0;

  void _normalizePredicates() {
    for (int i = 0; i < rules.length; i++) {
      var rule = rules[i];
      rule.setBody(_normalizePattern(rule.body(), <Pattern>{}));
    }
  }

  void _normalizeHigherOrderPatterns() {
    for (int i = 0; i < rules.length; i++) {
      var rule = rules[i];
      rule.setBody(_normalizePattern(rule.body(), <Pattern>{}));
    }
  }

  Pattern _normalizePattern(Pattern pattern, Set<Pattern> seen) {
    if (!seen.add(pattern)) {
      return pattern;
    }

    if (pattern is Rule) {
      return _normalizePattern(pattern.call(), seen);
    }

    if (pattern is RuleCall) {
      var normalizedArguments = _normalizeCallArguments(pattern.arguments, seen);
      if (!identical(normalizedArguments, pattern.arguments)) {
        pattern = RuleCall(
          pattern.name,
          pattern.rule,
          arguments: normalizedArguments,
          minPrecedenceLevel: pattern.minPrecedenceLevel,
        );
      }
      return pattern;
    }

    if (pattern is And) {
      pattern.pattern = _normalizePattern(pattern.pattern, seen);
      var child = pattern.pattern;
      if (child is! RuleCall) {
        var syntheticName = "pred\$${_syntheticRuleCounter++}";
        var syntheticRule = Rule(syntheticName, () => child);
        rules.add(syntheticRule);
        pattern.pattern = syntheticRule.call();
        // No need to recurse again as child was already normalized or is new
      }
      return pattern;
    }

    if (pattern is Not) {
      pattern.pattern = _normalizePattern(pattern.pattern, seen);
      var child = pattern.pattern;
      if (child is! RuleCall) {
        var syntheticName = "pred\$${_syntheticRuleCounter++}";
        var syntheticRule = Rule(syntheticName, () => child);
        rules.add(syntheticRule);
        pattern.pattern = syntheticRule.call();
      }
      return pattern;
    }

    if (pattern is Conj) {
      pattern.left = _normalizePattern(pattern.left, seen);
      var left = pattern.left;
      if (left is! RuleCall) {
        var syntheticName = "conj\$${_syntheticRuleCounter++}";
        var syntheticRule = Rule(syntheticName, () => left);
        rules.add(syntheticRule);
        pattern.left = syntheticRule.call();
      }

      pattern.right = _normalizePattern(pattern.right, seen);
      var right = pattern.right;
      if (right is! RuleCall) {
        var syntheticName = "conj\$${_syntheticRuleCounter++}";
        var syntheticRule = Rule(syntheticName, () => right);
        rules.add(syntheticRule);
        pattern.right = syntheticRule.call();
      }
      return pattern;
    }

    if (pattern is ParameterCallPattern) {
      var normalizedArguments = _normalizeCallArguments(pattern.arguments, seen);
      if (!identical(normalizedArguments, pattern.arguments)) {
        return ParameterCallPattern(
          pattern.name,
          arguments: normalizedArguments,
          minPrecedenceLevel: pattern.minPrecedenceLevel,
        );
      }
      return pattern;
    }

    if (pattern is IfCond) {
      pattern.pattern = _normalizePattern(pattern.pattern, seen);
      var child = pattern.pattern;

      var parameterNames = <String>{};
      _collectParameterNames(child, parameterNames);
      pattern.condition.collectReferredNames(parameterNames);

      var sortedNames = parameterNames.toList()..sort();
      var syntheticName = "if\$${_syntheticRuleCounter++}";
      var syntheticRule = Rule(syntheticName, () => child).guardedBy(pattern.condition);
      rules.add(syntheticRule);

      if (sortedNames.isEmpty) {
        return syntheticRule.call();
      }
      return syntheticRule.call(
        arguments: {for (var name in sortedNames) name: CallArgumentValue.reference(name)},
      );
    }

    // Traditional discovery of children to continue walk
    switch (pattern) {
      case Seq seq:
        seq.left = _normalizePattern(seq.left, seen);
        seq.right = _normalizePattern(seq.right, seen);
      case Alt alt:
        alt.left = _normalizePattern(alt.left, seen);
        alt.right = _normalizePattern(alt.right, seen);
      case Action<Object?> action:
        action.child = _normalizePattern(action.child, seen);
      case Prec plp:
        plp.child = _normalizePattern(plp.child, seen);
      case Opt opt:
        opt.child = _normalizePattern(opt.child, seen);
      case Plus plus:
        plus.child = _normalizePattern(plus.child, seen);
      case Star star:
        star.child = _normalizePattern(star.child, seen);
      case Label label:
        label.child = _normalizePattern(label.child, seen);
      default:
        break;
    }
    return pattern;
  }

  Map<String, CallArgumentValue> _normalizeCallArguments(
    Map<String, CallArgumentValue> arguments,
    Set<Pattern> seen,
  ) {
    var normalized = <String, CallArgumentValue>{};
    var changed = false;
    for (var entry in arguments.entries) {
      var value = _normalizeCallArgumentValue(entry.value, seen);
      normalized[entry.key] = value;
      if (!identical(value, entry.value)) {
        changed = true;
      }
    }
    return changed ? Map<String, CallArgumentValue>.unmodifiable(normalized) : arguments;
  }

  CallArgumentValue _normalizeCallArgumentValue(CallArgumentValue value, Set<Pattern> seen) {
    return value.transformPatterns((pattern) => _normalizeCallablePattern(pattern, seen));
  }

  Pattern _normalizeCallablePattern(Pattern pattern, Set<Pattern> seen) {
    var normalized = _normalizePattern(pattern.copy(), seen);
    if (normalized is Rule || normalized is RuleCall) {
      return normalized;
    }
    if (normalized is Eps || normalized.singleToken()) {
      return normalized;
    }
    return _hoistedPatternRule(normalized, seen);
  }

  Pattern _hoistedPatternRule(Pattern pattern, Set<Pattern> seen) {
    var parameterNames = <String>{};
    _collectParameterNames(pattern, parameterNames);
    var sortedNames = parameterNames.toList()..sort();
    var key = (pattern, sortedNames.join(","));
    var rule = _hoistedPatternRules[key];
    if (rule == null) {
      var syntheticName = "_hoist\$${_hoistedPatternRules.length}";
      var syntheticRule = Rule(syntheticName, () => pattern);
      rules.add(syntheticRule);
      rule = _hoistedPatternRules[key] = syntheticRule;
    }
    if (sortedNames.isEmpty) {
      return rule.call();
    }
    return rule.call(
      arguments: {for (var name in sortedNames) name: CallArgumentValue.reference(name)},
    );
  }

  void _collectParameterNames(Pattern pattern, Set<String> names) {
    switch (pattern) {
      case ParameterRefPattern(:var name):
        names.add(name);
      case ParameterCallPattern(:var name, :var arguments):
        names.add(name);
        for (var argument in arguments.values) {
          _collectParameterNamesFromArgumentValue(argument, names);
        }
      case RuleCall(:var arguments):
        for (var argument in arguments.values) {
          _collectParameterNamesFromArgumentValue(argument, names);
        }
      case Seq(:var left, :var right):
        _collectParameterNames(left, names);
        _collectParameterNames(right, names);
      case Alt(:var left, :var right):
        _collectParameterNames(left, names);
        _collectParameterNames(right, names);
      case Conj(:var left, :var right):
        _collectParameterNames(left, names);
        _collectParameterNames(right, names);
      case And(:var pattern):
        _collectParameterNames(pattern, names);
      case Not(:var pattern):
        _collectParameterNames(pattern, names);
      case Opt(:var child):
        _collectParameterNames(child, names);
      case Plus(:var child):
        _collectParameterNames(child, names);
      case Star(:var child):
        _collectParameterNames(child, names);
      case Label(:var child):
        _collectParameterNames(child, names);
      case Action(:var child):
        _collectParameterNames(child, names);
      case Prec(:var child):
        _collectParameterNames(child, names);
      case IfCond(:var condition, :var pattern):
        condition.collectReferredNames(names);
        _collectParameterNames(pattern, names);
      case Rule():
        break;
      default:
        break;
    }
  }

  void _collectParameterNamesFromArgumentValue(CallArgumentValue value, Set<String> names) {
    value.transformPatterns((pattern) {
      _collectParameterNames(pattern, names);
      return pattern;
    });
  }

  void _collectPatternsFromPattern(Pattern pattern, Set<Pattern> patterns) {
    if (patterns.contains(pattern)) {
      return; // Avoid cycles
    }
    patterns.add(pattern);

    switch (pattern) {
      case Seq seq:
        _collectPatternsFromPattern(seq.left, patterns);
        _collectPatternsFromPattern(seq.right, patterns);
      case Alt alt:
        _collectPatternsFromPattern(alt.left, patterns);
        _collectPatternsFromPattern(alt.right, patterns);
      case Conj conj:
        _collectPatternsFromPattern(conj.left, patterns);
        _collectPatternsFromPattern(conj.right, patterns);
      case And and:
        _collectPatternsFromPattern(and.pattern, patterns);
      case Not not:
        _collectPatternsFromPattern(not.pattern, patterns);
      case Action<Object?> action:
        _collectPatternsFromPattern(action.child, patterns);
      case Prec plp:
        _collectPatternsFromPattern(plp.child, patterns);
      case Opt opt:
        _collectPatternsFromPattern(opt.child, patterns);
      case Plus plus:
        _collectPatternsFromPattern(plus.child, patterns);
      case Star star:
        _collectPatternsFromPattern(star.child, patterns);
      case Label label:
        _collectPatternsFromPattern(label.child, patterns);
      case IfCond ifCond:
        _collectPatternsFromPattern(ifCond.pattern, patterns);
      case Token() ||
          Marker() ||
          StartAnchor() ||
          EofAnchor() ||
          Eps() ||
          ParameterRefPattern() ||
          ParameterCallPattern() ||
          Rule() ||
          RuleCall() ||
          LabelStart() ||
          LabelEnd() ||
          Backreference():
        break;
    }
  }

  Iterable<Pattern> get allPatterns sync* {
    for (Rule rule in rules) {
      Set<Pattern> patterns = {rule};
      _collectPatternsFromRule(rule, patterns);
      yield* patterns;
    }
  }

  StateMachine get stateMachine {
    _stateMachine ??= StateMachine(this);
    return _stateMachine!;
  }

  @override
  bool isEmpty() => startCall.rule.body().empty();

  void _computeEmpty() {
    var emptyRules = <Rule>{};

    bool changed;
    do {
      var sizeBefore = emptyRules.length;

      // Only process rules that are in the explicit rules list
      for (var rule in rules) {
        try {
          if (rule.calculateEmpty(emptyRules)) {
            emptyRules.add(rule);
          }
        } on Exception {
          // Skip rules that can't be computed yet
        }
      }

      changed = emptyRules.length != sizeBefore;
    } while (changed);
  }

  void _computeTransitions() {
    transitions = {};

    for (var rule in rules) {
      for (var (a, b) in rule.body().eachPair()) {
        transitions![a] ??= [];
        transitions![a]!.add(b);
      }

      for (var lastState in rule.body().lastSet()) {
        transitions![lastState] ??= [];
        transitions![lastState]!.add(rule);
      }

      // Static rules (consisting only of markers/predicates) are allowed even if
      // they don't return true for empty(), as they are handled by the state machine
      // without consuming input.
      if (!rule.body().empty() && rule.body().isStatic()) {
        // This used to throw, but we allow it now to support nested predicates
        // and markers in rules.
      }
    }

    // Use a marker Pattern for the success node
    var successMarker = Marker("__start__");
    transitions![startCall] ??= [];
    transitions![startCall]!.add(successMarker);
  }
}

class ShellGrammar implements GrammarInterface {
  ShellGrammar({
    required this.startSymbol,
    required this.childrenRegistry,
    required this.rules,
    required this.startCall,
  }) {
    for (var rule in rules) {
      allRules[rule.symbolId!] = rule;
    }
  }

  @override
  final Map<PatternSymbol, Pattern> registry = {};

  @override
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;

  @override
  final Map<PatternSymbol, Rule> allRules = {};

  @override
  final PatternSymbol startSymbol;

  @override
  final List<Rule> rules;

  @override
  final RuleCall startCall;

  @override
  bool isEmpty() => false; // Default for imported
}
