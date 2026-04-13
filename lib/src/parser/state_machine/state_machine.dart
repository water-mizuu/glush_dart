/// State machine compilation from grammars
library glush.state_machine;

import "dart:convert";

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/key/state_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:meta/meta.dart";

/// State in the state machine.
///
/// Each state contains a list of actions (transitions) that can be taken from it.
@immutable
class State {
  const State(this.id, this.actions);

  final int id;
  final List<StateAction> actions;

  @override
  String toString() => "State($id)";

  @override
  bool operator ==(Object other) => other is State && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A compiled state machine that represents a PEG grammar as a finite state automaton.
///
/// This state machine is built using Glushkov construction, which converts each grammar rule
/// into a deterministic pushdown automaton. The automaton uses:
/// - **States** to represent positions in parsing
/// - **Actions** to represent transitions (consuming tokens, calling rules, managing the stack)
/// - **Tail call optimization** for efficient right-recursive rules
///
/// The state machine supports advanced parsing features:
/// - **Precedence climbing** for operator expressions
/// - **Predicates** (lookahead with AND/NOT)
/// - **Conjunctions** (intersection of patterns)
/// - **Negations** (complement of patterns)
/// - **Parameters** (dynamic string/predicate matching)
/// - **Labels** (capturing groups and backreferences)
/// - **Marks** (for semantic actions)
///
/// Each rule is connected to form a complete automaton that can be used
/// by the parser to recognize strings matching the grammar.
class StateMachine {
  /// Create a state machine by compiling the grammar.
  ///
  /// This constructor:
  /// 1. Creates an initial state and connects the start rule to it
  /// 2. Marks the start state as accepting
  /// 3. Processes all grammar rules to build the state graph
  /// 4. For each rule, connects first patterns and sequence pairs
  /// 5. Marks return states for each rule
  /// 6. Analyzes rules for tail call optimization opportunities
  /// 7. Builds precedence maps for handling operator precedence
  ///
  /// Parameters:
  ///   [grammar] - The grammar interface to compile
  StateMachine(this.grammar) {
    var initState = _getOrCreateState(const InitStateKey());
    _connect(initState, grammar.startCall);

    // Mark the state after start call as accepting
    var startState = _getOrCreateState(PatternStateKey(grammar.startCall));
    startState.actions.add(const AcceptAction());

    if (grammar.isEmpty()) {
      initState.actions.add(const AcceptAction());
    }

    _initialStates = [initState];

    // Process each rule
    for (var rule in grammar.rules) {
      assert(
        rule.symbolId != null,
        "Invariant violation in StateMachine: "
        /* */ "rule.symbolId must be assigned before compilation.",
      );
      rules.add(rule.symbolId!);
      allRules[rule.symbolId!] = rule;

      var firstState = _getOrCreateState(PatternStateKey(rule));
      ruleFirst[rule.symbolId!] = firstState;
      _tailSelfCalls[rule] = _findDirectTailSelfCalls(rule);

      var ruleBody = rule.body();
      // Pre-calculate precedence mapping for this rule's body
      var precedenceMap = <Pattern, int?>{};
      _buildPrecedenceMap(ruleBody, null, precedenceMap);

      // Connect to first patterns
      for (var firstStateInRange in ruleBody.firstSet()) {
        _connect(firstState, firstStateInRange, currentRule: rule);
      }

      // Connect each pair
      for (var (a, b) in ruleBody.eachPair()) {
        _connect(_getOrCreateState(PatternStateKey(a)), b, currentRule: rule);
      }

      // Mark states before returns
      for (var lastState in ruleBody.lastSet()) {
        var state = _getOrCreateState(PatternStateKey(lastState));
        var action = ReturnAction(rule.symbolId!, precedenceMap[lastState]);
        state.actions.add(action);
      }

      if (ruleBody.empty()) {
        firstState.actions.add(ReturnAction(rule.symbolId!));
      }
    }
  }

  /// Internal constructor for pre-built state machines (imported).
  ///
  /// Used by ImportedStateMachine to reconstruct exported state machines
  /// without re-compiling the grammar. The state structure must be initialized
  /// separately via initializeImported.
  ///
  /// Parameters:
  ///   [grammar] - The grammar interface to associate with this machine
  StateMachine.empty(this.grammar);
  final GrammarInterface grammar;
  final List<PatternSymbol> rules = [];
  final Map<PatternSymbol, State> ruleFirst = {};

  /// All rules (including synthetic ones) indexed by their symbol.
  final Map<PatternSymbol, Rule> allRules = {};
  List<State>? _cachedStates;
  List<State> _initialStates = [];
  final Map<(String, State), State> _parameterStringChains = {};
  final Map<String, State> _parameterPredicateChains = {};
  final Rule _parameterPredicateRule = Rule("_parameter_predicate", () => Eps())..symbolId = -1;

  final Map<StateKey, State> _stateMapping = {};
  final Map<Rule, Set<RuleCall>> _tailSelfCalls = {};

  /// Initialize the state structure for imported state machines.
  ///
  /// This method is called by ImportedStateMachine to populate the state mapping
  /// and initial states from a previously serialized/exported state machine.
  /// It replaces the normal compilation process done in the main constructor.
  ///
  /// Parameters:
  ///   [initialStates] - The list of states to start parsing from
  ///   [stateMapping] - The complete mapping of state keys to compiled states
  void initializeImported(List<State> initialStates, Map<StateKey, State> stateMapping) {
    _initialStates = initialStates;
    _stateMapping.addAll(stateMapping);
    _cachedStates = stateMapping.values.toList();
  }

  /// Initialize from exported JSON data.
  ///
  /// This method sets up the state machine from pre-compiled data without needing
  /// StateKey objects. Used internally by importFromJson.
  ///
  /// Parameters:
  ///   [initialStates] - The initial states for parsing
  ///   [allStates] - All states in the compiled machine
  void initializeFromJson(List<State> initialStates, List<State> allStates) {
    _initialStates = initialStates;
    _cachedStates = allStates;
    // Populate state mapping using InitStateKey for first state
    if (initialStates.isNotEmpty) {
      _stateMapping[const InitStateKey()] = initialStates[0];
    }
  }

  /// Get or create a state with the given key.
  ///
  /// If a state with this key already exists, returns it.
  /// Otherwise, creates a new state with the next available ID.
  /// Invalidates the cached states list to ensure consistency.
  ///
  /// Parameters:
  ///   [key] - The key identifying the state (initial, pattern, parameter, etc.)
  ///
  /// Returns:
  ///   The existing or newly created state for this key
  State _getOrCreateState(StateKey key) {
    var state = _stateMapping[key];
    if (state != null) {
      return state;
    }
    var created = State(_stateMapping.length, []);
    _stateMapping[key] = created;
    _cachedStates = null;
    return created;
  }

  /// Get the initial/start state of the state machine.
  ///
  /// Returns:
  ///   The state marked as the initial state (created with [InitStateKey])
  State get startState => _stateMapping[const InitStateKey()]!;

  /// Get or create a chain of states for matching a parameter string.
  ///
  /// Parameter matching requires consuming characters one by one,
  /// so this creates a chain of states transitioning through each character
  /// until reaching the [nextState].
  ///
  /// Parameters:
  ///   [text] - The string to match character-by-character
  ///   [nextState] - The state to reach after matching all characters
  ///
  /// Returns:
  ///   The entry point state for this parameter string chain
  State parameterStringEntry(String text, State nextState) {
    if (text.isEmpty) {
      return nextState;
    }

    var key = (text, nextState);
    if (_parameterStringChains[key] case var state?) {
      return state;
    }

    var bytes = utf8.encode(text);
    var tail = nextState;
    for (var i = bytes.length - 1; i >= 0; i--) {
      var state = _getOrCreateState(ParamStringStateKey(text, i, nextState));
      if (state.actions.isEmpty) {
        state.actions.add(ParameterStringAction(bytes[i], tail));
      }
      tail = state;
    }
    return _parameterStringChains[key] = tail;
  }

  /// Get or create a chain of states for checking a parameter predicate.
  ///
  /// Parameter predicates are evaluated at runtime to check if the parameter
  /// value matches a specific string. This creates a chain of states that
  /// consumes characters and ultimately returns if the entire string matches.
  ///
  /// Parameters:
  ///   [text] - The string that the parameter must match
  ///
  /// Returns:
  ///   The entry point state for this predicate check chain
  State parameterPredicateEntry(String text) {
    // Predicates use the same cached chain idea, but end in a synthetic
    // return state so lookahead can resume the caller if the predicate matches.

    if (_parameterPredicateChains[text] case var state?) {
      return state;
    }

    var terminal = _getOrCreateState(ParamPredicateEndStateKey(text));
    if (terminal.actions.isEmpty) {
      terminal.actions.add(ReturnAction(_parameterPredicateRule.symbolId!));
    }

    if (text.isEmpty) {
      return terminal;
    }

    var bytes = utf8.encode(text);
    var tail = terminal;
    for (var i = bytes.length - 1; i >= 0; i--) {
      var state = _getOrCreateState(ParamPredicateStateKey(text, i));
      if (state.actions.isEmpty) {
        state.actions.add(ParameterStringAction(bytes[i], tail));
      }
      tail = state;
    }
    return _parameterPredicateChains[text] = tail;
  }

  /// Connect a state to a pattern terminal.
  ///
  /// This method is the core of state machine construction. It examines
  /// the pattern type and creates appropriate transitions:
  ///
  /// - **Tokens**: Create [TokenAction] to consume specific input
  /// - **Conjunctions**: Create [ConjunctionAction] for (A & B) intersection parsing
  /// - **Boundaries**: Create [BoundaryAction] for start/EOF checks
  /// - **Markers**: Create [MarkAction] for semantic backref capture
  /// - **Predicates**: Create [PredicateAction] for (AND/NOT) lookahead
  /// - **Rule calls**: Create [CallAction] or [TailCallAction] for function calls
  /// - **Labels**: Create [LabelStartAction]/[LabelEndAction] for capture groups
  /// - **Backreferences**: Create [BackreferenceAction] to match captured text
  /// - **Parameters**: Create [ParameterAction]/[ParameterCallAction] for dynamic matching
  ///
  /// Parameters:
  ///   [state] - The state to add the transition from
  ///   [terminal] - The pattern to connect
  ///   [currentRule] - Optional: the current rule (used for tail call detection)
  void _connect(State state, Pattern terminal, {Rule? currentRule}) {
    switch (terminal) {
      case Token():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = TokenAction(terminal.choice, nextState);
        state.actions.add(action);
      case Conj():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        // Complex conjunction: use sub-parse rendezvous
        var action = ConjunctionAction(
          leftSymbol: _extractSymbol(terminal.left),
          rightSymbol: _extractSymbol(terminal.right),
          nextState: nextState,
        );
        state.actions.add(action);
      case StartAnchor() || EofAnchor():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var kind = terminal is StartAnchor ? BoundaryKind.start : BoundaryKind.eof;
        var action = BoundaryAction(kind, nextState);
        state.actions.add(action);
      case Marker():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = MarkAction(terminal.name, nextState);
        state.actions.add(action);
      case And():
        // Positive lookahead: create predicate action
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        switch (terminal.pattern) {
          case RuleCall(:var rule):
            state.actions.add(
              PredicateAction(isAnd: true, symbol: rule.symbolId!, nextState: nextState),
            );
          case ParameterRefPattern(:var name):
            // Parameter lookahead is resolved from the current caller
            // arguments, which lets `&param` inspect dynamic parser data.
            state.actions.add(
              ParameterPredicateAction(isAnd: true, name: name, nextState: nextState),
            );
          default:
            throw UnsupportedError("Invalid pattern type for predicate action");
        }
      case Not():
        // Negative lookahead: create predicate action
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        switch (terminal.pattern) {
          case RuleCall(:var rule):
            state.actions.add(
              PredicateAction(isAnd: false, symbol: rule.symbolId!, nextState: nextState),
            );
          case ParameterRefPattern(:var name):
            // Negative parameter predicates use the same runtime resolution
            // path, but only resume when the value does *not* match.
            state.actions.add(
              ParameterPredicateAction(isAnd: false, name: name, nextState: nextState),
            );
          default:
            throw UnsupportedError("Invalid pattern type for predicate action");
        }
      case RuleCall(:var minPrecedenceLevel):
        if (currentRule != null &&
            minPrecedenceLevel == null &&
            (_tailSelfCalls[currentRule]?.contains(terminal) ?? false)) {
          var action = TailCallAction(
            terminal.rule.symbolId!,
            terminal.arguments,
            minPrecedenceLevel,
          );
          state.actions.add(action);
        } else {
          var returnState = _getOrCreateState(PatternStateKey(terminal));
          var action = CallAction(
            terminal.rule.symbolId!,
            terminal.arguments,
            returnState,
            minPrecedenceLevel,
          );
          state.actions.add(action);
        }
      case LabelStart():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = LabelStartAction(terminal.name, nextState);
        state.actions.add(action);
      case LabelEnd():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = LabelEndAction(terminal.name, nextState);
        state.actions.add(action);
      case Backreference():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = BackreferenceAction(terminal.name, nextState);
        state.actions.add(action);
      case ParameterRefPattern():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = ParameterAction(terminal.name, nextState);
        state.actions.add(action);
      case ParameterCallPattern():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = ParameterCallAction(
          terminal.name,
          terminal.arguments,
          nextState,
          terminal.minPrecedenceLevel,
        );
        state.actions.add(action);
      case Retreat():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = RetreatAction(nextState);
        state.actions.add(action);
      case Eps():
        // Epsilon doesn't create transitions
        break;
      case IfCond() ||
          Action() ||
          Alt() ||
          Seq() ||
          Rule() ||
          Prec() ||
          Label() ||
          Opt() ||
          Plus() ||
          Star():
        // These should have been decomposed by Glushkov construction
        throw UnimplementedError("Unexpected pattern type in _connect: ${terminal.runtimeType}");
    }
  }

  /// Extract the symbol (rule ID) from a pattern.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to extract the symbol from
  ///
  /// Returns:
  ///   The rule symbol ID if the pattern is a [RuleCall]
  ///
  /// Throws:
  ///   [UnsupportedError] if the pattern is not a rule call or token
  PatternSymbol _extractSymbol(Pattern pattern) {
    return switch (pattern) {
      RuleCall(:var rule) => rule.symbolId!,
      _ => throw UnsupportedError("Conjunction children must be rules or tokens: $pattern"),
    };
  }

  /// Build a map of patterns to their precedence levels.
  ///
  /// This recursively traverses the pattern structure, tracking precedence
  /// through [Prec] nodes. Used by [ReturnAction] to apply correct precedence
  /// levels during parsing.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to analyze
  ///   [current] - The current precedence level
  ///   [map] - The map to populate with precedence information
  void _buildPrecedenceMap(Pattern pattern, int? current, Map<Pattern, int?> map) {
    if (pattern is Prec) {
      _buildPrecedenceMap(pattern.child, pattern.precedenceLevel, map);
      return;
    }

    // Leaf nodes or other nodes that might be in lastSet()
    map[pattern] = current;

    if (pattern is Alt) {
      _buildPrecedenceMap(pattern.left, current, map);
      _buildPrecedenceMap(pattern.right, current, map);
    } else if (pattern is Seq) {
      _buildPrecedenceMap(pattern.left, current, map);
      _buildPrecedenceMap(pattern.right, current, map);
    } else if (pattern is Action) {
      _buildPrecedenceMap(pattern.child, current, map);
    } else if (pattern is Label) {
      _buildPrecedenceMap(pattern.child, current, map);
      map[pattern] = current;
      assert(
        pattern.firstSet().isNotEmpty && pattern.lastSet().isNotEmpty,
        "Invariant violation in _buildPrecedenceMap: Label must expose non-empty "
        "first/last sets for precedence propagation.",
      );
      map[pattern.firstSet().first] = current;
      map[pattern.lastSet().first] = current;
    } else if (pattern is Opt) {
      _buildPrecedenceMap(pattern.child, current, map);
    } else if (pattern is Plus) {
      _buildPrecedenceMap(pattern.child, current, map);
    } else if (pattern is Star) {
      _buildPrecedenceMap(pattern.child, current, map);
    }
  }

  /// Get all states in this state machine.
  ///
  /// The list is cached until the state machine is modified.
  ///
  /// Returns:
  ///   A list of all compiled states
  List<State> get states {
    _cachedStates ??= _stateMapping.values.toList();
    return _cachedStates!;
  }

  /// Get all initial states that parsing can start from.
  ///
  /// Returns:
  ///   A list of the initial states (typically just the start state for grammars)
  List<State> get initialStates => _initialStates;

  /// Render the compiled state machine as Graphviz DOT.
  ///
  String toDot() => _toDot(this);

  /// Find all direct tail-self-call opportunities in a rule.
  ///
  /// Tail call optimization replaces recursive calls at the end of a sequence
  /// with efficient loop jumps, avoiding stack growth for right-recursive patterns.
  ///
  /// This method identifies rules that can be optimized by checking:
  /// 1. The rule has exactly two branches: base case and recursive case
  /// 2. One branch is the base (non-recursive) case that consumes input
  /// 3. The other is a sequence that ends with an immediate recursive call
  /// 4. The base case must not be empty (to ensure progress)
  /// 5. The prefix before the recursive call must consume input
  ///
  /// Parameters:
  ///   [rule] - The rule to analyze for tail call opportunities
  ///
  /// Returns:
  ///   Set of direct tail recursive calls in this rule (typically 0 or 1)
  Set<RuleCall> _findDirectTailSelfCalls(Rule rule) {
    var branches = _flattenAlternation(_stripTransparent(rule.body()));
    // Only optimize the simple shape:
    //   base | prefix self
    // Anything more complex stays on the general call/return path.
    if (branches.length != 2) {
      return const <RuleCall>{};
    }

    Pattern? baseBranch;
    Pattern? recursiveBranch;
    for (var branch in branches) {
      // Exactly one branch must recurse back to the same rule.
      // Multiple recursive branches need the full generalized machinery.
      if (_containsRuleReference(branch, rule)) {
        if (recursiveBranch != null) {
          return const <RuleCall>{};
        }
        recursiveBranch = _stripTransparent(branch);
      } else {
        if (baseBranch != null) {
          return const <RuleCall>{};
        }
        baseBranch = _stripTransparent(branch);
      }
    }

    if (baseBranch == null || recursiveBranch == null) {
      return const <RuleCall>{};
    }
    // The non-recursive exit must consume input. If it can match empty, then
    // replacing recursion with a loop would erase real epsilon cycles.
    if (!_isDefinitelyNonEmpty(baseBranch)) {
      return const <RuleCall>{};
    }

    var recursiveParts = _stripDeadSuffixes(_flattenSequence(recursiveBranch));
    if (recursiveParts.isEmpty) {
      return const <RuleCall>{};
    }

    var last = _stripTransparent(recursiveParts.last);
    // Only direct right-tail self calls qualify.
    // Left recursion and precedence-constrained calls are intentionally excluded.
    if (last is! RuleCall ||
        !identical(last.rule, rule) ||
        last.minPrecedenceLevel != null ||
        last.arguments.isNotEmpty) {
      return const <RuleCall>{};
    }

    var prefixParts = recursiveParts
        .sublist(0, recursiveParts.length - 1)
        .map(_stripTransparent)
        .toList();
    // The prefix before the tail call must always make progress and must not
    // recurse. That guarantees each loop iteration advances the input.
    if (prefixParts.isEmpty || prefixParts.any((part) => _containsRuleReference(part, rule))) {
      return const <RuleCall>{};
    }

    var prefix = _joinSequence(prefixParts);
    if (!_isDefinitelyNonEmpty(prefix)) {
      return const <RuleCall>{};
    }

    return {last};
  }

  /// Flatten an alternation pattern into a list of branches.
  ///
  /// Recursively expands all [Alt] nodes to produce a flat list
  /// where each element is a branch of the original alternation.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to flatten
  ///
  /// Returns:
  ///   A list of all branches in the alternation
  List<Pattern> _flattenAlternation(Pattern pattern) {
    return switch (pattern) {
      Alt(:var left, :var right) => [..._flattenAlternation(left), ..._flattenAlternation(right)],
      _ => [pattern],
    };
  }

  /// Flatten a sequence pattern into a list of elements.
  ///
  /// Recursively expands all [Seq] nodes to produce a flat list
  /// where each element is a component of the original sequence.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to flatten
  ///
  /// Returns:
  ///   A list of all elements in the sequence
  List<Pattern> _flattenSequence(Pattern pattern) {
    return switch (pattern) {
      Seq(:var left, :var right) => [..._flattenSequence(left), ..._flattenSequence(right)],
      _ => [pattern],
    };
  }

  /// Remove dead suffixes (epsilon/empty patterns) from a list.
  ///
  /// Dead suffixes are epsilon patterns that don't contribute to parsing
  /// and shouldn't prevent tail-position detection.
  ///
  /// Parameters:
  ///   [patterns] - The list of patterns
  ///
  /// Returns:
  ///   The list with trailing epsilons removed
  List<Pattern> _stripDeadSuffixes(List<Pattern> patterns) {
    var end = patterns.length;
    while (end > 0 && _isDeadSuffix(patterns[end - 1])) {
      end--;
    }
    return patterns.sublist(0, end);
  }

  /// Strip transparent wrappers from a pattern.
  ///
  /// Transparent wrappers ([Action], [Prec]) don't affect the parsing structure,
  /// so this unwraps them to get to the underlying pattern for analysis.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to unwrap
  ///
  /// Returns:
  ///   The innermost non-transparent pattern
  Pattern _stripTransparent(Pattern pattern) {
    Pattern current = pattern;
    while (true) {
      switch (current) {
        case Action(:var child):
          current = child;
        case Prec(:var child):
          current = child;
        default:
          return current;
      }
    }
  }

  /// Check if a pattern is a dead suffix.
  ///
  /// A dead suffix contributes nothing to parsing (epsilon patterns).
  ///
  /// Parameters:
  ///   [pattern] - The pattern to check
  ///
  /// Returns:
  ///   true if this pattern is a dead suffix, false otherwise
  bool _isDeadSuffix(Pattern pattern) {
    var stripped = _stripTransparent(pattern);
    // A trailing epsilon contributes neither input progress nor a real
    // continuation boundary, so it should not block tail-position detection.
    return stripped is Eps;
  }

  /// Check if a pattern contains a reference to a specific rule.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to search
  ///   [target] - The rule to look for
  ///
  /// Returns:
  ///   true if this pattern or any subpattern references the target rule
  bool _containsRuleReference(Pattern pattern, Rule target) {
    var referencedRules = <Rule>{};
    pattern.collectRules(referencedRules);
    return referencedRules.contains(target);
  }

  /// Join a list of patterns into a single sequence.
  ///
  /// Parameters:
  ///   [patterns] - The patterns to join
  ///
  /// Returns:
  ///   A single pattern representing sequences of all input patterns
  ///
  /// Throws:
  ///   [AssertionError] if patterns is empty
  Pattern _joinSequence(List<Pattern> patterns) {
    assert(
      patterns.isNotEmpty,
      "Invariant violation: sequence join requires at least one pattern.",
    );
    return patterns.reduce((left, right) => left >> right);
  }

  /// Check if a pattern definitely consumes input (is non-empty).
  ///
  /// This is a conservative check used to ensure tail calls make progress.
  /// Some patterns (like alternatives) return false if they might be empty,
  /// even if they sometimes consume input.
  ///
  /// Parameters:
  ///   [pattern] - The pattern to check
  ///
  /// Returns:
  ///   true if the pattern always consumes at least one input element
  bool _isDefinitelyNonEmpty(Pattern pattern) {
    return switch (pattern) {
      Eps() || Opt() || Star() => false,
      Token() ||
      Marker() ||
      StartAnchor() ||
      EofAnchor() ||
      LabelStart() ||
      LabelEnd() ||
      Backreference() ||
      Rule() ||
      RuleCall() ||
      Retreat() => true,
      ParameterRefPattern() => false,
      ParameterCallPattern() => false,
      Alt(:var left, :var right) => _isDefinitelyNonEmpty(left) && _isDefinitelyNonEmpty(right),
      Seq(:var left, :var right) => _isDefinitelyNonEmpty(left) || _isDefinitelyNonEmpty(right),
      Conj(:var left, :var right) => _isDefinitelyNonEmpty(left) || _isDefinitelyNonEmpty(right),
      And() || Not() => false,
      IfCond(:var pattern) => _isDefinitelyNonEmpty(pattern),
      Action(:var child) ||
      Prec(:var child) ||
      Plus(:var child) ||
      Label(:var child) => _isDefinitelyNonEmpty(child),
    };
  }
}

/// Converts a [StateMachine] into Graphviz DOT format for visualization.
///
/// This generates a directed graph where:
/// - Nodes represent states in the state machine
/// - Edges represent transitions (StateActions) between states
/// - Special nodes include:
///   - `__start__`: Entry point (shown as a point)
///   - `__accept__`: Accepting state (shown as double circle)
///   - `__return_<RuleName>__`: Rule-specific return nodes (shown as gray boxes)
///
/// The visualization uses different edge styles to distinguish action types:
/// - Bold edges: function calls
/// - Dashed green edges: AND predicates
/// - Dashed gray edges: returns
/// - Regular edges: other transitions
///
/// Returns a String containing the complete Graphviz DOT format.
String _toDot(StateMachine machine) {
  var buffer = StringBuffer();

  // Write graph header and global styling
  buffer.writeln("digraph StateMachine {");
  buffer.writeln("  rankdir=LR;");
  buffer.writeln('  node [fontname="Courier"];');
  buffer.writeln('  "__start__" [shape=point, label=""];');
  buffer.writeln('  "__accept__" [shape=doublecircle, label="accept"];');

  // Collect all unique rules that have return actions
  // This allows us to create per-rule return nodes
  var returnRules = <PatternSymbol>{};
  for (var state in machine._stateMapping.values) {
    for (var action in state.actions) {
      if (action is ReturnAction) {
        returnRules.add(action.ruleSymbol);
      }
    }
  }

  // Create rule-specific return nodes for visualization
  // Each rule gets its own return node to make control flow clearer
  for (var symbol in returnRules) {
    var returnNodeId = "__return_${symbol}__";
    buffer.writeln(
      '  "$returnNodeId" [shape=box, label="return $symbol", style=filled, fillcolor=lightgray];',
    );
  }

  // Create nodes for all states in the state machine
  // Iterate through _stateMapping to ensure ALL states are included
  // (including parameter states and predicate states)
  for (var entry in machine._stateMapping.entries) {
    var state = entry.value;
    var stateId = "S${state.id}";

    // Determine an appropriate label for this state based on its key type
    String label = "S${state.id}";

    var key = entry.key;
    if (key is InitStateKey) {
      label = "init";
    } else if (key is PatternStateKey) {
      label = key.pattern.toString();
    } else if (key is ParamStringStateKey) {
      label = "param_str[${key.index}]";
    } else if (key is ParamPredicateStateKey) {
      label = "param_pred[${key.index}]";
    } else if (key is ParamPredicateEndStateKey) {
      label = "param_pred_end";
    }

    // Check if this state is an accept state
    // Accept states are shown with a double circle shape
    bool isAcceptState = false;
    for (var action in state.actions) {
      if (action is AcceptAction) {
        isAcceptState = true;
        break;
      }
    }

    // Write the node definition with appropriate shape and label
    var shape = isAcceptState ? "doublecircle" : "circle";
    buffer.writeln('  "$stateId" [shape=$shape, label="$label"];');
  }

  // Create the start edge from the invisible start point to the initial state
  var startState = "S${machine.startState.id}";
  buffer.writeln('  "__start__" -> "$startState" [label="start"];');

  // Create edges for all state transitions
  // Each StateAction becomes one or more edges in the DOT graph
  for (var state in machine._stateMapping.values) {
    var fromStateId = "S${state.id}";

    for (var action in state.actions) {
      // TokenAction: consume a token and transition
      if (action is TokenAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="token ${_dotEscape(action.choice.toString())}"];',
        );
      }
      // CallAction: enter a subroutine (rule call)
      else if (action is CallAction) {
        var toStateId = "S${action.returnState.id}";
        var ruleDisplay = action.minPrecedenceLevel != null
            ? "${action.ruleSymbol}^${action.minPrecedenceLevel}"
            : action.ruleSymbol;
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="call $ruleDisplay", style=bold];');
      }
      // TailCallAction: optimized recursive call (loops back to same state)
      else if (action is TailCallAction) {
        var ruleDisplay = action.minPrecedenceLevel != null
            ? "${action.ruleSymbol}^${action.minPrecedenceLevel}"
            : action.ruleSymbol;
        buffer.writeln(
          '  "$fromStateId" -> "$fromStateId" [label="tail call $ruleDisplay", style=bold];',
        );
      }
      // ReturnAction: return from a subroutine to the rule's return node
      else if (action is ReturnAction) {
        var returnNodeId = "__return_${action.ruleSymbol}__";
        var labelStr = (machine.grammar.registry[action.ruleSymbol]! as Rule).name as String;
        if (action.precedenceLevel != null) {
          labelStr = "$labelStr (prec: ${action.precedenceLevel})";
        }
        buffer.writeln(
          '  "$fromStateId" -> "$returnNodeId" [label="return $labelStr", style=dashed, color=gray45];',
        );
      }
      // MarkAction: set a mark for later backreference
      else if (action is MarkAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="mark ${action.name}"];');
      }
      // BoundaryAction: check start-of-input or end-of-input boundary
      else if (action is BoundaryAction) {
        var toStateId = "S${action.nextState.id}";
        var kindStr = action.kind == BoundaryKind.start ? "start" : "eof";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="boundary $kindStr"];');
      }
      // LabelStartAction: begin a labeled capture group
      else if (action is LabelStartAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="label start ${action.name}"];');
      }
      // LabelEndAction: end a labeled capture group
      else if (action is LabelEndAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="label end ${action.name}"];');
      }
      // BackreferenceAction: match a previously captured group
      else if (action is BackreferenceAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="backref ${action.name}"];');
      }
      // ParameterAction: consume a parameter value
      else if (action is ParameterAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="param ${action.name}"];');
      }
      // ParameterCallAction: call a parameterized rule
      else if (action is ParameterCallAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="param call ${_dotEscape(action.arguments.toString())}"];',
        );
      }
      // ParameterStringAction: match one character from a parameter string
      else if (action is ParameterStringAction) {
        var toStateId = "S${action.nextState.id}";
        var char = String.fromCharCode(action.codeUnit);
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="param str ${_dotEscape(char)}"];');
      }
      // ParameterPredicateAction: predicate check on a parameter
      else if (action is ParameterPredicateAction) {
        var toStateId = "S${action.nextState.id}";
        var pred = action.isAnd ? "&" : "!";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="param pred $pred${action.name}"];',
        );
      }
      // PredicateAction: lookahead assertion (AND or NOT)
      else if (action is PredicateAction) {
        var toStateId = "S${action.nextState.id}";
        var pred = action.isAnd ? "AND" : "NOT";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="$pred ${_dotEscape(action.symbol.toString())}", style=dashed, color=seagreen4];',
        );
      }
      // ConjunctionAction: intersection (A & B) parsing
      else if (action is ConjunctionAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="Conj ${_dotEscape(action.leftSymbol.toString())} & ${_dotEscape(action.rightSymbol.toString())}"];',
        );
      }
      // AcceptAction: successful parse - connect to accept node
      else if (action is AcceptAction) {
        buffer.writeln('  "$fromStateId" -> "__accept__" [label="accept"];');
      }
    }
  }

  // Close the graph
  buffer.writeln("}");
  return buffer.toString();
}

/// Escapes special characters in a string for use in Graphviz DOT format.
///
/// Graphviz DOT requires certain characters to be escaped:
/// - Backslash (\) → \\
/// - Double quote (") → \"
/// - Newline → \n
/// - Carriage return → \r
/// - Tab → \t
///
/// This ensures that pattern descriptions, labels, and other text can be safely
/// embedded in DOT edge and node labels without breaking the graph syntax.
///
/// Parameters:
///   [value] - The string to escape
///
/// Returns:
///   The escaped string safe for use in DOT format
String _dotEscape(String value) {
  var out = StringBuffer();
  for (var rune in value.runes) {
    switch (rune) {
      case 0x5C: // \
        out.write(r"\\");
      case 0x22: // "
        out.write(r'\"');
      case 0x0A: // newline
        out.write(r"\n");
      case 0x0D: // carriage return
        out.write(r"\r");
      case 0x09: // tab
        out.write(r"\t");
      default:
        out.write(String.fromCharCode(rune));
    }
  }
  return out.toString();
}
