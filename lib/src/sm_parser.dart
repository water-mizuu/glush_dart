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

  const ParseDerivation(this.symbol, this.start, this.end, this.children);

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
    if (children.length == 1) {
      return children.single.toTreeString(input);
    }
    // Parens showing children structure with their matched content
    final childStr = children.map((c) => c.toTreeString(input)).join('');
    return '($childStr)';
  }

  Object? getSimplified(String input) {
    if (children.isEmpty) {
      return input.substring(start, end);
    }

    if (children.length == 1) {
      return children.single.getSimplified(input);
    }

    return children.map((c) => c.getSimplified(input)).toList();
  }

  /// Pretty print the parse tree
  @override
  String toString() => '$symbol[$start:$end]';
}

/// Represents a parse tree with its evaluated semantic value
class ParseDerivationWithValue<T> {
  final ParseDerivation tree;
  final T value;
  final GrammarInterface? grammar;

  ParseDerivationWithValue(this.tree, this.value, {this.grammar});

  /// Get substring that this derivation matched
  String getMatchedText(String input) => tree.getMatchedText(input);

  /// Get the tree's symbol (as a String ID)
  String get symbol => tree.symbol;

  /// Get the tree's pattern object from the registry (uses grammar context if available)
  Pattern? get pattern {
    if (grammar case var grammar?) {
      return grammar.symbolRegistry[tree.symbol];
    }
    return null;
  }

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
  final GrammarInterface grammar;
  late final List<Frame> _initialFrames;
  late PredicateLookaheadBuffer _predicateBuffer;

  SMParser(GrammarInterface grammar)
      : stateMachine = StateMachine(grammar),
        grammar = grammar {
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
    final startRule = stateMachine.grammar.startCall.rule;
    final nodeManager = ForestNodeManager();
    final root = bsrSet.buildSppf(startRule, input, nodeManager);
    final effectiveRoot = root ?? nodeManager.symbolic(0, input.length, startRule);
    final forest = ParseForest(nodeManager, effectiveRoot, bsrOutcome.marks);
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
  Future<ParseOutcome<T>> parseWithForestAsync<T>(
    Stream<String> input, {
    int lookaheadWindowSize = 1048576,
  }) {
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
              final effectiveRoot = root ?? nodeManager.symbolic(0, globalPosition, startRule);
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

      final root = nodeManager.symbolic(0, input.length, startRule);
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
      return BsrParseSuccess(bsr, lastStep.marks);
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
    Map<String, bool> inProgress,
  ) {
    final key = '${rule.name}:$start:$end';

    if (memo.containsKey(key)) return memo[key];
    if (inProgress[key] == true) return null; // Recursive call — treat as no derivation

    inProgress[key] = true;

    final symNode = nodeManager.symbolic(start, end, rule);
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
    Map<String, bool> inProgress,
  ) {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        final termNode = nodeManager.terminal(start, end, pattern, input.codeUnitAt(start));
        return [
          [termNode]
        ];
      }
      return [];
    }

    if (pattern is Eps) {
      if (start == end) {
        return [
          [nodeManager.epsilon(start, pattern)]
        ]; // epsilon: one derivation with one EpsilonNode
      }
      return [];
    }

    if (pattern is Marker) {
      if (start == end) {
        return [
          [nodeManager.marker(start, pattern)]
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
            final node = nodeManager.intermediate(start, end, pattern, 'Seq');
            node.addFamily(Family([...leftChildren, ...rightChildren]));
            result.add([node]);
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
      final childGroups =
          _patternChildGroups(pattern.child, input, start, end, nodeManager, memo, inProgress);
      if (childGroups.isEmpty) return [];

      // Wrap each derivation in an IntermediateNode to represent the semantic action
      return childGroups.map((children) {
        final intermediateNode = nodeManager.intermediate(start, end, pattern, 'Action<T>');
        intermediateNode.addFamily(Family(children));
        return [intermediateNode];
      }).toList();
    }

    if (pattern is Plus) {
      // Decompose (P >> Plus(P)) | P
      final result = <List<ForestNode>>[];

      // Option 1: P then Plus(P)
      for (int mid = start + 1; mid <= end; mid++) {
        final headGroups =
            _patternChildGroups(pattern.child, input, start, mid, nodeManager, memo, inProgress);
        if (headGroups.isEmpty) continue;

        final tailGroups =
            _patternChildGroups(pattern, input, mid, end, nodeManager, memo, inProgress);
        if (tailGroups.isEmpty) continue;

        for (final h in headGroups) {
          for (final t in tailGroups) {
            final node = nodeManager.intermediate(start, end, pattern, 'Plus');
            node.addFamily(Family([...h, ...t]));
            result.add([node]);
          }
        }
      }

      // Option 2: Just P
      final singleGroups =
          _patternChildGroups(pattern.child, input, start, end, nodeManager, memo, inProgress);
      for (final s in singleGroups) {
        final node = nodeManager.intermediate(start, end, pattern, 'Plus');
        node.addFamily(Family(s));
        result.add([node]);
      }

      return result;
    }

    if (pattern is Star) {
      final result = <List<ForestNode>>[];

      // Option 1: P then Star(P)
      for (int mid = start + 1; mid <= end; mid++) {
        final headGroups =
            _patternChildGroups(pattern.child, input, start, mid, nodeManager, memo, inProgress);
        if (headGroups.isEmpty) continue;

        final tailGroups =
            _patternChildGroups(pattern, input, mid, end, nodeManager, memo, inProgress);
        if (tailGroups.isEmpty) continue;

        for (final h in headGroups) {
          for (final t in tailGroups) {
            final node = nodeManager.intermediate(start, end, pattern, 'Star');
            node.addFamily(Family([...h, ...t]));
            result.add([node]);
          }
        }
      }

      // Option 2: Eps (base case)
      if (start == end) {
        final node = nodeManager.intermediate(start, end, pattern, 'Star');
        node.addFamily(Family([nodeManager.epsilon(start, pattern)]));
        result.add([node]);
      }

      return result;
    }

    if (pattern is Conj) {
      // Both patterns must match the same span.
      // Since Conj is restricted to single-token patterns, start+1 should be end.
      if (start + 1 == end &&
          pattern.left.match(input.codeUnitAt(start)) &&
          pattern.right.match(input.codeUnitAt(start))) {
        final termNode = nodeManager.terminal(start, end, pattern, input.codeUnitAt(start));
        return [
          [termNode]
        ];
      }
      return [];
    }

    if (pattern is And || pattern is Not) {
      // Predicates are zero-width.
      if (start == end) {
        return [
          [nodeManager.epsilon(start, pattern)]
        ];
      }
      return [];
    }

    if (pattern is PrecedenceLabeledPattern) {
      return _patternChildGroups(pattern.pattern, input, start, end, nodeManager, memo, inProgress);
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
  Iterable<ParseDerivationWithValue<dynamic>> enumerateAllParsesWithResults(String input) sync* {
    for (final derivation in enumerateAllParses(input)) {
      final value = evaluateParseDerivation(derivation, input);
      yield ParseDerivationWithValue(derivation, value, grammar: grammar);
    }
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
    for (final tree in forest.forest.extract()) {
      final derivation = parseTreeToDerivation(tree, input);
      final value = evaluateParseDerivation(derivation, input);
      yield ParseDerivationWithValue(derivation, value, grammar: grammar);
    }
  }

  /// Convert a [ParseTree] (forest representation) to a [ParseDerivation] (enumeration representation).
  static ParseDerivation parseTreeToDerivation(ParseTree tree, String input) {
    final childDerivations = tree.children //
        .map((c) => parseTreeToDerivation(c, input))
        .toList();

    return ParseDerivation(
      tree.node.pattern.symbolId!,
      tree.node.start,
      tree.node.end,
      childDerivations,
    );
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

    if (pattern is Star) {
      return _countStar(pattern.child, input, start, end, memo, inProgress);
    }

    if (pattern is Conj) {
      if (start + 1 == end &&
          pattern.left.match(input.codeUnitAt(start)) &&
          pattern.right.match(input.codeUnitAt(start))) {
        return 1;
      }
      return 0;
    }

    if (pattern is PrecedenceLabeledPattern) {
      return _countAlternatives(pattern.pattern, input, start, end, memo, inProgress);
    }

    if (pattern is And || pattern is Not) {
      if (start == end &&
          _checkPredicatePattern(
                  pattern is And ? pattern.pattern : (pattern as Not).pattern, start) ==
              (pattern is And)) {
        return 1;
      }
      return 0;
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
          final d = ParseDerivation(rule.symbolId!, start, end, []);
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
    for (final d in _enumerateAlternatives(rule.body(), input, start, end, memo, inProgress)) {
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
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress,
  ) sync* {
    if (pattern is Token) {
      if (start + 1 == end && pattern.match(input.codeUnitAt(start))) {
        yield ParseDerivation(pattern.symbolId!, start, end, []);
      }
      return;
    }

    if (pattern is Eps) {
      if (start == end) yield ParseDerivation(pattern.symbolId, start, end, []);
      return;
    }

    if (pattern is Marker) {
      if (start == end) yield ParseDerivation(pattern.symbolId!, start, end, []);
      return;
    }

    if (pattern is Alt) {
      yield* _enumerateAlternatives(pattern.left, input, start, end, memo, inProgress);
      yield* _enumerateAlternatives(pattern.right, input, start, end, memo, inProgress);
      return;
    }

    if (pattern is Seq) {
      // CFG sequence: enumerate ALL splits where both left and right match
      for (int mid = start; mid <= end; mid++) {
        final leftList =
            _enumerateAlternatives(pattern.left, input, start, mid, memo, inProgress).toList();
        if (leftList.isEmpty) continue;

        final rightList =
            _enumerateAlternatives(pattern.right, input, mid, end, memo, inProgress).toList();
        if (rightList.isEmpty) continue;

        for (final left in leftList) {
          for (final right in rightList) {
            yield ParseDerivation(pattern.symbolId!, start, end, [left, right]);
          }
        }
      }
      return;
    }

    if (pattern is Plus) {
      for (int mid = start + 1; mid <= end; mid++) {
        final childList =
            _enumerateAlternatives(pattern.child, input, start, mid, memo, inProgress).toList();
        if (childList.isEmpty) continue;
        for (final child in childList) {
          for (final star in _enumerateStar(
              pattern.child, input, mid, end, '${pattern.child}*', memo, inProgress)) {
            // Only yield if plus covers the full requested span
            if (star.end == end) {
              yield ParseDerivation(pattern.symbolId!, start, end, [child, star]);
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
      for (final child
          in _enumerateAlternatives(pattern.child, input, start, end, memo, inProgress)) {
        yield ParseDerivation(pattern.symbolId!, start, end, [child]);
      }
      // yield* _enumerateAlternatives(pattern.child, input, start, end, memo, inProgress);
      return;
    }

    if (pattern is And) {
      // Positive lookahead: check if pattern matches at start position without consuming
      if (_checkPredicatePattern(pattern.pattern, start)) {
        // Predicate succeeded - yield empty derivation (zero-width match)
        yield ParseDerivation(pattern.symbolId!, start, start, []);
      }
      return;
    }

    if (pattern is Not) {
      // Negative lookahead: check if pattern does NOT match at start position
      if (!_checkPredicatePattern(pattern.pattern, start)) {
        // Predicate succeeded - yield empty derivation (zero-width match)
        yield ParseDerivation(pattern.symbolId!, start, start, []);
      }
      return;
    }

    if (pattern is Star) {
      yield* _enumerateStar(pattern.child, input, start, end, 'Star', memo, inProgress);
      return;
    }

    if (pattern is Conj) {
      if (start + 1 == end &&
          pattern.left.match(input.codeUnitAt(start)) &&
          pattern.right.match(input.codeUnitAt(start))) {
        yield ParseDerivation(pattern.symbolId!, start, end, []);
      }
      return;
    }

    if (pattern is PrecedenceLabeledPattern) {
      yield* _enumerateAlternatives(pattern.pattern, input, start, end, memo, inProgress);
      return;
    }
  }

  Iterable<ParseDerivation> _enumerateStar(
    Pattern pattern,
    String input,
    int start,
    int end,
    String symbol,
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress,
  ) sync* {
    if (start == end) {
      yield ParseDerivation(pattern.symbolId!, start, end, []);
      return;
    }

    // PEG greedy matching: try longest match first
    for (int mid = end; mid > start; mid--) {
      final childList =
          _enumerateAlternatives(pattern, input, start, mid, memo, inProgress).toList();
      if (childList.isNotEmpty) {
        for (final child in childList) {
          for (final star in _enumerateStar(pattern, input, mid, end, symbol, memo, inProgress)) {
            // Use the actual end position from the star tree, not the requested 'end'
            final actualEnd = star.end;
            yield ParseDerivation(pattern.symbolId!, start, actualEnd, [child, star]);
          }
        }
        return; // Only use the first (longest) match - PEG greedy semantics
      }
    }

    // No match found - zero matches
    yield ParseDerivation(pattern.symbolId!, start, start, []);
  }

  /// Evaluate a [ParseDerivation] with evaluated semantic values.
  Object? evaluateParseDerivation(
    ParseDerivation derivation,
    String input,
  ) {
    return _evaluateParseDerivation(derivation, input);
  }

  /// Directly evaluate a [ParseTree] extracted from the forest.
  Object? evaluateParseTree(ParseTree tree, String input) {
    return _evaluateParseDerivation(
      parseTreeToDerivation(tree, input),
      input,
    );
  }

  Object? _evaluateParseDerivation(ParseDerivation tree, String input) {
    final symbolRegistry = grammar.symbolRegistry;

    switch (symbolRegistry[tree.symbol]) {
      case Token pattern:
        if (tree.start + 1 == tree.end && pattern.match(input.codeUnitAt(tree.start))) {
          final evaluated = tree.getMatchedText(input);
          return evaluated;
        }
      case Marker pattern:
        return NamedMark(pattern.name, tree.start);
      case Eps():
        return "";
      case Alt():
        // One of the alternatives matched - evaluate that child
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case Seq():
        // Sequence: evaluate left and right children
        final results = <dynamic>[];
        for (final child in tree.children) {
          final childValue = _evaluateParseDerivation(child, input);
          results.add(childValue);
        }
        return results;
      case Conj():
        // Conjunction: both patterns match the same token
        final codeUnit = input.codeUnitAt(tree.start);
        return String.fromCharCode(codeUnit);
      case Plus():
      case Star():
        // One/Zero or more: collect all child results into a list.
        // We avoid flattening sequences (lists) from the body match.
        final results = <dynamic>[];
        if (tree.children.isNotEmpty) {
          // First child is the 'head' element
          results.add(_evaluateParseDerivation(tree.children[0], input));
          // Second child (if any) is the rest of the repetition (tail)
          if (tree.children.length > 1) {
            final rest = _evaluateParseDerivation(tree.children[1], input);
            if (rest is List) {
              results.addAll(rest);
            } else if (rest != "") {
              results.add(rest);
            }
          }
        }
        return results;
      case And():
        // Positive lookahead: zero-width, return empty list
        return [];
      case Not():
        // Negative lookahead: zero-width, return empty list
        return [];
      case Rule():
        // Evaluate the rule's body
        return _evaluateParseDerivation(
          tree.children.isNotEmpty
              ? tree.children[0]
              : ParseDerivation(Eps().symbolId, tree.start, tree.end, []),
          input,
        );
      case RuleCall _:
        // Recursively evaluate the referenced rule
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case Call _:
        // Recursively evaluate the referenced rule
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case Action<dynamic> action:
        // Evaluate the child and apply the semantic action
        assert(tree.children.length == 1, "Action Nodes should only have one child.");

        final childResults = <dynamic>[];
        for (final child in tree.children) {
          final childValue = _evaluateParseDerivation(child, input);
          childResults.add(childValue);
        }
        final span = tree.getMatchedText(input);
        if (childResults.length == 1 && childResults.single is List) {
          return action.callback(span, childResults.single);
        }
        return action.callback(span, childResults);
      case PrecedenceLabeledPattern():
        // Unwrap and evaluate the child pattern
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case null:
        throw StateError("Tried to evaluate using an invalid symbol.");
    }

    return null;
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
  final Set<State> nextStates;

  Frame(this.context) : nextStates = {};

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
          if (token != null &&
              action.pattern is Token &&
              (action.pattern as Token).choice is! ExactToken) {
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
