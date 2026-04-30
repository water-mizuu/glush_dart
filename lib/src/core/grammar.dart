/// Grammar definition and building
library glush.grammar;

import "dart:collection";

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A function signature for building a grammar.
///
/// This builder is typically used to define the entry point rule of a grammar,
/// which in turn triggers the recursive discovery and compilation of all
/// referenced rules and patterns.
typedef GrammarBuilder = Rule Function();

/// A specialized interface for accessing grammar components without requiring
/// the full [Grammar] implementation.
///
/// This interface is crucial for breaking circular dependencies between the
/// grammar definition and the patterns or state machines that operate on it.
/// It provides read-only access to the pattern registry, rules, and symbols.
sealed class GrammarInterface {
  /// A registry mapping unique [PatternSymbol] IDs back to their [Pattern] instances.
  ///
  /// This mapping is used by the parser and evaluator to resolve numeric IDs
  /// into concrete logic during execution.
  Map<PatternSymbol, Pattern> get registry;

  /// The entry point call for the grammar.
  ///
  /// This represents the starting point of any parse attempt using this grammar.
  RuleCall get startCall;

  /// The unique symbol ID representing the start rule.
  PatternSymbol get startSymbol;

  /// The list of all rules defined within this grammar.
  List<Rule> get rules;

  /// A map for fast lookup of [Rule] instances by their symbol ID.
  Map<PatternSymbol, Rule> get allRules;

  /// Indicates whether the grammar is fundamentally empty (i.e., matches the empty string).
  bool isEmpty();
}

/// The primary representation of a formal grammar in Glush.
///
/// The [Grammar] class is responsible for compiling a human-readable grammar
/// definition (provided via a [GrammarBuilder]) into a structured, optimized
/// form suitable for parsing. This involves discovering all reachable rules,
/// normalizing complex patterns (like predicates and rule calls),
/// assigning unique symbol IDs, and computing the state transitions required
/// by the Glush parsing algorithm.
class Grammar implements GrammarInterface {
  /// Constructs a [Grammar] by executing the provided [builder].
  ///
  /// The builder returns the starting [Rule], which is then used as the root
  /// for a recursive discovery process. The grammar is immediately finalized
  /// upon construction.
  Grammar(GrammarBuilder builder) {
    var result = builder();
    finalize(result.call());
  }

  /// The list of all rules discovered in this grammar.
  @override
  final List<Rule> rules = [];

  /// The entry point call that initiates parsing.
  @override
  late final RuleCall startCall;

  /// A mapping of transitions between patterns, used during state machine generation.
  Map<Pattern, List<Pattern>>? transitions;

  /// The compiled state machine for this grammar.
  StateMachine? _stateMachine;

  /// The registry for mapping symbol IDs to patterns.
  @override
  final Map<PatternSymbol, Pattern> registry = {};

  /// Fast lookup map for rules by their symbol ID.
  @override
  final Map<PatternSymbol, Rule> allRules = {};

  /// Returns the symbol ID of the start rule.
  @override
  PatternSymbol get startSymbol => startCall.rule.symbolId!;

  /// Completes the compilation of the grammar starting from the [start] call.
  ///
  /// This method orchestrates the entire compilation pipeline:
  /// 1. **Rule Discovery**: Recursively finds all rules reachable from the start.
  /// 2. **Normalization**: Rewrites predicates and complex patterns into a standard form.
  /// 3. **Symbol Assignment**: Assigns unique numeric IDs to every pattern.
  /// 4. **Static Analysis**: Computes empty-status and state transitions.
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
    _normalizePatterns();

    // Discover and assign symbol IDs to all patterns used in this grammar
    _assignPatternSymbols();

    _computeEmpty();
    _computeTransitions();
  }

  /// Discovers all patterns in the grammar and assigns them symbol IDs
  /// Traverses the entire grammar to assign a unique numeric symbol ID to every pattern.
  ///
  /// These IDs are used to optimize internal operations, such as state transitions
  /// and bitset representations of pattern sets. The registry is populated
  /// simultaneously to allow reverse lookup of patterns from their IDs.
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

  /// Helper to collect all patterns from a specific rule.
  void _collectPatternsFromRule(Rule rule, Set<Pattern> patterns) {
    var body = rule.body();
    _collectPatternsFromPattern(body, patterns);
  }

  /// Recursively collects patterns from a pattern structure
  /// A counter for generating unique names for synthetic rules created during normalization.
  static int _syntheticRuleCounter = 0;

  /// Normalizes rule bodies by hoisting predicate subpatterns into synthetic
  /// rules where needed.
  ///
  /// The loop intentionally uses an index against [rules] so synthetic
  /// rules appended during normalization are processed in the same pass.
  void _normalizePatterns() {
    var cache = <Pattern, Pattern>{};
    for (int i = 0; i < rules.length; i++) {
      var rule = rules[i];
      rule.setBody(_normalizePattern(rule.body(), cache));
    }
  }

  /// Ensures [pattern] is anchored by a rule call, hoisting it when needed.
  Pattern _ensureRuleCallPattern(Pattern pattern, String syntheticPrefix) {
    if (pattern is RuleCall) {
      return pattern;
    }
    var syntheticName = "$syntheticPrefix\$${_syntheticRuleCounter++}";
    var syntheticRule = Rule(syntheticName, () => pattern);
    rules.add(syntheticRule);
    return syntheticRule.call();
  }

  /// Recursively normalizes a pattern and its children.
  ///
  /// This is the core logic for hoisting anonymous patterns into synthetic rules.
  /// It specifically targets patterns that require rule-level anchoring for
  /// correct forest construction, such as patterns used in predicates.
  Pattern _normalizePattern(Pattern pattern, Map<Pattern, Pattern> cache) {
    if (cache.containsKey(pattern)) {
      return cache[pattern]!;
    }

    if (pattern is Rule) {
      return _normalizePattern(pattern.call(), cache);
    }

    if (pattern is RuleCall) {
      var result = RuleCall(
        pattern.name,
        pattern.rule,
        minPrecedenceLevel: pattern.minPrecedenceLevel,
      );
      cache[pattern] = result;
      return result;
    }

    if (pattern is And) {
      var inner = _normalizePattern(pattern.pattern, cache);
      inner = _ensureRuleCallPattern(inner, "pred");
      var result = (inner == pattern.pattern) ? pattern : And(inner);
      cache[pattern] = result;
      return result;
    }

    if (pattern is Not) {
      var inner = _normalizePattern(pattern.pattern, cache);
      inner = _ensureRuleCallPattern(inner, "pred");
      var result = (inner == pattern.pattern) ? pattern : Not(inner);
      cache[pattern] = result;
      return result;
    }

    // Traditional discovery of children to continue walk
    Pattern result;
    if (pattern is Seq) {
      var left = _normalizePattern(pattern.left, cache);
      var right = _normalizePattern(pattern.right, cache);
      result = (left == pattern.left && right == pattern.right) ? pattern : Seq(left, right);
    } else if (pattern is Alt) {
      var left = _normalizePattern(pattern.left, cache);
      var right = _normalizePattern(pattern.right, cache);
      result = (left == pattern.left && right == pattern.right) ? pattern : Alt(left, right);
    } else if (pattern is Prec) {
      var child = _normalizePattern(pattern.child, cache);
      result = (child == pattern.child) ? pattern : Prec(pattern.precedenceLevel, child);
    } else if (pattern is Opt) {
      var child = _normalizePattern(pattern.child, cache);
      result = (child == pattern.child) ? pattern : Opt(child);
    } else if (pattern is Plus) {
      var child = _normalizePattern(pattern.child, cache);
      result = (child == pattern.child) ? pattern : Plus(child);
    } else if (pattern is Star) {
      var child = _normalizePattern(pattern.child, cache);
      result = (child == pattern.child) ? pattern : Star(child);
    } else if (pattern is Label) {
      var child = _normalizePattern(pattern.child, cache);
      result = (child == pattern.child) ? pattern : Label(pattern.name, child);
    } else {
      result = pattern;
    }

    cache[pattern] = result;
    return result;
  }

  /// Recursively discovers all patterns within a given pattern structure.
  ///
  /// This method is used during the symbol assignment phase to ensure that
  /// every nested pattern is identified and assigned a unique ID.
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
      case And and:
        _collectPatternsFromPattern(and.pattern, patterns);
      case Not not:
        _collectPatternsFromPattern(not.pattern, patterns);
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
          StartAnchor() ||
          EofAnchor() ||
          Eps() ||
          Rule() ||
          RuleCall() ||
          LabelStart() ||
          LabelEnd() ||
          Retreat():
        break;
    }
  }

  /// An iterable yielding every pattern instance used in the grammar.
  Iterable<Pattern> get allPatterns sync* {
    for (Rule rule in rules) {
      Set<Pattern> patterns = {rule};
      _collectPatternsFromRule(rule, patterns);
      yield* patterns;
    }
  }

  /// Gets the [StateMachine] compiled for this grammar.
  ///
  /// The state machine is lazily instantiated and cached, as its construction
  /// can be computationally intensive for large grammars.
  StateMachine get stateMachine {
    _stateMachine ??= StateMachine(this);
    return _stateMachine!;
  }

  /// Checks if the grammar's start rule can match an empty string.
  @override
  bool isEmpty() => startCall.rule.body().empty();

  /// Iteratively computes the empty-status for every rule in the grammar.
  ///
  /// A rule is considered empty if there exists a path through its pattern
  /// structure that consumes zero tokens. This computation is performed
  /// using a fixed-point iteration to correctly handle recursive rules.
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

  /// Computes the set of valid transitions between patterns in the grammar.
  ///
  /// This analysis determines which patterns can follow each other, including
  /// transitions across rule boundaries. It forms the foundation of the
  /// state machine's transition table and the parser's lookahead logic.
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
    }

    // // Use a marker Pattern for the success node
    // var successMarker = Marker("__start__");
    // transitions![startCall] ??= [];
    // transitions![startCall]!.add(successMarker);
  }
}

/// A lightweight "shell" implementation of [GrammarInterface].
///
/// This class is used to represent a grammar that has been partially loaded or
/// imported, providing just enough information for basic structure navigation
/// without the overhead of full compilation or state machine generation.
class ShellGrammar implements GrammarInterface {
  /// Constructs a [ShellGrammar] with the required structural components.
  ShellGrammar({required this.startSymbol, required this.rules, required this.startCall}) {
    for (var rule in rules) {
      allRules[rule.symbolId!] = rule;
    }
  }

  /// The pattern registry (often empty in a shell grammar).
  @override
  final Map<PatternSymbol, Pattern> registry = {};

  /// Fast lookup map for rules.
  @override
  final Map<PatternSymbol, Rule> allRules = {};

  /// The entry point symbol.
  @override
  final PatternSymbol startSymbol;

  /// The list of rules.
  @override
  final List<Rule> rules;

  /// The entry point call.
  @override
  final RuleCall startCall;

  /// Shell grammars are typically considered non-empty by default.
  @override
  bool isEmpty() => false; // Default for imported
}
