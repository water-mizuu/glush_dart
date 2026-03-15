/// State machine-based parser implementation
library glush.sm_parser;

import 'dart:async';

import 'patterns.dart';
import 'state_machine.dart';
import 'mark.dart';
import 'list.dart';
import 'sppf.dart';
import 'bsr.dart';
export 'bsr.dart';

// ---------------------------------------------------------------------------
// Parse result types — sealed hierarchy replaces dynamic return values
// ---------------------------------------------------------------------------

/// Sealed result type returned by [SMParser.parse] and [SMParser.parseWithForest].
sealed class ParseOutcome<T> {}

/// Returned when parsing fails.
final class ParseError<T> extends ParseOutcome<T> implements Exception {
  final int position;

  ParseError(this.position);

  @override
  String toString() => 'ParseError at position $position';
}

/// Returned when parsing succeeds (marks-based parse).
final class ParseSuccess<T> extends ParseOutcome<T> {
  final ParserResult result;

  ParseSuccess(this.result);
}

/// Returned when parsing succeeds with a full parse forest.
final class ParseForestSuccess<T> extends ParseOutcome<T> {
  final ParseForest forest;

  ParseForestSuccess(this.forest);

  @override
  String toString() => 'ParseForestSuccess(forest=$forest)';
}

// ---------------------------------------------------------------------------

class ParserResult {
  final List<Mark> _rawMarks;

  ParserResult(this._rawMarks);

  List<String> get marks {
    final result = <String>[];
    String? currentStringMark;

    for (final mark in _rawMarks) {
      if (mark is NamedMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is StringMark) {
        currentStringMark = (currentStringMark ?? '') + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }
    
    return result;
  }

  List<List<Object?>> toList() => _rawMarks.map((m) {
    if (m is NamedMark) return m.toList();
    if (m is StringMark) return m.toList();
    return [];
  }).toList();
}

/// Represents a single parse tree derivation
class ParseDerivation {
  final String symbol;
  final int start;
  final int end;
  final List<ParseDerivation> children;

  ParseDerivation(this.symbol, this.start, this.end, this.children);

  /// Get substring that this derivation matched
  String getMatchedText(String input) {
    if (input.isEmpty || start >= input.length) {
      return '';
    }
    final actualEnd = end > input.length ? input.length : end;
    return input.substring(start, actualEnd);
  }

  /// Convert to flat tree string showing matched content and structure
  /// Example: for input "sss" with grammar S=s|SS|SSS might show (s(ss))
  String toTreeString(String? input) {
    if (children.isEmpty) {
      // Leaf node - show the matched text if input provided, otherwise just span
      if (input != null) {
        return getMatchedText(input);
      }
      return input == null ? '[$start:$end]' : '${input.substring(start, end)}';
    }
    // Parens showing children structure with their matched content
    final childStr = children.map((c) => c.toTreeString(input)).join('');
    return '($childStr)';
  }

  /// Pretty print the parse tree
  @override
  String toString() => '$symbol[$start:$end]';
}

/// Represents a parse tree with its evaluated semantic value
class ParseDerivationWithValue<T> {
  final ParseDerivation tree;
  final T value;

  ParseDerivationWithValue(this.tree, this.value);

  /// Get substring that this derivation matched
  String getMatchedText(String input) => tree.getMatchedText(input);

  /// Get the tree's symbol
  String get symbol => tree.symbol;

  /// Get the tree's span
  int get start => tree.start;
  int get end => tree.end;

  /// Get the tree's children
  List<ParseDerivation> get children => tree.children;

  @override
  String toString() => '$symbol[$start:$end]=$value';
}

// ---------------------------------------------------------------------------
// Predicate lookahead buffer — supports unbounded lookahead with buffering
// ---------------------------------------------------------------------------

/// Manages lookahead for predicates without exposing full input during parsing.
/// Dynamically accumulates characters in a buffer and caches predicate results.
/// Supports both synchronous (pre-loaded input) and async (streaming) usage.
class PredicateLookaheadBuffer {
  final List<int> _buffer = []; // Dynamic character buffer
  final Map<(int, String), bool> _predicateCache = {};

  /// Initialize buffer with a complete string (for synchronous parsing)
  void initializeFromString(String input) {
    _buffer.clear();
    _buffer.addAll(input.codeUnits);
  }

  /// Add a single character to the buffer (for streaming)
  void addCodeUnit(int codeUnit) {
    _buffer.add(codeUnit);
  }

  /// Add multiple characters to the buffer
  void addCodeUnits(List<int> codeUnits) {
    _buffer.addAll(codeUnits);
  }

  /// Get a character at position, or -1 if out of bounds
  int codeUnitAt(int position) {
    if (position < 0 || position >= _buffer.length) return -1;
    return _buffer[position];
  }

  /// Check if there are at least [length] characters available from [position]
  bool hasCharsAt(int position, int length) {
    return position >= 0 && position + length <= _buffer.length;
  }

  /// Get substring from [start] to [end], or empty string if out of bounds
  String getSubstring(int start, int end) {
    if (start < 0 || end > _buffer.length || start > end) return '';
    // Convert codeUnits to string
    return String.fromCharCodes(_buffer.sublist(start, end));
  }

  /// Total buffered characters
  int get length => _buffer.length;

  /// Clear the buffer (useful for resetting state)
  void clear() {
    _buffer.clear();
    _predicateCache.clear();
  }

  /// Cache a predicate result to avoid recomputation
  bool cachedPredicateCheck(int position, String patternKey, bool Function() evaluate) {
    final key = (position, patternKey);
    return _predicateCache.putIfAbsent(key, evaluate);
  }

  /// Clear the predicate cache (if needed)
  void clearCache() => _predicateCache.clear();
}

class SMParser {
  final StateMachine stateMachine;
  late final List<Frame> _initialFrames;
  late PredicateLookaheadBuffer _predicateBuffer;

  SMParser(GrammarInterface grammar) : stateMachine = StateMachine(grammar) {
    const initialContext = Context(RootCallerKey(), null);
    final initialFrame = Frame(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
    // Initialize buffer (can be reused across parses with clear())
    _predicateBuffer = PredicateLookaheadBuffer();
  }

  bool recognize(String input) {
    _predicateBuffer.initializeFromString(input);
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames);
      frames = stepResult.nextFrames;
      if (frames.isEmpty) return false;
      position++;
    }

    final lastStep = _processToken(null, position, frames);
    return lastStep.accept;
  }

  ParseOutcome<T> parse<T>(String input) {
    _predicateBuffer.initializeFromString(input);
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames);
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError<T>(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames);

    if (lastStep.accept) {
      return ParseSuccess<T>(ParserResult(lastStep.marks));
    } else {
      return ParseError<T>(position);
    }
  }

  /// Parse with forest extraction enabled.
  ///
  /// Internally uses BSR (Binarised Shared Representation) recorded during
  /// parsing to restrict the SPPF construction to spans proven reachable by
  /// the parser, rather than exhaustively searching the whole grammar.
  ParseOutcome<T> parseWithForest<T>(String input) {
    _predicateBuffer.initializeFromString(input);
    final bsrOutcome = parseToBsr(input);
    if (bsrOutcome is BsrParseError) {
      return ParseError<T>(bsrOutcome.position);
    }

    final bsrSuccess = bsrOutcome as BsrParseSuccess;
    final bsrSet = bsrSuccess.bsrSet;

    // Retrieve marks from a normal parse pass (recognise returns marks too).
    var frames = _initialFrames;
    int position = 0;
    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames, bsr: null);
      frames = stepResult.nextFrames;
      position++;
    }
    final lastStep = _processToken(null, position, frames, bsr: null);

    final startRule = stateMachine.grammar.startCall.rule;
    final nodeManager = ForestNodeManager();
    final root = bsrSet.buildSppf(startRule, input, nodeManager);
    final effectiveRoot = root ?? nodeManager.symbolic(0, input.length, startRule.name);
    final forest = ParseForest(nodeManager, effectiveRoot, lastStep.marks);
    return ParseForestSuccess<T>(forest);
  }

  /// Parse a stream of input chunks with forest extraction.
  ///
  /// Processes input incrementally as chunks arrive without buffering the entire
  /// stream in memory. Uses a bounded sliding-window buffer for predicate lookahead
  /// (default 1MB). Suitable for streaming large files.
  ///
  /// WARNING: If the grammar has predicates that require lookahead beyond the
  /// buffer window, results may be incorrect. Adjust [lookaheadWindowSize] if needed.
  Future<ParseOutcome<T>> parseWithForestAsync<T>(Stream<String> input,
      {int lookaheadWindowSize = 1048576}) {
    _predicateBuffer.clear();

    final completer = Completer<ParseOutcome<T>>();
    var frames = _initialFrames;
    int globalPosition = 0;

    // Bounded buffer for lookahead: prevents unbounded memory growth
    final lookaheadWindow = <int>[];

    // Keep all input for a second pass to get marks (required for correct SPPF construction)
    final allInput = <int>[];

    // BSR recording happens as we parse
    final bsr = BsrSet();

    input.listen(
      (chunk) {
        try {
          // Feed chunk data into the parser token-by-token
          for (final codeUnit in chunk.codeUnits) {
            // Store for second pass
            allInput.add(codeUnit);

            // Maintain bounded window: keep only recent data for lookahead
            lookaheadWindow.add(codeUnit);
            if (lookaheadWindow.length > lookaheadWindowSize) {
              lookaheadWindow.removeAt(0);
            }

            // Update the predicate buffer for this token
            _predicateBuffer._buffer.clear();
            _predicateBuffer._buffer.addAll(lookaheadWindow);

            // Process this token with BSR recording
            final stepResult = _processToken(codeUnit, globalPosition, frames, bsr: bsr);
            frames = stepResult.nextFrames;

            // If parsing fails, complete with error
            if (frames.isEmpty) {
              completer.complete(ParseError<T>(globalPosition));
              return;
            }

            globalPosition++;
          }
        } catch (e) {
          completer.completeError(e);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () {
        // Defer finalization to avoid blocking
        Future.microtask(() {
          try {
            if (completer.isCompleted) return;

            // Process end-of-stream token
            final lastStep = _processToken(null, globalPosition, frames, bsr: bsr);

            if (lastStep.accept) {
              // Now do a second pass over the buffered input to get marks
              // (matches the sync algorithm's approach)
              _predicateBuffer.initializeFromString(String.fromCharCodes(allInput));
              var marksFrames = _initialFrames;
              for (int i = 0; i < allInput.length; i++) {
                final stepResult = _processToken(allInput[i], i, marksFrames, bsr: null);
                marksFrames = stepResult.nextFrames;
              }
              final marksStep = _processToken(null, allInput.length, marksFrames, bsr: null);

              // Build SPPF from the recorded BSR
              final startRule = stateMachine.grammar.startCall.rule;
              final nodeManager = ForestNodeManager();
              final fullInput = String.fromCharCodes(allInput);
              final root = bsr.buildSppf(startRule, fullInput, nodeManager);
              final effectiveRoot = root ?? nodeManager.symbolic(0, globalPosition, startRule.name);
              final forest = ParseForest(nodeManager, effectiveRoot, marksStep.marks);
              completer.complete(ParseForestSuccess<T>(forest));
            } else {
              completer.complete(ParseError<T>(globalPosition));
            }
          } catch (e) {
            if (!completer.isCompleted) {
              completer.completeError(e);
            }
          }
        });
      },
    );

    return completer.future;
  }

  /// Parse with forest extraction using the direct grammar-walk approach.
  ///
  /// Builds the SPPF by exhaustively walking the grammar structure after
  /// parsing, without BSR pruning. Provided for performance
  /// comparison against [parseWithForest] (the BSR-backed variant).
  ParseOutcome<T> parseWithForestDirect<T>(String input) {
    _predicateBuffer.initializeFromString(input);
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames, bsr: null);
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError<T>(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames, bsr: null);

    if (lastStep.accept) {
      final startRule = stateMachine.grammar.startCall.rule;
      final nodeManager = ForestNodeManager();
      _buildForestNode(startRule, input, 0, input.length, nodeManager, {}, {});

      final root = nodeManager.symbolic(0, input.length, startRule.name);
      final forest = ParseForest(nodeManager, root, lastStep.marks);
      return ParseForestSuccess<T>(forest);
    } else {
      return ParseError<T>(position);
    }
  }

  /// Parse and return the BSR set of all proven rule-completion spans.
  ///
  /// Returns [BsrParseSuccess] with the [BsrSet] on success, or
  /// [BsrParseError] if the input does not conform to the grammar.
  BsrParseOutcome parseToBsr(String input) {
    _predicateBuffer.initializeFromString(input);
    final bsr = BsrSet();
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames, bsr: bsr);
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return BsrParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames, bsr: bsr);

    if (lastStep.accept) {
      return BsrParseSuccess(bsr);
    } else {
      return BsrParseError(position);
    }
  }

  /// Build SPPF nodes for a rule span, returning the SymbolicNode (or null if no derivation).
  SymbolicNode? _buildForestNode(
      Rule rule,
      String input,
      int start,
      int end,
      ForestNodeManager nodeManager,
      Map<String, SymbolicNode?> memo,
      Map<String, bool> inProgress) {
    final key = '${rule.name}:$start:$end';

    if (memo.containsKey(key)) return memo[key];
    if (inProgress[key] == true) return null; // Recursive call — treat as no derivation

    inProgress[key] = true;

    final symNode = nodeManager.symbolic(start, end, rule.name);
    // NOTE: memo is NOT set here — we set it only after families are built,
    // so that re-entrant calls via identity rules (e.g. Call(s)) return null
    // instead of a partially-constructed (and potentially cyclic) node.

    final childGroups =
        _patternChildGroups(rule.body(), input, start, end, nodeManager, memo, inProgress);
    for (final children in childGroups) {
      symNode.addFamily(Family(children));
    }

    inProgress[key] = false;
    final result = symNode.families.isNotEmpty ? symNode : null;
    memo[key] = result; // Cache the final result (null if no valid derivation)
    return result;
  }

  /// Returns all possible lists of child [ForestNode]s that [pattern] can produce
  /// over [start]..[end]. Each entry represents one alternative derivation's flat
  /// child list. An empty returned list means no derivation exists.
  List<List<ForestNode>> _patternChildGroups(
      Pattern pattern,
      String input,
      int start,
      int end,
      ForestNodeManager nodeManager,
      Map<String, SymbolicNode?> memo,
      Map<String, bool> inProgress) {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        final termNode = nodeManager.terminal(start, end, input.codeUnitAt(start));
        return [
          [termNode]
        ];
      }
      return [];
    }

    if (pattern is Eps) {
      if (start == end) {
        return [[]]; // epsilon: one derivation with no children
      }
      return [];
    }

    if (pattern is Marker) {
      if (start == end) {
        return [
          [nodeManager.marker(start, pattern.name)]
        ];
      }
      return [];
    }

    if (pattern is Alt) {
      // Union: collect derivations from both alternatives
      final leftGroups =
          _patternChildGroups(pattern.left, input, start, end, nodeManager, memo, inProgress);
      final rightGroups =
          _patternChildGroups(pattern.right, input, start, end, nodeManager, memo, inProgress);
      return [...leftGroups, ...rightGroups];
    }

    if (pattern is Seq) {
      final result = <List<ForestNode>>[];
      for (int mid = start; mid <= end; mid++) {
        final leftGroups =
            _patternChildGroups(pattern.left, input, start, mid, nodeManager, memo, inProgress);
        if (leftGroups.isEmpty) continue;

        final rightGroups =
            _patternChildGroups(pattern.right, input, mid, end, nodeManager, memo, inProgress);
        if (rightGroups.isEmpty) continue;

        // Cartesian product: concatenate each pair of left/right child-lists
        for (final leftChildren in leftGroups) {
          for (final rightChildren in rightGroups) {
            result.add([...leftChildren, ...rightChildren]);
          }
        }
      }
      return result;
    }

    if (pattern is Call) {
      final child =
          _buildForestNode(pattern.rule, input, start, end, nodeManager, memo, inProgress);
      return child != null
          ? [
              [child]
            ]
          : [];
    }

    if (pattern is RuleCall) {
      final child =
          _buildForestNode(pattern.rule, input, start, end, nodeManager, memo, inProgress);
      return child != null
          ? [
              [child]
            ]
          : [];
    }

    if (pattern is Action) {
      return _patternChildGroups(pattern.child, input, start, end, nodeManager, memo, inProgress);
    }

    return [];
  }

  /// Count all possible parse trees without building them
  int countAllParses(String input) {
    final startRule = stateMachine.grammar.startCall.rule;
    return _countDerivations(startRule, input, 0, input.length, {}, {});
  }

  /// Enumerate all possible parse trees lazily, yielding each as a [ParseDerivation].
  Iterable<ParseDerivation> enumerateAllParses(String input) {
    final startRule = stateMachine.grammar.startCall.rule;
    return _enumerateDerivations(startRule, input, 0, input.length, {}, {});
  }

  /// Enumerate all possible parse trees with evaluated semantic values.
  /// Actions are executed bottom-up with child results.
  Iterable<ParseDerivationWithValue<dynamic>> enumerateAllParsesWithResults(String input) {
    final startRule = stateMachine.grammar.startCall.rule;
    return _enumerateDerivationsWithResults(startRule, input, 0, input.length, input, {}, {});
  }

  /// Extract all parse trees from a [ParseForest] with evaluated semantic actions.
  /// This provides a forest-based alternative to [enumerateAllParsesWithResults],
  /// yielding [ParseDerivationWithValue] results with top-level semantic values.
  ///
  /// The forest should come from [parseWithForest] on matching input.
  Iterable<ParseDerivationWithValue<dynamic>> enumerateForestWithResults(
    ParseForestSuccess forest,
    String input,
  ) sync* {
    final startRule = stateMachine.grammar.startCall.rule;
    for (final tree in forest.forest.extract()) {
      final value = _evaluateParseTree(tree, startRule, input);
      // Reconstruct a ParseDerivation from the ParseTree for compatibility
      final derivation = _parseTreeToDerivation(tree, input);
      yield ParseDerivationWithValue(derivation, value);
    }
  }

  /// Convert a [ParseTree] (forest representation) to a [ParseDerivation] (enumeration representation).
  ParseDerivation _parseTreeToDerivation(ParseTree tree, String input) {
    String nodeLabel = '';
    if (tree.node is SymbolicNode) {
      nodeLabel = (tree.node as SymbolicNode).symbol;
    } else if (tree.node is TerminalNode) {
      final terminal = tree.node as TerminalNode;
      nodeLabel = String.fromCharCode(terminal.token);
    } else if (tree.node is MarkerNode) {
      nodeLabel = 'Mark\$${(tree.node as MarkerNode).name}';
    } else if (tree.node is EpsilonNode) {
      nodeLabel = 'ε';
    } else {
      nodeLabel = tree.node.toString();
    }

    final childDerivations = tree.children.map((c) => _parseTreeToDerivation(c, input)).toList();
    return ParseDerivation(nodeLabel, tree.node.start, tree.node.end, childDerivations);
  }

  /// Evaluate a [ParseTree] extracted from the forest, executing semantic actions.
  /// Returns the semantic value computed bottom-up from the tree.
  dynamic _evaluateParseTree(ParseTree tree, Rule rule, String input) {
    // Recursively evaluate children first
    final childValues = <dynamic>[];
    for (final child in tree.children) {
      childValues.add(_evaluateParseTreeNode(child, rule, input));
    }

    // Look for semantic action attached to this rule for this span
    final action = _findActionInRule(rule, tree.node.start, tree.node.end, input);
    if (action != null) {
      final span = input.substring(tree.node.start, tree.node.end);
      return action.callback(span, childValues);
    }

    // No action - return the first child value or unit
    if (childValues.isNotEmpty) {
      return childValues.length == 1 ? childValues[0] : childValues;
    }
    return null;
  }

  /// Evaluate a forest node contextually.
  dynamic _evaluateParseTreeNode(ParseTree tree, Rule contextRule, String input) {
    // For symbolic nodes, find their corresponding rule
    if (tree.node is SymbolicNode) {
      final symNode = tree.node as SymbolicNode;
      // Try to find a rule matching this symbol
      final matchingRule = _findRuleByName(symNode.symbol);
      if (matchingRule != null) {
        return _evaluateParseTree(tree, matchingRule, input);
      }
    }

    // Otherwise, evaluate generically
    final childValues =
        tree.children.map((c) => _evaluateParseTreeNode(c, contextRule, input)).toList();
    return childValues.isNotEmpty ? (childValues.length == 1 ? childValues[0] : childValues) : null;
  }

  /// Find a rule by name from the grammar.
  Rule? _findRuleByName(String name) {
    try {
      // Attempt to find rule by name - this is a linear search;
      // for efficiency, you may want to cache rule lookups
      final startRule = stateMachine.grammar.startCall.rule;
      return _searchRuleByName(startRule, name, <Rule>{});
    } catch (_) {
      return null;
    }
  }

  /// Recursively search for a rule by name, avoiding cycles.
  Rule? _searchRuleByName(Rule current, String targetName, Set<Rule> visited) {
    if (visited.contains(current)) return null;
    visited.add(current);

    if (current.name == targetName) return current;

    // Collect all referenced rules from the rule body
    final referencedRules = <Rule>{};
    current.body().collectRules(referencedRules);

    for (final rule in referencedRules) {
      final found = _searchRuleByName(rule, targetName, visited);
      if (found != null) return found;
    }

    return null;
  }

  /// Find a semantic action attached to a rule that applies to the given span.
  Action? _findActionInRule(Rule rule, int start, int end, String input) {
    // Walk the rule body looking for Action nodes
    return _findActionInPattern(rule.body());
  }

  /// Recursively find the first Action node in a pattern.
  Action? _findActionInPattern(Pattern pattern) {
    if (pattern is Action) {
      return pattern;
    }

    if (pattern is Alt) {
      var result = _findActionInPattern(pattern.left);
      if (result != null) return result;
      return _findActionInPattern(pattern.right);
    }

    if (pattern is Seq) {
      var result = _findActionInPattern(pattern.left);
      if (result != null) return result;
      return _findActionInPattern(pattern.right);
    }

    if (pattern is Plus) {
      return _findActionInPattern(pattern.child);
    }

    if (pattern is Call) {
      return _findActionInPattern(pattern.rule.body());
    }

    if (pattern is RuleCall) {
      return _findActionInPattern(pattern.rule.body());
    }

    return null;
  }

  int _countDerivations(Rule rule, String input, int start, int end, Map<String, int> memo,
      Map<String, bool> inProgress) {
    final key = '${rule.name}:$start:$end';

    if (memo.containsKey(key)) {
      return memo[key]!;
    }

    // Check for cycle - if we're already processing this rule at this span, break the cycle
    if (inProgress[key] == true) {
      return 0; // Prevent infinite recursion on identity rules
    }

    if (start == end) {
      try {
        final isEmpty = rule.body().empty();
        final result = isEmpty ? 1 : 0;
        memo[key] = result;
        return result;
      } catch (_) {
        memo[key] = 0;
        return 0;
      }
    }

    inProgress[key] = true;
    int totalCount = _countAlternatives(rule.body(), input, start, end, memo, inProgress);
    inProgress[key] = false;
    memo[key] = totalCount;
    return totalCount;
  }

  int _countAlternatives(Pattern pattern, String input, int start, int end, Map<String, int> memo,
      Map<String, bool> inProgress) {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        return 1;
      }
      return 0;
    }

    if (pattern is Eps) {
      return start == end ? 1 : 0;
    }

    if (pattern is Marker) {
      return _countAlternatives(Eps(), input, start, end, memo, inProgress);
    }

    if (pattern is Alt) {
      return _countAlternatives(pattern.left, input, start, end, memo, inProgress) +
          _countAlternatives(pattern.right, input, start, end, memo, inProgress);
    }

    if (pattern is Seq) {
      int totalCount = 0;
      // Try all split points
      for (int mid = start; mid <= end; mid++) {
        final leftCount = _countAlternatives(pattern.left, input, start, mid, memo, inProgress);
        if (leftCount > 0) {
          final rightCount = _countAlternatives(pattern.right, input, mid, end, memo, inProgress);
          totalCount += leftCount * rightCount;
        }
      }
      return totalCount;
    }

    if (pattern is Plus) {
      // At least one match
      int totalCount = 0;
      for (int mid = start + 1; mid <= end; mid++) {
        final childCount = _countAlternatives(pattern.child, input, start, mid, memo, inProgress);
        if (childCount > 0) {
          final starCount = _countStar(pattern.child, input, mid, end, memo, inProgress);
          totalCount += childCount * starCount;
        }
      }
      return totalCount;
    }

    if (pattern is Call) {
      return _countDerivations(pattern.rule, input, start, end, memo, inProgress);
    }

    if (pattern is RuleCall) {
      return _countDerivations(pattern.rule, input, start, end, memo, inProgress);
    }

    if (pattern is Action) {
      // Action wraps another pattern - just delegate to unwrapped pattern
      return _countAlternatives(pattern.child, input, start, end, memo, inProgress);
    }

    return 0;
  }

  // Count zero or more matches of a pattern
  int _countStar(Pattern pattern, String input, int start, int end, Map<String, int> memo,
      Map<String, bool> inProgress) {
    if (start == end) {
      return 1; // Zero matches
    }

    int totalCount = 1; // Zero matches at current position

    // One or more matches
    for (int mid = start + 1; mid <= end; mid++) {
      final childCount = _countAlternatives(pattern, input, start, mid, memo, inProgress);
      if (childCount > 0) {
        final restCount = _countStar(pattern, input, mid, end, memo, inProgress);
        totalCount += childCount * restCount;
      }
    }

    return totalCount;
  }

  Iterable<ParseDerivation> _enumerateDerivations(
    Rule rule,
    String input,
    int start,
    int end,
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress,
  ) sync* {
    final key = '${rule.name}:$start:$end';

    // If we've already computed this span, replay from cache
    if (memo.containsKey(key)) {
      yield* memo[key] ?? const [];
      return;
    }

    // Cycle guard — identity rules like Call(s) at the same span return nothing
    if (inProgress[key] == true) return;

    if (start == end) {
      try {
        if (rule.body().empty()) {
          final d = ParseDerivation(rule.name, start, end, []);
          memo[key] = [d];
          yield d;
        } else {
          memo[key] = [];
        }
      } catch (_) {
        memo[key] = [];
      }
      return;
    }

    inProgress[key] = true;
    final cache = <ParseDerivation>[];
    for (final d
        in _enumerateAlternatives(rule.body(), input, start, end, rule.name, memo, inProgress)) {
      cache.add(d);
      yield d;
    }
    inProgress[key] = false;
    memo[key] = cache;
  }

  Iterable<ParseDerivation> _enumerateAlternatives(
      Pattern pattern,
      String input,
      int start,
      int end,
      String symbol,
      Map<String, List<ParseDerivation>?> memo,
      Map<String, bool> inProgress) sync* {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        yield ParseDerivation(symbol, start, end,
            [ParseDerivation(String.fromCharCode(input.codeUnitAt(start)), start, end, [])]);
      }
      return;
    }

    if (pattern is Eps) {
      if (start == end) yield ParseDerivation(symbol, start, end, []);
      return;
    }

    if (pattern is Marker) {
      if (start == end) yield ParseDerivation('Mark(\${pattern.name})', start, end, []);
      return;
    }

    if (pattern is Alt) {
      yield* _enumerateAlternatives(pattern.left, input, start, end, symbol, memo, inProgress);
      yield* _enumerateAlternatives(pattern.right, input, start, end, symbol, memo, inProgress);
      return;
    }

    if (pattern is Seq) {
      // CFG sequence: enumerate ALL splits where both left and right match
      for (int mid = start; mid <= end; mid++) {
        final leftList = _enumerateAlternatives(
                pattern.left, input, start, mid, '${pattern.left}', memo, inProgress)
            .toList();
        if (leftList.isEmpty) continue;

        final rightList = _enumerateAlternatives(
                pattern.right, input, mid, end, '${pattern.right}', memo, inProgress)
            .toList();
        if (rightList.isEmpty) continue;

        for (final left in leftList) {
          for (final right in rightList) {
            yield ParseDerivation(symbol, start, end, [left, right]);
          }
        }
      }
      return;
    }

    if (pattern is Plus) {
      for (int mid = start + 1; mid <= end; mid++) {
        final childList = _enumerateAlternatives(
                pattern.child, input, start, mid, '${pattern.child}', memo, inProgress)
            .toList();
        if (childList.isEmpty) continue;
        for (final child in childList) {
          for (final star in _enumerateStar(
              pattern.child, input, mid, end, '${pattern.child}*', memo, inProgress)) {
            // Only yield if plus covers the full requested span
            if (star.end == end) {
              yield ParseDerivation(symbol, start, end, [child, star]);
            }
          }
        }
      }
      return;
    }

    if (pattern is Call) {
      yield* _enumerateDerivations(pattern.rule, input, start, end, memo, inProgress);
      return;
    }

    if (pattern is RuleCall) {
      yield* _enumerateDerivations(pattern.rule, input, start, end, memo, inProgress);
      return;
    }

    if (pattern is Action) {
      yield* _enumerateAlternatives(pattern.child, input, start, end, symbol, memo, inProgress);
      return;
    }

    if (pattern is And) {
      // Positive lookahead: check if pattern matches at start position without consuming
      if (_checkPredicatePattern(pattern.pattern, start)) {
        // Predicate succeeded - yield empty derivation (zero-width match)
        yield ParseDerivation(symbol, start, start, []);
      }
      return;
    }

    if (pattern is Not) {
      // Negative lookahead: check if pattern does NOT match at start position
      if (!_checkPredicatePattern(pattern.pattern, start)) {
        // Predicate succeeded - yield empty derivation (zero-width match)
        yield ParseDerivation(symbol, start, start, []);
      }
      return;
    }
  }

  Iterable<ParseDerivation> _enumerateStar(Pattern pattern, String input, int start, int end,
      String symbol, Map<String, List<ParseDerivation>?> memo, Map<String, bool> inProgress) sync* {
    if (start == end) {
      yield ParseDerivation(symbol, start, end, []);
      return;
    }

    // PEG greedy matching: try longest match first
    for (int mid = end; mid > start; mid--) {
      final childList =
          _enumerateAlternatives(pattern, input, start, mid, '$pattern', memo, inProgress).toList();
      if (childList.isNotEmpty) {
        for (final child in childList) {
          for (final star in _enumerateStar(pattern, input, mid, end, symbol, memo, inProgress)) {
            // Use the actual end position from the star tree, not the requested 'end'
            final actualEnd = star.end;
            yield ParseDerivation(symbol, start, actualEnd, [child, star]);
          }
        }
        return; // Only use the first (longest) match - PEG greedy semantics
      }
    }

    // No match found - zero matches
    yield ParseDerivation(symbol, start, start, []);
  }

  /// Enumerate all derivations with evaluated semantic values
  Iterable<ParseDerivationWithValue<dynamic>> _enumerateDerivationsWithResults(
      Rule rule,
      String input,
      int start,
      int end,
      String fullInput,
      Map<String, List<ParseDerivationWithValue<dynamic>>?> memo,
      Map<String, bool> inProgress) sync* {
    final key = '${rule.name}:$start:$end';

    if (memo.containsKey(key)) {
      yield* memo[key] ?? const [];
      return;
    }

    if (inProgress[key] == true) return;

    if (start == end) {
      try {
        if (rule.body().empty()) {
          final d = ParseDerivation(rule.name, start, end, []);
          final evaluated = _evaluatePattern(rule.body(), d, fullInput);
          final withValue = ParseDerivationWithValue(d, evaluated);
          memo[key] = [withValue];
          yield withValue;
        } else {
          memo[key] = [];
        }
      } catch (_) {
        memo[key] = [];
      }
      return;
    }

    inProgress[key] = true;
    final cache = <ParseDerivationWithValue<dynamic>>[];
    for (final d in _enumerateAlternativesWithResults(
        rule.body(), input, start, end, rule.name, fullInput, memo, inProgress)) {
      cache.add(d);
      yield d;
    }
    inProgress[key] = false;
    memo[key] = cache;
  }

  /// Enumerate alternatives with evaluated results
  Iterable<ParseDerivationWithValue<dynamic>> _enumerateAlternativesWithResults(
      Pattern pattern,
      String input,
      int start,
      int end,
      String symbol,
      String fullInput,
      Map<String, List<ParseDerivationWithValue<dynamic>>?> memo,
      Map<String, bool> inProgress) sync* {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        final tree = ParseDerivation(symbol, start, end,
            [ParseDerivation(String.fromCharCode(input.codeUnitAt(start)), start, end, [])]);
        final evaluated = _evaluatePattern(pattern, tree, fullInput);
        yield ParseDerivationWithValue(tree, evaluated);
      }
      return;
    }

    if (pattern is Eps) {
      if (start == end) {
        final tree = ParseDerivation(symbol, start, end, []);
        final evaluated = _evaluatePattern(pattern, tree, fullInput);
        yield ParseDerivationWithValue(tree, evaluated);
      }
      return;
    }

    if (pattern is Marker) {
      if (start == end) {
        final tree = ParseDerivation('Mark(\${pattern.name})', start, end, []);
        final evaluated = _evaluatePattern(pattern, tree, fullInput);
        yield ParseDerivationWithValue(tree, evaluated);
      }
      return;
    }

    if (pattern is Alt) {
      yield* _enumerateAlternativesWithResults(
          pattern.left, input, start, end, symbol, fullInput, memo, inProgress);
      yield* _enumerateAlternativesWithResults(
          pattern.right, input, start, end, symbol, fullInput, memo, inProgress);
      return;
    }

    if (pattern is Seq) {
      for (int mid = start; mid <= end; mid++) {
        final leftList = _enumerateAlternativesWithResults(
                pattern.left, input, start, mid, '${pattern.left}', fullInput, memo, inProgress)
            .toList();
        if (leftList.isEmpty) continue;

        final rightList = _enumerateAlternativesWithResults(
                pattern.right, input, mid, end, '${pattern.right}', fullInput, memo, inProgress)
            .toList();
        if (rightList.isEmpty) continue;

        for (final left in leftList) {
          for (final right in rightList) {
            final tree = ParseDerivation(symbol, start, end, [left.tree, right.tree]);
            final evaluated =
                _evaluatePattern(pattern, tree, fullInput, childResults: [left.value, right.value]);
            yield ParseDerivationWithValue(tree, evaluated);
          }
        }
      }
      return;
    }

    if (pattern is Plus) {
      for (int mid = start + 1; mid <= end; mid++) {
        final childList = _enumerateAlternativesWithResults(
                pattern.child, input, start, mid, '${pattern.child}', fullInput, memo, inProgress)
            .toList();
        if (childList.isEmpty) continue;
        for (final child in childList) {
          for (final star in _enumerateStarWithResults(
              pattern.child, input, mid, end, '${pattern.child}*', fullInput, memo, inProgress)) {
            // Only yield if plus covers the full requested span
            if (star.tree.end == end) {
              final tree = ParseDerivation(symbol, start, end, [child.tree, star.tree]);
              final evaluated = _evaluatePattern(pattern, tree, fullInput,
                  childResults: [child.value, star.value]);
              yield ParseDerivationWithValue(tree, evaluated);
            }
          }
        }
      }
      return;
    }

    if (pattern is Call) {
      yield* _enumerateDerivationsWithResults(
          pattern.rule, input, start, end, fullInput, memo, inProgress);
      return;
    }

    if (pattern is RuleCall) {
      yield* _enumerateDerivationsWithResults(
          pattern.rule, input, start, end, fullInput, memo, inProgress);
      return;
    }

    if (pattern is Action) {
      // Evaluate the child first, then apply the action
      for (final childResult in _enumerateAlternativesWithResults(
          pattern.child, input, start, end, symbol, fullInput, memo, inProgress)) {
        // Execute the action with the full span and the evaluated child value
        final span = fullInput.substring(start, end);
        final actionValue = pattern.callback(
            span, childResult.value is List ? childResult.value : [childResult.value]);
        yield ParseDerivationWithValue(childResult.tree, actionValue);
      }
      return;
    }

    if (pattern is And) {
      // Positive lookahead: check if pattern matches at start position without consuming
      if (_checkPredicatePattern(pattern.pattern, start)) {
        // Predicate succeeded - yield empty derivation (zero-width match)
        final tree = ParseDerivation(symbol, start, start, []);
        final evaluated = _evaluatePattern(pattern, tree, fullInput);
        yield ParseDerivationWithValue(tree, evaluated);
      }
      return;
    }

    if (pattern is Not) {
      // Negative lookahead: check if pattern does NOT match at start position
      if (!_checkPredicatePattern(pattern.pattern, start)) {
        // Predicate succeeded - yield empty derivation (zero-width match)
        final tree = ParseDerivation(symbol, start, start, []);
        final evaluated = _evaluatePattern(pattern, tree, fullInput);
        yield ParseDerivationWithValue(tree, evaluated);
      }
      return;
    }
  }

  /// Enumerate star with results
  Iterable<ParseDerivationWithValue<dynamic>> _enumerateStarWithResults(
      Pattern pattern,
      String input,
      int start,
      int end,
      String symbol,
      String fullInput,
      Map<String, List<ParseDerivationWithValue<dynamic>>?> memo,
      Map<String, bool> inProgress) sync* {
    if (start == end) {
      final tree = ParseDerivation(symbol, start, end, []);
      final evaluated = _evaluatePattern(pattern, tree, fullInput);
      yield ParseDerivationWithValue(tree, evaluated);
      return;
    }

    // PEG greedy matching: try longest match first
    for (int mid = end; mid > start; mid--) {
      final childList = _enumerateAlternativesWithResults(
              pattern, input, start, mid, '$pattern', fullInput, memo, inProgress)
          .toList();
      if (childList.isNotEmpty) {
        for (final child in childList) {
          for (final star in _enumerateStarWithResults(
              pattern, input, mid, end, symbol, fullInput, memo, inProgress)) {
            // Use the actual end position from the star tree, not the requested 'end'
            final actualEnd = star.tree.end;
            final tree = ParseDerivation(symbol, start, actualEnd, [child.tree, star.tree]);
            final evaluated =
                _evaluatePattern(pattern, tree, fullInput, childResults: [child.value, star.value]);
            yield ParseDerivationWithValue(tree, evaluated);
          }
        }
        return; // Only use the first (longest) match - PEG greedy semantics
      }
    }

    // No match found - zero matches
    final tree = ParseDerivation(symbol, start, start, []);
    final evaluated = _evaluatePattern(pattern, tree, fullInput);
    yield ParseDerivationWithValue(tree, evaluated);
  }

  /// Evaluate a pattern, executing actions bottom-up
  dynamic _evaluatePattern(Pattern pattern, ParseDerivation tree, String input,
      {List<dynamic> childResults = const []}) {
    if (pattern is Action<dynamic>) {
      // Execute action with span and child results
      final span = input.substring(tree.start, tree.end);
      return pattern.callback(span, childResults);
    }

    if (pattern is Token) {
      return tree.getMatchedText(input);
    }

    if (pattern is Eps) {
      return null;
    }

    if (pattern is Marker) {
      return NamedMark(pattern.name, tree.start);
    }

    if (pattern is Alt) {
      // Find which child matched and evaluate it
      if (tree.children.isNotEmpty) {
        final childTree = tree.children[0];
        // Determine which alternative matched
        if (pattern.left.toString() == childTree.symbol ||
            _patternMatches(pattern.left, childTree)) {
          return _evaluatePattern(pattern.left, childTree, input);
        } else {
          return _evaluatePattern(pattern.right, childTree, input);
        }
      }
      return null;
    }

    if (pattern is Seq) {
      // Already evaluated children passed in
      return childResults;
    }

    if (pattern is Plus) {
      return childResults;
    }

    if (pattern is Call || pattern is RuleCall) {
      if (childResults.isNotEmpty) {
        return childResults[0];
      }
      return null;
    }

    return null;
  }

  /// Check if a pattern matches a tree's symbol
  bool _patternMatches(Pattern pattern, ParseDerivation tree) {
    if (pattern is Token) {
      return tree.symbol.length == 1; // Single character token
    }
    if (pattern is Call || pattern is RuleCall) {
      if (pattern is Call) {
        return tree.symbol == pattern.rule.name;
      } else if (pattern is RuleCall) {
        return tree.symbol == pattern.rule.name;
      }
    }
    return false;
  }

  Step _processToken(int? token, int position, List<Frame> frames, {BsrSet? bsr}) {
    final step = Step(this, token, position, bsr: bsr, buffer: _predicateBuffer);

    for (final frame in frames) {
      step._processFrame(frame);
    }

    return step;
  }

  /// Check if a pattern matches at a given position in the input without consuming.
  /// Used for AND/NOT lookahead predicates.
  ///
  /// This is a fast check that determines if a pattern would match at startPos
  /// without actually advancing the parser state.
  bool checkPatternAtPosition(Pattern pattern, String input, int startPos) {
    _predicateBuffer.initializeFromString(input);
    return _checkPredicatePattern(pattern, startPos);
  }

  /// Internal: recursive predicate pattern checking (uses buffer stored on parser)
  bool _checkPredicatePattern(Pattern pattern, int startPos) {
    // Base cases
    if (pattern is Token) {
      final codeUnit = _predicateBuffer.codeUnitAt(startPos);
      if (codeUnit >= 0) {
        return pattern.match(codeUnit);
      }
      return false;
    }

    if (pattern is Eps) {
      return true;
    }

    if (pattern is Marker) {
      return true;
    }

    if (pattern is Alt) {
      return _checkPredicatePattern(pattern.left, startPos) ||
          _checkPredicatePattern(pattern.right, startPos);
    }

    if (pattern is Seq) {
      return _checkPredicateSeq(pattern.left, pattern.right, startPos);
    }

    if (pattern is Plus) {
      return _checkPredicatePattern(pattern.child, startPos);
    }

    if (pattern is And) {
      return _checkPredicatePattern(pattern.pattern, startPos);
    }

    if (pattern is Not) {
      return !_checkPredicatePattern(pattern.pattern, startPos);
    }

    if (pattern is Call || pattern is RuleCall) {
      Rule rule = pattern is Call ? pattern.rule : (pattern as RuleCall).rule;
      return _ruleMatchesAtPosition(rule, startPos);
    }

    if (pattern is Action) {
      return _checkPredicatePattern(pattern.child, startPos);
    }

    // Default: assume matches
    return true;
  }

  /// Check if a sequence matches: left followed by right
  bool _checkPredicateSeq(Pattern left, Pattern right, int startPos) {
    // Determine how much 'left' consumes
    final leftLen = _estimatePatternLength(left, startPos);
    if (leftLen < 0) return false;
    return _checkPredicatePattern(right, startPos + leftLen);
  }

  /// Estimate how many characters a pattern would match.
  /// Returns >= 0 if matches, < 0 if doesn't match.
  int _estimatePatternLength(Pattern pattern, int startPos) {
    if (startPos > _predicateBuffer.length) return -1;

    if (pattern is Token) {
      if (_checkPredicatePattern(pattern, startPos)) {
        return 1;
      }
      return -1;
    }

    if (pattern is Eps) {
      return 0;
    }

    if (pattern is Marker) {
      return 0;
    }

    if (pattern is Alt) {
      int leftLen = _estimatePatternLength(pattern.left, startPos);
      if (leftLen >= 0) return leftLen;
      return _estimatePatternLength(pattern.right, startPos);
    }

    if (pattern is Plus) {
      return _estimatePatternLength(pattern.child, startPos);
    }

    if (pattern is And || pattern is Not) {
      // Predicates are zero-width
      return 0;
    }

    if (pattern is Call || pattern is RuleCall) {
      // For rules, we don't know the length - be conservative
      // A better implementation would parse to determine length
      return 0;
    }

    if (pattern is Action) {
      return _estimatePatternLength(pattern.child, startPos);
    }

    // Default: unknown
    return -1;
  }

  /// Check if a rule's body matches at the given position
  bool _ruleMatchesAtPosition(Rule rule, int startPos) {
    if (startPos >= _predicateBuffer.length && !rule.body().empty()) {
      return false;
    }

    // Check if the rule body can match from startPos to any end position
    try {
      // Try to find at least one valid match
      for (int endPos = startPos; endPos <= _predicateBuffer.length; endPos++) {
        if (_patternCanMatch(rule.body(), startPos, endPos)) {
          return true;
        }
      }
      return false;
    } catch (_) {
      // If anything goes wrong, be conservative
      return true;
    }
  }

  /// Check if a pattern can match the span [start, end)
  bool _patternCanMatch(Pattern pattern, int start, int end) {
    if (pattern is Token) {
      return start + 1 == end && pattern.match(_predicateBuffer.codeUnitAt(start));
    }

    if (pattern is Eps) {
      return start == end;
    }

    if (pattern is Marker) {
      return start == end;
    }

    if (pattern is Alt) {
      return _patternCanMatch(pattern.left, start, end) ||
          _patternCanMatch(pattern.right, start, end);
    }

    if (pattern is Seq) {
      // Try all split points
      for (int mid = start; mid <= end; mid++) {
        if (_patternCanMatch(pattern.left, start, mid) &&
            _patternCanMatch(pattern.right, mid, end)) {
          return true;
        }
      }
      return false;
    }

    if (pattern is Plus) {
      // At least one match
      if (start == end) return false;
      for (int mid = start + 1; mid <= end; mid++) {
        if (_patternCanMatch(pattern.child, start, mid)) {
          // Check if rest can be matched by zero or more
          if (mid == end || _patternCanMatchStar(pattern.child, mid, end)) {
            return true;
          }
        }
      }
      return false;
    }

    if (pattern is And || pattern is Not) {
      return start == end;
    }

    if (pattern is Call || pattern is RuleCall) {
      Rule rule = pattern is Call ? pattern.rule : (pattern as RuleCall).rule;
      return _patternCanMatch(rule.body(), start, end);
    }

    if (pattern is Action) {
      return _patternCanMatch(pattern.child, start, end);
    }

    return false;
  }

  /// Check if a pattern can match zero or more times in the span [start, end)
  bool _patternCanMatchStar(Pattern pattern, int start, int end) {
    if (start == end) return true; // Zero matches

    // Try one match
    for (int mid = start + 1; mid <= end; mid++) {
      if (_patternCanMatch(pattern, start, mid) && _patternCanMatchStar(pattern, mid, end)) {
        return true;
      }
    }

    return false;
  }
}

// ---------------------------------------------------------------------------
// Internal parsing machinery
// ---------------------------------------------------------------------------

/// Strongly typed key to identify a call site.
sealed class CallerKey {
  const CallerKey();
}

/// Represents the root call context.
final class RootCallerKey extends CallerKey {
  const RootCallerKey();

  @override
  int get hashCode => 0;

  @override
  bool operator ==(Object other) => other is RootCallerKey;
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
class Context {
  final CallerKey caller;
  final GlushList<Mark>? marks;

  /// The input position at which the rule associated with this context
  /// was invoked.  Used to record BSR rule-completion entries.
  final int? callStart;

  const Context(this.caller, this.marks, [this.callStart]);
}

/// Frame for managing parsing states
class Frame {
  final Context context;
  final Set<State> nextStates = {};

  Frame(this.context);

  Frame copy() => Frame(context);

  CallerKey get caller => context.caller;
  GlushList<Mark>? get marks => context.marks;
}

/// Caller tracking for rule returns
class Caller extends CallerKey {
  /// Key is a (caller, nextState) pair encoded as a two-element list.
  final Map<(CallerKey, State), List<GlushList<Mark>?>> _grouped = {};

  /// The input position at which the associated rule was invoked.
  /// Set once at CallAction time; used by ReturnAction to record BSR entries.
  int? callStart;

  void addReturn(Context context, State nextState) {
    final key = (context.caller, nextState);
    _grouped.putIfAbsent(key, () => []).add(context.marks);
  }

  void forEach(void Function(CallerKey, State, GlushList<Mark>?) callback) {
    for (final MapEntry(key: (caller, nextState), value: marks) in _grouped.entries) {
      for (final mark in marks) {
        callback(caller, nextState, mark);
      }
    }
  }
}

/// Single step in parsing
class Step {
  final SMParser parser;
  final int? token;
  final int position;

  /// Optional BSR set to populate with rule-completion entries. When null,
  /// BSR recording is skipped (used by the plain recognize/parse paths).
  final BsrSet? bsr;

  /// Predicate lookahead buffer for checking patterns without full input access
  final PredicateLookaheadBuffer buffer;

  final List<Frame> nextFrames = [];
  final Map<Rule, Caller> _callers = {};
  final Set<CallerKey> _returnedCallers = {};
  final List<Context> _acceptedContexts = [];

  Step(this.parser, this.token, this.position, {this.bsr, required this.buffer});

  bool get accept => _acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    final markList = _acceptedContexts[0].marks;
    if (markList == null) return [];
    return markList.toList().cast<Mark>();
  }

  void _withFrame(Context context, void Function(Frame) callback) {
    final frame = Frame(context);
    callback(frame);
    if (frame.nextStates.isNotEmpty) {
      nextFrames.add(frame);
    }
  }

  void _process(Frame frame, State state) {
    for (final action in state.actions) {
      if (action is TokenAction) {
        if (action.pattern.match(token)) {
          // If token matches, add a StringMark with the captured token if not ExactToken
          // So ranges and 'any' tokens are captured into the marks array too
          var newMarks = frame.marks;
          if (token != null && action.pattern is Token && (action.pattern as Token).choice is! ExactToken) {
            final strMark = StringMark(String.fromCharCode(token!), position);
            newMarks = (newMarks ?? GlushList.empty<Mark>()).add(strMark);
          }
          final nextFrame = Frame(Context(frame.caller, newMarks));
          nextFrame.nextStates.add(action.nextState);
          nextFrames.add(nextFrame);
        }
      } else if (action is MarkAction) {
        final mark = NamedMark(action.name, position);
        final markCtx = Context(
          frame.caller,
          (frame.marks ?? GlushList.empty<Mark>()).add(mark),
        );
        _withFrame(markCtx, (markFrame) {
          _process(markFrame, action.nextState);
        });
      } else if (action is PredicateAction) {
        // Predicate checking (lookahead without consumption)
        // Buffer ensures we have the data needed for lookahead
        bool predicateMatches = parser._checkPredicatePattern(action.pattern, position);

        // For AND (&pattern), continue if pattern matches
        // For NOT (!pattern), continue if pattern does NOT match
        final shouldContinue = action.isAnd ? predicateMatches : !predicateMatches;

        if (shouldContinue) {
          // Predicate succeeded - process next state through standard frame mechanism
          // Zero-width: processed with the same token in this frame step
          _withFrame(frame.context, (predFrame) {
            _process(predFrame, action.nextState);
          });
        }
        // If predicate failed, we simply don't add the next state (backtrack)
      } else if (action is CallAction) {
        final rule = action.rule;
        final isExecuted = _callers.containsKey(rule);
        final caller = _callers.putIfAbsent(rule, Caller.new);

        caller.addReturn(frame.context, action.returnState);

        if (!isExecuted) {
          // Store callStart on the Caller so ReturnAction can emit BSR entries.
          caller.callStart = position;
          final callCtx = Context(caller, GlushList.empty<Mark>(), position);
          _withFrame(callCtx, (callFrame) {
            for (final firstState in parser.stateMachine.ruleFirst[rule] ?? []) {
              _process(callFrame, firstState);
            }
          });
        }
      } else if (action is ReturnAction) {
        final rule = action.rule;

        if (token != null && rule.guard != null && !rule.guard!.match(token)) {
          continue;
        }

        // Record BSR rule-completion entry BEFORE the ambiguity guard,
        // so every distinct (rule, callStart, position) span is captured.
        // The _returnedCallers guard below is only for parsing-state correctness.
        final callStart = frame.context.callStart ??
            (frame.caller is Caller ? (frame.caller as Caller).callStart : null);
        if (bsr != null && callStart != null) {
          bsr!.add(rule, callStart, position);
        }

        final caller = frame.caller;

        // Simple ambiguity handling: only process each caller once
        final shouldProcess = _returnedCallers.add(caller);
        if (!shouldProcess) continue;

        if (caller is Caller) {
          caller.forEach((ccaller, nextState, marks) {
            final combinedMarks = marks == null
                ? frame.marks
                : GlushList.branched<Mark>([marks]).addList(frame.marks ?? GlushList.empty<Mark>());

            final nextContext = Context(ccaller, combinedMarks);
            _withFrame(nextContext, (nextFrame) {
              _process(nextFrame, nextState);
            });
          });
        }
      } else if (action is AcceptAction) {
        _acceptedContexts.add(frame.context);
      }
    }
  }

  void _processFrame(Frame frame) {
    _withFrame(frame.copy().context, (nextFrame) {
      for (final state in frame.nextStates) {
        _process(nextFrame, state);
      }
    });
  }
}
