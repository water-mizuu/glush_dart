/// State machine compilation from grammars
library glush.state_machine;

import "dart:convert";

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/key/state_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:meta/meta.dart";

/// A single configuration within the [StateMachine].
///
/// Each state represents a specific point in the grammar's derivation. It holds
/// a collection of [actions] that define the possible transitions to subsequent
/// states.
@immutable
class State {
  /// Creates a state with a unique [id] and its associated [actions].
  const State(this.id, this.actions);

  /// The unique identifier for this state.
  final int id;

  /// The set of transitions available from this state.
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
  /// Compiles a [grammar] into its state machine representation.
  ///
  /// The construction follows the Glushkov algorithm, which transforms the
  /// grammar's regular and recursive expressions into a non-deterministic finite
  /// automaton (NFA) that is then executed by the GLL-style parser engine.
  ///
  /// During compilation, the machine:
  /// 1. Identifies the "first" set for each rule to establish entry points.
  /// 2. Connects sequence pairs to establish internal transitions.
  /// 3. Identifies "last" sets to establish rule return points.
  /// 4. Analyzes the grammar for tail-call optimization opportunities.
  /// 5. Builds precedence maps to resolve operator priority.
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

    _precompileRuleStartAdmissibility();
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
  final Map<(PatternSymbol, int?, bool), bool> _ruleStartAdmissibilityCache = {};
  final Map<PatternSymbol, _RuleStartAdmissibilityTable> _ruleStartAdmissibilityTables = {};

  static const int _precompiledTokenMin = 0;
  static const int _precompiledTokenMax = 255;

  /// Returns true if [symbol] can potentially begin matching at [token].
  ///
  /// This check is conservative: it returns false only when the rule is
  /// definitely impossible to start at this token. Unknown constructs default to
  /// true to avoid pruning valid parses.
  bool canRuleStartWith(PatternSymbol symbol, int? token, {required bool isAtStart}) {
    var table = _ruleStartAdmissibilityTables[symbol]!;
    if (token == null) {
      return isAtStart ? table.eofAtStart : table.eofNotAtStart;
    }
    if (token >= _precompiledTokenMin && token <= _precompiledTokenMax) {
      return isAtStart ? table.atStart[token] : table.notAtStart[token];
    }

    var key = (symbol, token, isAtStart);
    if (_ruleStartAdmissibilityCache[key] case var cached?) {
      return cached;
    }

    var result = _canRuleStartWith(
      symbol,
      token,
      isAtStart: isAtStart,
      visitingRules: <PatternSymbol>{},
    );
    _ruleStartAdmissibilityCache[key] = result;
    return result;
  }

  void _precompileRuleStartAdmissibility() {
    for (var symbol in ruleFirst.keys) {
      var atStart = List<bool>.filled(_precompiledTokenMax + 1, false);
      var notAtStart = List<bool>.filled(_precompiledTokenMax + 1, false);

      for (var token = _precompiledTokenMin; token <= _precompiledTokenMax; token++) {
        var startValue = _canRuleStartWith(
          symbol,
          token,
          isAtStart: true,
          visitingRules: <PatternSymbol>{},
        );
        var nonStartValue = _canRuleStartWith(
          symbol,
          token,
          isAtStart: false,
          visitingRules: <PatternSymbol>{},
        );
        atStart[token] = startValue;
        notAtStart[token] = nonStartValue;

        _ruleStartAdmissibilityCache[(symbol, token, true)] = startValue;
        _ruleStartAdmissibilityCache[(symbol, token, false)] = nonStartValue;
      }

      var eofAtStart = _canRuleStartWith(
        symbol,
        null,
        isAtStart: true,
        visitingRules: <PatternSymbol>{},
      );
      var eofNotAtStart = _canRuleStartWith(
        symbol,
        null,
        isAtStart: false,
        visitingRules: <PatternSymbol>{},
      );
      _ruleStartAdmissibilityTables[symbol] = _RuleStartAdmissibilityTable(
        atStart: atStart,
        notAtStart: notAtStart,
        eofAtStart: eofAtStart,
        eofNotAtStart: eofNotAtStart,
      );
      _ruleStartAdmissibilityCache[(symbol, null, true)] = eofAtStart;
      _ruleStartAdmissibilityCache[(symbol, null, false)] = eofNotAtStart;
    }
  }

  bool _canRuleStartWith(
    PatternSymbol symbol,
    int? token, {
    required bool isAtStart,
    required Set<PatternSymbol> visitingRules,
  }) {
    if (visitingRules.contains(symbol)) {
      // Cycles are treated as unknown/possible to avoid unsound pruning.
      return true;
    }

    var entry = ruleFirst[symbol];
    if (entry == null) {
      return true;
    }

    visitingRules.add(symbol);
    var result = _stateCanStartWith(
      entry,
      token,
      isAtStart: isAtStart,
      visitingStates: <int>{},
      visitingRules: visitingRules,
    );
    visitingRules.remove(symbol);
    return result;
  }

  bool _stateCanStartWith(
    State state,
    int? token, {
    required bool isAtStart,
    required Set<int> visitingStates,
    required Set<PatternSymbol> visitingRules,
  }) {
    if (!visitingStates.add(state.id)) {
      return false;
    }

    for (var action in state.actions) {
      switch (action) {
        case TokenAction(:var choice):
          if (token != null && choice.matches(token)) {
            return true;
          }
        case ParameterStringAction(:var codeUnit):
          if (token != null && token == codeUnit) {
            return true;
          }
        case MarkAction(:var nextState):
          if (_stateCanStartWith(
            nextState,
            token,
            isAtStart: isAtStart,
            visitingStates: visitingStates,
            visitingRules: visitingRules,
          )) {
            return true;
          }
        case LabelStartAction(:var nextState):
          if (_stateCanStartWith(
            nextState,
            token,
            isAtStart: isAtStart,
            visitingStates: visitingStates,
            visitingRules: visitingRules,
          )) {
            return true;
          }
        case LabelEndAction(:var nextState):
          if (_stateCanStartWith(
            nextState,
            token,
            isAtStart: isAtStart,
            visitingStates: visitingStates,
            visitingRules: visitingRules,
          )) {
            return true;
          }
        case BoundaryAction(:var kind, :var nextState):
          if (kind == BoundaryKind.start && !isAtStart) {
            continue;
          }
          if (kind == BoundaryKind.eof && token != null) {
            continue;
          }
          if (_stateCanStartWith(
            nextState,
            token,
            isAtStart: isAtStart,
            visitingStates: visitingStates,
            visitingRules: visitingRules,
          )) {
            return true;
          }
        case CallAction(:var ruleSymbol):
          if (_canRuleStartWith(
            ruleSymbol,
            token,
            isAtStart: isAtStart,
            visitingRules: visitingRules,
          )) {
            return true;
          }
        case TailCallAction(:var ruleSymbol):
          if (_canRuleStartWith(
            ruleSymbol,
            token,
            isAtStart: isAtStart,
            visitingRules: visitingRules,
          )) {
            return true;
          }
        case ReturnAction():
          // The rule can complete without consuming input.
          return true;
        case AcceptAction():
          // Accept state is also a zero-consumption success path.
          return true;
        case PredicateAction() ||
            ConjunctionAction() ||
            ParameterAction() ||
            ParameterCallAction() ||
            ParameterPredicateAction() ||
            RetreatAction():
          // Runtime-dependent behavior: treat as possible.
          return true;
      }
    }

    return false;
  }

  void _ensureRuleStartAdmissibilityPrecompiled() {
    if (_ruleStartAdmissibilityTables.isEmpty && ruleFirst.isNotEmpty) {
      _precompileRuleStartAdmissibility();
    }
  }

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
    _ensureRuleStartAdmissibilityPrecompiled();
  }

  Map<int, StateKey>? _idToKey;

  /// Returns the [StateKey] that produced the given [stateId].
  ///
  /// This is used for debugging and diagnostics to understand which grammar
  /// pattern or rule a particular state belongs to.
  StateKey? keyOf(int stateId) {
    _idToKey ??= {for (var entry in _stateMapping.entries) entry.value.id: entry.key};
    return _idToKey![stateId];
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
    _ensureRuleStartAdmissibilityPrecompiled();
  }

  /// Retrieves an existing state or creates a new one for the given [key].
  ///
  /// This ensures that states are deduplicated based on their logical identity
  /// (e.g., a specific position in a specific pattern).
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

  /// Generates a chain of states to match a specific [text] string as a parameter.
  ///
  /// When a parameter is used in a position that consumes input, the machine
  /// must synthesize a path that matches the parameter's value. This method
  /// creates a linear sequence of [ParameterStringAction] transitions that
  /// ultimately lead to [nextState].
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

  /// Generates a chain of states for a parameter-based lookahead predicate.
  ///
  /// This is similar to [parameterStringEntry], but the chain ends in a
  /// [ReturnAction] instead of transitioning to another state. This allows the
  /// predicate engine to resolve whether a parameter matches a specific string.
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

  /// Connects [state] to the entry point of the given [terminal] pattern.
  ///
  /// This is the core recursive step of the Glushkov construction. It
  /// determines which [StateAction] should be added to the source state to
  /// reach the target pattern. It handles the full diversity of PEG patterns,
  /// including tokens, rule calls, predicates, and dynamic parameters.
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

  /// Analyzes a rule for tail-call optimization (TCO) opportunities.
  ///
  /// TCO is an essential optimization for right-recursive grammars. Instead of
  /// allocating a new stack frame (GSS node) for a recursive call at the end of
  /// a rule, the state machine can emit a [TailCallAction] which allows the
  /// parser to "jump" back to the rule's entry point while staying in the
  /// current context.
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

final class _RuleStartAdmissibilityTable {
  const _RuleStartAdmissibilityTable({
    required this.atStart,
    required this.notAtStart,
    required this.eofAtStart,
    required this.eofNotAtStart,
  });

  final List<bool> atStart;
  final List<bool> notAtStart;
  final bool eofAtStart;
  final bool eofNotAtStart;
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
