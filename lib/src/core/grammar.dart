/// Grammar definition and building
library glush.grammar;

import "dart:collection";

import "package:glush/src/core/errors.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/state_machine.dart";

typedef GrammarBuilder = Rule Function();

// Grammar interface to avoid circular import
sealed class GrammarInterface {
  /// Maps symbol IDs back to patterns for this grammar
  Map<PatternSymbol, Pattern> get symbolRegistry;
  Map<PatternSymbol, List<PatternSymbol>> get childrenRegistry;

  RuleCall get startCall;
  PatternSymbol get startSymbol;
  List<Rule> get rules;
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
  final Map<PatternSymbol, Pattern> symbolRegistry = {};

  @override
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry = {};

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
      if (pattern.symbolId == null) {
        var symbolId = "S${symbolCounter++}";
        pattern.symbolId = PatternSymbol(symbolId);
      }
      var actualSymbolId = pattern.symbolId!;
      symbolRegistry[actualSymbolId] = pattern;
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
        Neg(:var pattern) => [pattern.symbolId!],
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

    if (pattern is Neg) {
      pattern.pattern = _normalizePattern(pattern.pattern, seen);
      var child = pattern.pattern;
      if (child is! RuleCall) {
        var syntheticName = "neg\$${_syntheticRuleCounter++}";
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

    // Traditional discovery of children to continue walk
    switch (pattern) {
      case Seq seq:
        seq.left = _normalizePattern(seq.left, seen);
        seq.right = _normalizePattern(seq.right, seen);
      case Alt alt:
        alt.left = _normalizePattern(alt.left, seen);
        alt.right = _normalizePattern(alt.right, seen);
      case Action<dynamic> action:
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
      case Neg(:var pattern):
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
      case Neg neg:
        _collectPatternsFromPattern(neg.pattern, patterns);
      case Action<dynamic> action:
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

  // DSL methods
  Token anytoken() => Token(const AnyToken());

  Token token(int codepoint) => Token(ExactToken(codepoint));

  Token tokenRange(int start, int end) {
    if (start < 0 || end < 0) {
      throw GrammarError("only positive code points supported in range");
    }
    return Token(RangeToken(start, end));
  }

  Pattern str(String text) {
    var codepoints = text.codeUnits;
    Pattern result = token(codepoints[0]);
    for (int i = 1; i < codepoints.length; i++) {
      result = result >> token(codepoints[i]);
    }
    return result;
  }

  /// Convenience method for creating a keyword pattern with semantic action.
  /// Transforms the string into a sequence of tokens and wraps with the callback.
  ///
  /// Example:
  /// ```dart
  /// final ifKeyword = grammar.keyword<TokenType>('if', (span, _) => TokenType.IF);
  /// ```
  Action<T> keyword<T>(String text, T Function(String span, List<dynamic> _) action) {
    return str(text).withAction<T>(action);
  }

  /// Convenience method for creating a string pattern that captures the matched text.
  /// Transforms the string into a sequence of tokens and wraps with a capture action.
  ///
  /// Example:
  /// ```dart
  /// final identifier = grammar.literal('hello');
  /// ```
  Action<String> literal(String text) {
    return str(text).withAction<String>((span, _) => span);
  }

  Pattern strRange(IntRange range) {
    if (range.start < 0 || range.end < 0) {
      throw GrammarError("only positive code points supported in range");
    }
    return Token(RangeToken(range.start, range.end));
  }

  Eps eps() => Eps();

  Pattern start() => StartAnchor();

  Pattern eof() => EofAnchor();

  Rule defRule(String name, Pattern Function() builder) {
    var rule = Rule(name, builder);
    rules.add(rule);
    return rule;
  }

  Label label(String name, Pattern child) => Label(name, child);

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

// Extension for Range syntax
extension IntRangeExtension on int {
  IntRange operator *(int other) => IntRange(this, other);
}

class IntRange {
  IntRange(this.start, this.end);
  final int start;
  final int end;
}

class GrammarAdapter implements GrammarInterface {
  GrammarAdapter(StateMachine sm) : rules = sm.grammar.rules, startCall = sm.grammar.startCall {
    symbolRegistry.addAll(sm.grammar.symbolRegistry);
    childrenRegistry.addAll(sm.grammar.childrenRegistry);
  }

  GrammarAdapter.withRules(this.rules, this.startCall) {
    _assignPatternSymbols();
    _fillChildrenMapping();
  }
  @override
  final Map<PatternSymbol, Pattern> symbolRegistry = {};

  @override
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry = {};

  @override
  final List<Rule> rules;

  @override
  final RuleCall startCall;

  /// Counter for assigning symbol IDs within this grammar
  int _symbolCounter = 0;

  @override
  PatternSymbol get startSymbol => startCall.rule.symbolId!;

  /// Discovers all patterns in the grammar and assigns them symbol IDs
  void _assignPatternSymbols() {
    var allPatterns = <Pattern>{};

    // Collect all patterns from the grammar's rules, including the rules themselves
    for (var rule in rules) {
      allPatterns.add(rule); // Add the rule itself
      _collectPatternsFromRule(rule, allPatterns);
    }

    // Assign symbol IDs to each pattern in discovery order
    for (var pattern in allPatterns) {
      if (pattern.symbolId == null) {
        var symbolId = "S${_symbolCounter++}";
        pattern.symbolId = PatternSymbol(symbolId);
      }
      var actualSymbolId = pattern.symbolId!;
      symbolRegistry[actualSymbolId] = pattern;
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
        //
        Alt(:var left, :var right) ||
        Seq(:var left, :var right) ||
        Conj(:var left, :var right) => [left.symbolId!, right.symbolId!],
        //
        Neg(:var pattern) => [pattern.symbolId!],
        Label(:var child) ||
        Action(:var child) ||
        Prec(:var child) ||
        Opt(:var child) ||
        Plus(:var child) ||
        Star(:var child) => [child.symbolId!],
        //
        Rule rule => [rule.body().symbolId!],
        RuleCall(:var rule) => [rule.symbolId!],
        And(:var pattern) || Not(:var pattern) => [pattern.symbolId!],
      };
    }
  }

  /// Recursively collects all patterns used in a rule's body
  void _collectPatternsFromRule(Rule rule, Set<Pattern> patterns) {
    var body = rule.body();

    _collectPatternsFromPattern(body, patterns);
  }

  /// Recursively collects patterns from a pattern structure
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
      case Neg neg:
        _collectPatternsFromPattern(neg.pattern, patterns);
      case Action<dynamic> action:
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

  @override
  bool isEmpty() => rules.isEmpty;
}

class ShellGrammar implements GrammarInterface {
  ShellGrammar({
    required this.startSymbol,
    required this.childrenRegistry,
    required this.rules,
    required this.startCall,
  });

  @override
  final Map<PatternSymbol, Pattern> symbolRegistry = {};

  @override
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;

  @override
  final PatternSymbol startSymbol;

  @override
  final List<Rule> rules;

  @override
  final RuleCall startCall;

  @override
  bool isEmpty() => false; // Default for imported
}
