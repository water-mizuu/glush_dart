/// Grammar definition and building
library glush.grammar;

import 'package:glush/src/state_machine.dart';

import 'patterns.dart';
import 'state_machine.dart' as sm;
import 'errors.dart';

typedef GrammarBuilder = Rule Function();

// Grammar interface to avoid circular import
sealed class GrammarInterface {
  /// Maps symbol IDs back to patterns for this grammar
  Map<PatternSymbol, Pattern> get symbolRegistry;
  Map<PatternSymbol, Set<PatternSymbol>> get childrenRegistry;

  RuleCall get startCall;
  List<Rule> get rules;
  bool isEmpty();
}

class Grammar with _GrammarMixin implements GrammarInterface {
  final List<Rule> rules = [];
  late final RuleCall startCall;
  Map<Pattern, List<Pattern>>? transitions;
  sm.StateMachine? _stateMachine;

  /// Maps symbol IDs back to patterns for this grammar
  @override
  final Map<PatternSymbol, Pattern> symbolRegistry = {};
  final Map<PatternSymbol, Set<PatternSymbol>> childrenRegistry = {};

  /// Counter for assigning symbol IDs within this grammar
  int _symbolCounter = 0;

  Grammar(GrammarBuilder builder) {
    try {
      final result = builder();
      finalize(result.call());
    } on TypeError {
      throw GrammarError('the main pattern must be a rule call');
    }
  }

  void finalize(RuleCall start) {
    startCall = start.consume() as RuleCall;

    // Discover all rules referenced from the start call
    final discoveredRules = <Rule>{startCall.rule};
    final toProcess = <Rule>{startCall.rule};

    // Recursively discover rules by examining their bodies
    while (toProcess.isNotEmpty) {
      final rule = toProcess.first;
      toProcess.remove(rule);

      // Now safe to call body() since rule is registered
      final body = rule.body();
      final referencedRules = <Rule>{};
      body.collectRules(referencedRules);

      for (final ref in referencedRules) {
        if (!discoveredRules.contains(ref)) {
          discoveredRules.add(ref);
          toProcess.add(ref);
        }
      }
    }

    rules.addAll(discoveredRules);

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
      childrenRegistry[pattern.symbolId!] = switch (pattern) {
        And() || Not() || Token() || Marker() || Eps() => {},

        Alt(:var left, :var right) ||
        Seq(:var left, :var right) ||
        Conj(:var left, :var right) => {left.symbolId!, right.symbolId!},

        Plus(:var child) ||
        Star(:var child) ||
        Action(:var child) ||
        PrecedenceLabeledPattern(:var child) => {child.symbolId!},

        Rule rule => {rule.body().symbolId!},
        RuleCall(:var rule) || Call(:var rule) => {rule.symbolId!},
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
      case PrecedenceLabeledPattern plp:
        _collectPatternsFromPattern(plp.child, patterns);
      case Plus plus:
        _collectPatternsFromPattern(plus.child, patterns);
      case Star star:
        _collectPatternsFromPattern(star.child, patterns);
      case Token() || Marker() || Eps() || Rule() || RuleCall() || Call():
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

      for (final lst in rule.body().lastSet()) {
        transitions![lst] ??= [];
        transitions![lst]!.add(rule);
      }

      if (!rule.body().empty() && rule.body().isStatic()) {
        throw GrammarError('rule $rule contains markers in empty position');
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
  final List<Rule> rules;

  @override
  final RuleCall startCall;

  @override
  final Map<PatternSymbol, Pattern> symbolRegistry = {};

  @override
  final Map<PatternSymbol, Set<PatternSymbol>> childrenRegistry = {};

  GrammarAdapter(StateMachine sm)
    : rules = sm.rules,
      startCall = sm.rules.isNotEmpty ? sm.rules[0].call() : Rule('_dummy', () => Eps()).call();

  GrammarAdapter.withRules(this.rules, this.startCall);

  @override
  bool isEmpty() => rules.isEmpty;
}
