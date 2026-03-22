/// Grammar definition and building
library glush.grammar;

import 'dart:collection';

import 'patterns.dart';
import 'state_machine.dart' as sm;
import 'errors.dart';

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

class Grammar with _GrammarMixin implements GrammarInterface {
  final List<Rule> rules = [];
  late final RuleCall startCall;
  Map<Pattern, List<Pattern>>? transitions;
  sm.StateMachine? _stateMachine;

  @override
  final Map<PatternSymbol, Pattern> symbolRegistry = {};
  @override
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry = {};

  @override
  PatternSymbol get startSymbol => startCall.rule.symbolId!;

  /// Counter for assigning symbol IDs within this grammar
  int _symbolCounter = 0;

  Grammar(GrammarBuilder builder) {
    final result = builder();
    finalize(result.call());
  }

  void finalize(RuleCall start) {
    startCall = start.consume() as RuleCall;

    // Discover all rules referenced from the start call
    final discoveredRules = <Rule>{startCall.rule};
    final toProcess = Queue.of([startCall.rule]);

    // Recursively discover rules by examining their bodies
    while (toProcess.isNotEmpty) {
      final rule = toProcess.removeFirst();

      // Now safe to call body() since rule is registered
      final body = rule.body();
      final referencedRules = <Rule>{};
      body.collectRules(referencedRules);

      for (final ref in referencedRules) {
        if (!discoveredRules.contains(ref)) {
          discoveredRules.add(ref);
          toProcess.addLast(ref);
        }
      }
    }

    rules.addAll(discoveredRules);
    _normalizePredicates();

    // Discover and assign symbol IDs to all patterns used in this grammar
    _assignPatternSymbols();
    _fillChildrenMapping();

    _computeEmpty();
    _computeTransitions();
  }

  /// Discovers all patterns in the grammar and assigns them symbol IDs
  void _assignPatternSymbols() {
    final allPatterns = <Pattern>{};

    // Collect all patterns from the grammar's rules, including the rules themselves
    for (final rule in rules) {
      allPatterns.add(rule); // Add the rule itself
      _collectPatternsFromRule(rule, allPatterns);
    }

    // Assign symbol IDs to each pattern in discovery order
    for (final pattern in allPatterns) {
      if (pattern.symbolId == null) {
        final symbolId = 'S${_symbolCounter++}';
        pattern.assignSymbolId(PatternSymbol(symbolId));
      }
      final actualSymbolId = pattern.symbolId!;
      symbolRegistry[actualSymbolId] = pattern;
    }
  }

  void _fillChildrenMapping() {
    for (final pattern in allPatterns) {
      // print(pattern.symbolId!);
      childrenRegistry[pattern.symbolId!] = switch (pattern) {
        Token() || Marker() || Eps() => [],

        Alt(:var left, :var right) ||
        Seq(:var left, :var right) ||
        Conj(:var left, :var right) => [left.symbolId!, right.symbolId!],

        Action(:var child) || Prec(:var child) => [child.symbolId!],

        Rule rule => [rule.body().symbolId!],
        RuleCall(:var rule) => [rule.symbolId!],

        And(:var pattern) || Not(:var pattern) => [pattern.symbolId!],
      };
    }
  }

  /// Recursively collects all patterns used in a rule's body
  void _collectPatternsFromRule(Rule rule, Set<Pattern> patterns) {
    final body = rule.body();
    _collectPatternsFromPattern(body, patterns);
  }

  /// Recursively collects patterns from a pattern structure
  static int _syntheticRuleCounter = 0;

  void _normalizePredicates() {
    for (int i = 0; i < rules.length; i++) {
      _normalizePattern(rules[i].body());
    }
  }

  void _normalizePattern(Pattern pattern) {
    // We use a set to avoid infinite recursion in graph
    final seen = <Pattern>{};
    final queue = <Pattern>[pattern];

    while (queue.isNotEmpty) {
      final patternNode = queue.removeAt(0);
      if (seen.contains(patternNode)) continue;
      seen.add(patternNode);

      if (patternNode is And || patternNode is Not) {
        final dynamic pred = patternNode;
        final child = pred.pattern;
        if (child is! RuleCall) {
          final syntheticName = 'pred\$${_syntheticRuleCounter++}';
          final syntheticRule = Rule(syntheticName, () => child);
          rules.add(syntheticRule);
          pred.pattern = syntheticRule.call();
          // The new RuleCall will be seen in the next iteration or via recursive discovery
          queue.add(pred.pattern);
        }
      }

      // Traditional discovery of children to continue walk
      switch (patternNode) {
        case Seq seq:
          queue.add(seq.left);
          queue.add(seq.right);
        case Alt alt:
          queue.add(alt.left);
          queue.add(alt.right);
        case Conj conj:
          queue.add(conj.left);
          queue.add(conj.right);
        case And and:
          queue.add(and.pattern);
        case Not not:
          queue.add(not.pattern);
        case Action action:
          queue.add(action.child);
        case Prec plp:
          queue.add(plp.child);
        default:
          break;
      }
    }
  }

  void _collectPatternsFromPattern(Pattern pattern, Set<Pattern> patterns) {
    if (patterns.contains(pattern)) return; // Avoid cycles
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
      case Action action:
        _collectPatternsFromPattern(action.child, patterns);
      case Prec plp:
        _collectPatternsFromPattern(plp.child, patterns);
      case Token() || Marker() || Eps() || Rule() || RuleCall():
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

  sm.StateMachine get stateMachine {
    _stateMachine ??= sm.StateMachine(this);
    return _stateMachine!;
  }

  @override
  bool isEmpty() => startCall.rule.body().empty();

  // DSL methods
  Token anytoken() => Token(const AnyToken());

  Token token(int codepoint) => Token(ExactToken(codepoint));

  Token tokenRange(int start, int end) {
    if (start < 0 || end < 0) {
      throw GrammarError('only positive code points supported in range');
    }
    return Token(RangeToken(start, end));
  }

  Pattern str(String text) {
    final codepoints = text.codeUnits;
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
      throw GrammarError('only positive code points supported in range');
    }
    return Token(RangeToken(range.start, range.end));
  }

  Eps eps() => Eps();

  Rule defRule(String name, Pattern Function() builder) {
    final rule = Rule(name, builder);
    rules.add(rule);
    return rule;
  }

  void _computeEmpty() {
    final emptyRules = <Rule>{};

    bool changed;
    do {
      final sizeBefore = emptyRules.length;

      // Only process rules that are in the explicit rules list
      for (final rule in rules) {
        try {
          if (rule.calculateEmpty(emptyRules)) {
            emptyRules.add(rule);
          }
        } catch (e) {
          // Skip rules that can't be computed yet
        }
      }

      changed = emptyRules.length != sizeBefore;
    } while (changed);
  }

  void _computeTransitions() {
    transitions = {};

    for (final rule in rules) {
      rule.body().eachPair((a, b) {
        transitions![a] ??= [];
        transitions![a]!.add(b);
      });

      for (final lastState in rule.body().lastSet()) {
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
    final successMarker = Marker('__start__');
    transitions![startCall] ??= [];
    transitions![startCall]!.add(successMarker);
  }
}

/// Mixin for Grammar interface
mixin _GrammarMixin {
  RuleCall get startCall;
  List<Rule> get rules;
  bool isEmpty();
}

// Extension for Range syntax
extension IntRangeExtension on int {
  IntRange operator *(int other) => IntRange(this, other);
}

class IntRange {
  final int start;
  final int end;

  IntRange(this.start, this.end);
}

class GrammarAdapter implements GrammarInterface {
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

  GrammarAdapter(sm.StateMachine sm) : rules = sm.grammar.rules, startCall = sm.grammar.startCall {
    symbolRegistry.addAll(sm.grammar.symbolRegistry);
    childrenRegistry.addAll(sm.grammar.childrenRegistry);
  }

  @override
  PatternSymbol get startSymbol => startCall.rule.symbolId!;

  GrammarAdapter.withRules(this.rules, this.startCall) {
    _assignPatternSymbols();
    _fillChildrenMapping();
  }

  /// Discovers all patterns in the grammar and assigns them symbol IDs
  void _assignPatternSymbols() {
    final allPatterns = <Pattern>{};

    // Collect all patterns from the grammar's rules, including the rules themselves
    for (final rule in rules) {
      allPatterns.add(rule); // Add the rule itself
      _collectPatternsFromRule(rule, allPatterns);
    }

    // Assign symbol IDs to each pattern in discovery order
    for (final pattern in allPatterns) {
      if (pattern.symbolId == null) {
        final symbolId = 'S${_symbolCounter++}';
        pattern.assignSymbolId(PatternSymbol(symbolId));
      }
      final actualSymbolId = pattern.symbolId!;
      symbolRegistry[actualSymbolId] = pattern;
    }
  }

  void _fillChildrenMapping() {
    for (final pattern in allPatterns) {
      // print(pattern.symbolId!);
      childrenRegistry[pattern.symbolId!] = switch (pattern) {
        Token() || Marker() || Eps() => [],

        Alt(:var left, :var right) ||
        Seq(:var left, :var right) ||
        Conj(:var left, :var right) => [left.symbolId!, right.symbolId!],

        Action(:var child) || Prec(:var child) => [child.symbolId!],

        Rule rule => [rule.body().symbolId!],
        RuleCall(:var rule) => [rule.symbolId!],

        And(:var pattern) || Not(:var pattern) => [pattern.symbolId!],
      };
    }
  }

  /// Recursively collects all patterns used in a rule's body
  void _collectPatternsFromRule(Rule rule, Set<Pattern> patterns) {
    final body = rule.body();
    _collectPatternsFromPattern(body, patterns);
  }

  /// Recursively collects patterns from a pattern structure
  void _collectPatternsFromPattern(Pattern pattern, Set<Pattern> patterns) {
    if (patterns.contains(pattern)) return; // Avoid cycles
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
      case Action action:
        _collectPatternsFromPattern(action.child, patterns);
      case Prec plp:
        _collectPatternsFromPattern(plp.child, patterns);
      case Token() || Marker() || Eps() || Rule() || RuleCall():
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

  ShellGrammar({
    required this.startSymbol,
    required this.childrenRegistry,
    required this.rules,
    required this.startCall,
  });

  @override
  bool isEmpty() => false; // Default for imported
}
