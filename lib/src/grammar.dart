/// Grammar definition and building
library glush.grammar;

import 'patterns.dart';
import 'state_machine.dart' as sm;
import 'errors.dart';

typedef GrammarBuilder = Pattern Function();

class Grammar with _GrammarMixin implements sm.GrammarInterface {
  final List<Rule> rules = [];
  late final RuleCall startCall;
  Map<Pattern, List<Pattern>>? transitions;
  sm.StateMachine? _stateMachine;

  /// Maps symbol IDs back to patterns for this grammar
  @override
  final Map<String, Pattern> symbolRegistry = {};

  /// Counter for assigning symbol IDs within this grammar
  int _symbolCounter = 0;

  Grammar(GrammarBuilder builder) {
    try {
      final result = builder();
      if (result is RuleCall) {
        finalize(result);
      } else if (result is Call) {
        // Convert Call to RuleCall for grammar entry point
        finalize(result.rule.call());
      } else if (result is Rule) {
        // Convert Rule to RuleCall for grammar entry point
        finalize(result.call());
      } else {
        throw TypeError();
      }
    } catch (e) {
      if (e is TypeError) {
        throw GrammarError('the main pattern must be a rule call');
      }
      rethrow;
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
        pattern.assignSymbolId(symbolId);
        symbolRegistry[symbolId] = pattern;
      }
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
      case Plus plus:
        _collectPatternsFromPattern(plus.child, patterns);
      case Star star:
        _collectPatternsFromPattern(star.child, patterns);
      case And and:
        _collectPatternsFromPattern(and.pattern, patterns);
      case Not not:
        _collectPatternsFromPattern(not.pattern, patterns);
      case Action action:
        _collectPatternsFromPattern(action.child, patterns);
      case PrecedenceLabeledPattern plp:
        _collectPatternsFromPattern(plp.pattern, patterns);
      default:
        // Token, Marker, Eps, Rule, RuleCall, Call - these are terminals
        break;
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

  Pattern inv(Pattern pattern) => pattern.invert();

  Eps eps() => Eps();

  Marker mark(String name) => Marker(name);

  Alt sepBy(Pattern p, Pattern sep) => sepBy1(p, sep).maybe();

  Seq sepBy1(Pattern p, Pattern sep) => p >> (sep >> p).star();

  Alt endBy(Pattern p, Pattern sep) => endBy1(p, sep).maybe();

  Plus endBy1(Pattern p, Pattern sep) => (p >> sep).plus();

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
