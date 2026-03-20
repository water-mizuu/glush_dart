/// State machine-based parser implementation
library glush.sm_parser;

import 'dart:async';

import 'package:glush/src/grammar.dart';

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
sealed class ParseOutcome {}

/// Returned when parsing fails.
final class ParseError extends ParseOutcome implements Exception {
  final int position;

  ParseError(this.position);

  @override
  String toString() => 'ParseError at position $position';
}

/// Returned when parsing succeeds (marks-based parse).
final class ParseSuccess extends ParseOutcome {
  final ParserResult result;

  ParseSuccess(this.result);
}

/// Returned when parsing succeeds with a full parse forest.
final class ParseForestSuccess extends ParseOutcome {
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
  final PatternSymbol symbol;
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
  String toTreeString(String input, [int indent = 0]) {
    final prefix = '  ' * indent;
    final str = '$prefix$this${children.isEmpty ? '  ${input.substring(start, end)}' : ''}\n';
    return str + children.map((c) => c.toTreeString(input, indent + 1)).join('');
  }

  String toPrecedenceString(String input) {
    if (children.isEmpty) {
      return input.substring(start, end);
    }

    List<String> mapped = children
        .where((c) => c.start != c.end)
        .map((c) => c.toPrecedenceString(input))
        .toList();

    if (mapped.length == 1) {
      return mapped.single;
    }

    return "(${mapped.join("")})";
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
  PatternSymbol get symbol => tree.symbol;

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
  late final List<Frame> _initialFrames;
  late PredicateLookaheadBuffer _predicateBuffer;

  GrammarInterface get grammar => stateMachine.grammar;

  SMParser(GrammarInterface grammar) : stateMachine = StateMachine(grammar) {
    const initialContext = Context(RootCallerKey(), null);
    final initialFrame = Frame(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
    _predicateBuffer = PredicateLookaheadBuffer();
  }

  /// Create parser from a pre-built state machine (used for imported machines)
  SMParser.fromStateMachine(this.stateMachine) {
    const initialContext = Context(RootCallerKey(), null);
    final initialFrame = Frame(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
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

  ParseOutcome parse(String input) {
    _predicateBuffer.initializeFromString(input);
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(codepoint, position, frames);
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames);

    if (lastStep.accept) {
      return ParseSuccess(ParserResult(lastStep.marks));
    } else {
      return ParseError(position);
    }
  }

  /// Parse with forest extraction enabled.
  ///
  /// Internally uses BSR (Binarised Shared Representation) recorded during
  /// parsing to restrict the SPPF construction to spans proven reachable by
  /// the parser, rather than exhaustively searching the whole grammar.
  ParseOutcome parseWithForest(String input) {
    _predicateBuffer.initializeFromString(input);
    final bsrOutcome = parseToBsr(input);
    if (bsrOutcome is BsrParseError) {
      return ParseError(bsrOutcome.position);
    }

    final bsrSuccess = bsrOutcome as BsrParseSuccess;
    final bsrSet = bsrSuccess.bsrSet;
    final startSymbol = stateMachine.grammar.startSymbol;
    final nodeManager = ForestNodeManager();
    final root = bsrSet.buildSppf(grammar, startSymbol, input, nodeManager);
    final effectiveRoot = root ?? nodeManager.symbolic(0, input.length, startSymbol);
    final forest = ParseForest(nodeManager, effectiveRoot);
    return ParseForestSuccess(forest);
  }

  /// Parse a stream of input chunks with forest extraction.
  ///
  /// Processes input incrementally as chunks arrive without buffering the entire
  /// stream in memory. Uses a bounded sliding-window buffer for predicate lookahead
  /// (default 1MB). Suitable for streaming large files.
  ///
  /// WARNING: If the grammar has predicates that require lookahead beyond the
  /// buffer window, results may be incorrect. Adjust [lookaheadWindowSize] if needed.
  Future<ParseOutcome> parseWithForestAsync(
    Stream<String> input, {
    int lookaheadWindowSize = 1048576,
  }) {
    _predicateBuffer.clear();

    final completer = Completer<ParseOutcome>();
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
              completer.complete(ParseError(globalPosition));
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
              // Build SPPF from the recorded BSR
              final startSymbol = stateMachine.grammar.startSymbol;
              final nodeManager = ForestNodeManager();
              final fullInput = String.fromCharCodes(allInput);
              final root = bsr.buildSppf(grammar, startSymbol, fullInput, nodeManager);
              final effectiveRoot = root ?? nodeManager.symbolic(0, globalPosition, startSymbol);
              final forest = ParseForest(nodeManager, effectiveRoot);
              completer.complete(ParseForestSuccess(forest));
            } else {
              completer.complete(ParseError(globalPosition));
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
      final stepResult = _processToken(codepoint, position, frames, input: input, bsr: bsr);
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return BsrParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames, input: input, bsr: bsr);

    if (lastStep.accept) {
      return BsrParseSuccess(bsr, lastStep.marks);
    } else {
      return BsrParseError(position);
    }
  }

  /// Count all possible parse trees without building them
  int countAllParses(String input) {
    final startSymbol = stateMachine.grammar.startSymbol;
    return _countDerivations(startSymbol, input, 0, input.length, {}, {});
  }

  /// Enumerate all possible parse trees lazily, yielding each as a [ParseDerivation].
  Iterable<ParseDerivation> enumerateAllParses(String input) sync* {
    final bsrOutcome = parseToBsr(input);
    if (bsrOutcome is! BsrParseSuccess) return;

    final bsrSet = bsrOutcome.bsrSet;
    final startSymbol = stateMachine.grammar.startSymbol;
    final memo = <String, List<ParseDerivation>?>{};

    yield* _enumerateDerivations(bsrSet, startSymbol, 0, input.length, input, memo);
  }

  /// Enumerate all possible parse trees with evaluated semantic values.
  /// Actions are executed bottom-up with child results.
  Iterable<ParseDerivationWithValue<dynamic>> enumerateAllParsesWithResults(String input) sync* {
    for (final derivation in enumerateAllParses(input)) {
      final value = evaluateParseDerivation(derivation, input);
      yield ParseDerivationWithValue(derivation, value, grammar: grammar);
    }
  }

  /// Convert a [ParseTree] (forest representation) to a [ParseDerivation] (enumeration representation).
  static ParseDerivation parseTreeToDerivation(ParseTree tree, String input) {
    final childDerivations = tree
        .children //
        .map((c) => parseTreeToDerivation(c, input))
        .toList();

    return ParseDerivation(tree.node.symbol, tree.node.start, tree.node.end, childDerivations);
  }

  int _countDerivations(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    final key = '$symbol:$start:$end';

    if (memo.containsKey(key)) {
      return memo[key]!;
    }

    if (inProgress[key] == true) {
      return 0; // Avoid cycles
    }

    inProgress[key] = true;
    int totalCount = 0;

    final children = grammar.childrenRegistry[symbol] ?? [];

    if (symbol.symbol.startsWith('rul:')) {
      if (children.isNotEmpty) {
        totalCount = _countAlternatives(children.single, input, start, end, memo, inProgress);
      }
    } else {
      totalCount = _countAlternatives(symbol, input, start, end, memo, inProgress);
    }

    inProgress[key] = false;
    memo[key] = totalCount;
    return totalCount;
  }

  int _countAlternatives(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    final pattern = symbol.symbol;
    final children = grammar.childrenRegistry[symbol] ?? [];
    final split = pattern.split(":");
    if (split.length < 3) return 0;
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          return start == end ? 1 : 0;
        }
      case "tok":
        {
          if (start + 1 != end) return 0;
          final unit = input.codeUnitAt(start);
          bool isMatching = switch (suffix[0]) {
            "." => true,
            ";" => unit == int.parse(suffix.substring(1)),
            "<" => unit <= int.parse(suffix.substring(1)),
            ">" => unit >= int.parse(suffix.substring(1)),
            "[" => () {
              final parts = suffix.substring(1).split(",");
              final min = int.parse(parts[0]);
              final max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
          return isMatching ? 1 : 0;
        }
      case "mar":
        return start == end ? 1 : 0;
      case "alt":
        return _countAlternatives(children.first, input, start, end, memo, inProgress) +
            _countAlternatives(children.last, input, start, end, memo, inProgress);
      case "seq":
        {
          int totalCount = 0;
          for (int mid = start; mid <= end; mid++) {
            final leftCount = _countAlternatives(
              children.first,
              input,
              start,
              mid,
              memo,
              inProgress,
            );
            if (leftCount > 0) {
              final rightCount = _countAlternatives(
                children.last,
                input,
                mid,
                end,
                memo,
                inProgress,
              );
              totalCount += leftCount * rightCount;
            }
          }
          return totalCount;
        }
      case "plu":
        {
          int totalCount = 0;
          for (int mid = start + 1; mid <= end; mid++) {
            final childCount = _countAlternatives(
              children.single,
              input,
              start,
              mid,
              memo,
              inProgress,
            );
            if (childCount > 0) {
              final starCount = _countStar(children.single, input, mid, end, memo, inProgress);
              totalCount += childCount * starCount;
            }
          }
          return totalCount;
        }
      case "sta":
        return _countStar(children.single, input, start, end, memo, inProgress);
      case "cal" || "rca" || "rul" || "act" || "pre":
        return _countDerivations(children.single, input, start, end, memo, inProgress);
      case "and":
      case "not":
        if (start == end &&
            checkPatternAtSymbol(children.single, input, start) == (prefix == "and")) {
          return 1;
        }
        return 0;
      default:
        return 0;
    }
  }

  // Count zero or more matches of a pattern
  int _countStar(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    if (start == end) {
      return 1; // Zero matches
    }

    int totalCount = 1; // Zero matches at current position

    // One or more matches
    for (int mid = start + 1; mid <= end; mid++) {
      final childCount = _countAlternatives(symbol, input, start, mid, memo, inProgress);
      if (childCount > 0) {
        final restCount = _countStar(symbol, input, mid, end, memo, inProgress);
        totalCount += childCount * restCount;
      }
    }

    return totalCount;
  }

  Iterable<ParseDerivation> _enumerateDerivations(
    BsrSet bsr,
    PatternSymbol symbol,
    int start,
    int end,
    String input,
    Map<String, List<ParseDerivation>?> memo, {
    int? minPrecedenceLevel,
    Map<String, bool>? inProgress,
  }) sync* {
    final key = '$symbol:$start:$end:${minPrecedenceLevel ?? ""}';
    if (memo.containsKey(key)) {
      final results = memo[key];
      if (results != null) yield* results;
      return;
    }

    inProgress ??= {};
    if (inProgress[key] == true) return;

    inProgress[key] = true;

    // For rules or other patterns, we check their children
    final children = grammar.childrenRegistry[symbol] ?? [];

    if (symbol.symbol.startsWith('rul:')) {
      // It's a rule, evaluate its body (the single child)
      if (children.isNotEmpty) {
        yield* _enumerateAlternatives(
          bsr,
          children.single,
          input,
          start,
          end,
          memo,
          inProgress,
          minPrecedenceLevel: minPrecedenceLevel,
        );
      }
    } else {
      yield* _enumerateAlternatives(
        bsr,
        symbol,
        input,
        start,
        end,
        memo,
        inProgress,
        minPrecedenceLevel: minPrecedenceLevel,
      );
    }

    inProgress[key] = false;
  }

  Iterable<ParseDerivation> _enumerateAlternatives(
    BsrSet bsr,
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress, {
    int? minPrecedenceLevel,
  }) sync* {
    final pattern = symbol.symbol;
    final children = grammar.childrenRegistry[symbol] ?? [];
    final split = pattern.split(":");
    if (split.length < 3) return;
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          if (start == end) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "tok":
        {
          late bool isMatching = switch (suffix[0]) {
            "." => true,
            ";" => input.codeUnitAt(start) == int.parse(suffix.substring(1)),
            "<" => input.codeUnitAt(start) <= int.parse(suffix.substring(1)),
            ">" => input.codeUnitAt(start) >= int.parse(suffix.substring(1)),
            "[" => () {
              final unit = input.codeUnitAt(start);
              final parts = suffix.substring(1).split(",");
              final min = int.parse(parts[0]);
              final max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
          if (start + 1 == end && isMatching) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "mar":
        if (start == end) yield ParseDerivation(symbol, start, end, []);
      case "pre":
        {
          final prec = int.parse(suffix);
          if (minPrecedenceLevel != null && prec < minPrecedenceLevel) return;
          yield* _enumerateAlternatives(
            bsr,
            children.single,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
        }
      case "alt":
        {
          yield* _enumerateAlternatives(
            bsr,
            children.first,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
          yield* _enumerateAlternatives(
            bsr,
            children.last,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
        }
      case "seq":
        {
          for (int mid = start; mid <= end; mid++) {
            final leftList = _enumerateAlternatives(
              bsr,
              children.first,
              input,
              start,
              mid,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (leftList.isEmpty) continue;

            final rightList = _enumerateAlternatives(
              bsr,
              children.last,
              input,
              mid,
              end,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (rightList.isEmpty) continue;

            for (final left in leftList) {
              for (final right in rightList) {
                yield ParseDerivation(symbol, start, end, [left, right]);
              }
            }
          }
        }
      case "plu":
        {
          for (int mid = start + 1; mid <= end; mid++) {
            final childList = _enumerateAlternatives(
              bsr,
              children.single,
              input,
              start,
              mid,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (childList.isEmpty) continue;
            for (final child in childList) {
              for (final star in _enumerateStar(
                bsr,
                children.single,
                input,
                mid,
                end,
                symbol,
                memo,
                inProgress,
              )) {
                if (star.end == end) {
                  yield ParseDerivation(symbol, start, end, [child, star]);
                }
              }
            }
          }
        }
      case "sta":
        yield* _enumerateStar(bsr, children.single, input, start, end, symbol, memo, inProgress);
      case "cal" || "rca":
        {
          final prec = suffix.isEmpty ? null : int.parse(suffix);
          yield* _enumerateDerivations(
            bsr,
            children.single,
            start,
            end,
            input,
            memo,
            minPrecedenceLevel: prec,
            inProgress: inProgress,
          );
        }
      case "act":
        for (final child in _enumerateAlternatives(
          bsr,
          children.single,
          input,
          start,
          end,
          memo,
          inProgress,
          minPrecedenceLevel: minPrecedenceLevel,
        )) {
          yield ParseDerivation(symbol, start, end, [child]);
        }
      case "and":
        if (checkPatternAtSymbol(children.single, input, start)) {
          yield ParseDerivation(symbol, start, start, []);
        }
      case "not":
        if (!checkPatternAtSymbol(children.single, input, start)) {
          yield ParseDerivation(symbol, start, start, []);
        }
      case "con":
        // Simplified check for conjunction
        if (start + 1 == end) {
          // This would need more logic to check both children match
          yield ParseDerivation(symbol, start, end, []);
        }
    }
  }

  Iterable<ParseDerivation> _enumerateStar(
    BsrSet bsr,
    PatternSymbol childSymbol,
    String input,
    int start,
    int end,
    PatternSymbol starSymbol,
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress,
  ) sync* {
    if (start == end) {
      yield ParseDerivation(starSymbol, start, end, []);
      return;
    }

    // PEG greedy matching: try longest match first
    for (int mid = end; mid > start; mid--) {
      final childList = _enumerateAlternatives(
        bsr,
        childSymbol,
        input,
        start,
        mid,
        memo,
        inProgress,
      ).toList();
      if (childList.isNotEmpty) {
        for (final child in childList) {
          for (final star in _enumerateStar(
            bsr,
            childSymbol,
            input,
            mid,
            end,
            starSymbol,
            memo,
            inProgress,
          )) {
            final actualEnd = star.end;
            yield ParseDerivation(starSymbol, start, actualEnd, [child, star]);
          }
        }
        return;
      }
    }

    yield ParseDerivation(starSymbol, start, start, []);
  }

  /// Evaluate a [ParseDerivation] with evaluated semantic values.
  Object? evaluateParseDerivation(ParseDerivation derivation, String input) {
    return _evaluateParseDerivation(derivation, input);
  }

  /// Directly evaluate a [ParseTree] extracted from the forest.
  Object? evaluateParseTree(ParseTree tree, String input) {
    return _evaluateParseDerivation(parseTreeToDerivation(tree, input), input);
  }

  Object? _evaluateParseDerivation(ParseDerivation tree, String input) {
    final symbol = tree.symbol.symbol;
    final split = symbol.split(":");
    if (split.length < 3) {
      // Fallback for symbols that don't follow the prefix:id:suffix format
      return null;
    }
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        return "";
      case "tok":
        return tree.getMatchedText(input);
      case "mar":
        return NamedMark(suffix, tree.start);
      case "alt":
      case "act":
      case "pre":
      case "cal":
      case "rca":
      case "rul":
        if (tree.children.isNotEmpty) {
          return _evaluateParseDerivation(tree.children[0], input);
        }
        return null;
      case "seq":
        final results = <dynamic>[];
        for (final child in tree.children) {
          results.add(_evaluateParseDerivation(child, input));
        }
        return results;
      case "plu":
      case "sta":
        final results = <dynamic>[];
        if (tree.children.isNotEmpty) {
          results.add(_evaluateParseDerivation(tree.children[0], input));
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
      case "and":
      case "not":
        return [];
      default:
        // Try fallback to symbolRegistry if it exists
        final pattern = grammar.symbolRegistry[tree.symbol];
        if (pattern == null) return null;

        return switch (pattern) {
          Token() => tree.getMatchedText(input),
          Marker(:var name) => NamedMark(name, tree.start),
          Eps() => "",
          Action action => () {
            final childResults = tree.children
                .map((c) => _evaluateParseDerivation(c, input))
                .toList();
            final span = tree.getMatchedText(input);
            if (childResults.length == 1 && childResults.single is List) {
              return action.callback(span, childResults.single as List);
            }
            return action.callback(span, childResults);
          }(),
          _ => tree.children.isNotEmpty ? _evaluateParseDerivation(tree.children[0], input) : null,
        };
    }
  }

  bool checkPatternAtSymbol(PatternSymbol symbol, String inputStr, int startPos) {
    _predicateBuffer.initializeFromString(inputStr);
    return _checkPredicateSymbol(symbol, startPos);
  }

  bool _checkPredicateSymbol(PatternSymbol symbol, int startPos) {
    final pattern = symbol.symbol;
    final children = grammar.childrenRegistry[symbol] ?? [];
    final split = pattern.split(":");
    if (split.length < 3) return true;
    final [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          return true;
        }
      case "tok":
        {
          if (startPos >= _predicateBuffer.length) return false;
          final unit = _predicateBuffer.codeUnitAt(startPos);
          if (unit < 0) return false;
          if (suffix.isEmpty) return false;
          return switch (suffix[0]) {
            "." => true,
            ";" => unit == int.parse(suffix.substring(1)),
            "<" => unit <= int.parse(suffix.substring(1)),
            ">" => unit >= int.parse(suffix.substring(1)),
            "[" => () {
              final parts = suffix.substring(1).split(",");
              final min = int.parse(parts[0]);
              final max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
        }
      case "mar":
        return true;
      case "alt":
        return _checkPredicateSymbol(children.first, startPos) ||
            _checkPredicateSymbol(children.last, startPos);
      case "seq":
        {
          // Very simplified sequence check for predicates
          if (_checkPredicateSymbol(children.first, startPos)) {
            // Assume single token for left part if it's 'tok'
            final leftLen = children.first.symbol.startsWith('tok:') ? 1 : 0;
            return _checkPredicateSymbol(children.last, startPos + leftLen);
          }
          return false;
        }
      case "and":
        return _checkPredicateSymbol(children.single, startPos);
      case "not":
        return !_checkPredicateSymbol(children.single, startPos);
      case "cal" || "rca" || "rul" || "act" || "pre":
        return _checkPredicateSymbol(children.single, startPos);
      default:
        return true;
    }
  }

  Step _processToken(
    int? token,
    int position,
    List<Frame> frames, {
    String input = '',
    BsrSet? bsr,
  }) {
    final step = Step(this, token, position, input: input, bsr: bsr, buffer: _predicateBuffer);
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
  bool checkPatternAtPosition(Pattern pattern, String inputStr, int startPos) {
    _predicateBuffer.initializeFromString(inputStr);
    return _checkPredicatePattern(pattern, startPos);
  }

  /// Internal: recursive predicate pattern checking (uses buffer stored on parser)
  bool _checkPredicatePattern(Pattern pattern, int startPos, {PatternSymbol? symbol}) {
    if (symbol != null) {
      return _checkPredicateSymbol(symbol, startPos);
    }
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

    if (pattern is Star) {
      // Zero or more matches
      if (start == end) return true; // Zero matches always succeeds

      // Try one or more matches
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

/// Caller tracking for rule returns
final class Caller extends CallerKey {
  final Rule rule;
  final Pattern pattern;

  /// Key is a (caller, nextState) pair encoded as a two-element list.
  final Map<(CallerKey, State), List<Context>> _grouped = {};

  /// The input position at which the associated rule was invoked.
  /// Set once at CallAction time; used by ReturnAction to record BSR entries.
  int? callStart;

  Caller(this.rule, this.pattern);

  void addReturn(Context context, State nextState) {
    final key = (context.caller, nextState);
    _grouped.putIfAbsent(key, () => []).add(context);
  }

  void forEach(void Function(CallerKey, State, Context) callback) {
    for (final MapEntry(key: (caller, nextState), value: contexts) in _grouped.entries) {
      for (final context in contexts) {
        callback(caller, nextState, context);
      }
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
class Context {
  final CallerKey caller;
  final GlushList<Mark>? marks;

  /// The input position at which the rule associated with this context
  /// was invoked.  Used to record BSR rule-completion entries.
  final int? callStart;

  /// The input position where the last matched symbol started.
  /// Used for midPoint in BSR nodes.
  final int? pivot;

  const Context(this.caller, this.marks, [this.callStart, this.pivot]);
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

/// Single step in parsing
class Step {
  final SMParser parser;
  final int? token;
  final int position;
  final String input;

  /// Optional BSR set to populate with rule-completion entries. When null,
  /// BSR recording is skipped (used by the plain recognize/parse paths).
  final BsrSet? bsr;

  /// Predicate lookahead buffer for checking patterns without full input access
  final PredicateLookaheadBuffer buffer;

  final List<Frame> nextFrames = [];
  final Map<(Rule, Pattern), Caller> _callers = {};
  final Set<CallerKey> _returnedCallers = {};
  final List<Context> _acceptedContexts = [];

  // /// Frames created during CPS processing that need conditional adding to nextFrames
  // final Set<Frame> _localFramesInCurrentProcessing = {};

  Step(
    this.parser,
    this.token,
    this.position, {
    required this.input,
    this.bsr,
    required this.buffer,
  });

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
      switch (action) {
        case SemanticAction():
          // Evaluate semantic action during parsing
          // Extract child results from marks (StringMark values)
          final marks = frame.marks?.toList() ?? [];
          final childResults = <Object?>[];
          int spanStart = position;
          int spanEnd = position;

          for (final mark in marks) {
            if (mark is StringMark) {
              childResults.add(mark.value);
              spanStart = spanStart > mark.position ? mark.position : spanStart;
              spanEnd = mark.position + 1; // Update end position
            } else if (mark is NamedMark) {
              spanStart = spanStart > mark.position ? mark.position : spanStart;
              spanEnd = spanEnd < mark.position ? mark.position : spanEnd;
            }
          }

          // // Compute the span string from input
          // final span = spanStart < input.length && spanEnd <= input.length
          //     ? input.substring(spanStart, spanEnd)
          //     : '';

          // final computedValue = action.callback(span, childResults);

          // Create new context with computed semantic value
          final semanticCtx = Context(
            frame.caller,
            frame.marks,
            frame.context.callStart,
            frame.context.pivot,
          );

          _withFrame(semanticCtx, (frame) {
            _process(frame, action.nextState);
          });
        case TokenAction():
          if (token case var token? when action.pattern.match(token)) {
            // If token matches, add a StringMark with the captured token if not ExactToken
            // So ranges and 'any' tokens are captured into the marks array too
            var newMarks = frame.marks;
            if (action.pattern case Token(:var choice) when choice is! ExactToken) {
              final strMark = StringMark(String.fromCharCode(token), position);
              newMarks = (newMarks ?? const GlushList.empty()).add(strMark);
            }

            final bsrSet = bsr;
            if (bsrSet != null && frame.caller is Caller) {
              final rule = (frame.caller as Caller).rule;
              bsrSet.add(
                rule.symbolId!,
                frame.context.callStart!,
                position, // Use current position as pivot for this token
                position + 1,
              );
            }

            final nextFrame = Frame(
              Context(frame.caller, newMarks, frame.context.callStart, position + 1),
            );
            nextFrame.nextStates.add(action.nextState);
            nextFrames.add(nextFrame);
            // TokenAction does NOT enqueue - it defers to next token step
          }
        case MarkAction():
          final mark = NamedMark(action.name, position);
          final markCtx = Context(
            frame.caller,
            (frame.marks ?? const GlushList.empty()).add(mark),
            frame.context.callStart,
            frame.context.pivot,
          );

          final bsrSet = bsr;
          if (bsrSet != null && frame.caller is Caller) {
            final rule = (frame.caller as Caller).rule;
            bsrSet.add(rule.symbolId!, frame.context.callStart!, position, position);
          }

          _withFrame(markCtx, (nextFrame) {
            _process(nextFrame, action.nextState);
          });
        case PredicateAction():
          // Predicate checking (lookahead without consumption)
          // Buffer ensures we have the data needed for lookahead
          bool predicateMatches = parser._checkPredicatePattern(
            action.pattern,
            position,
            symbol: action.symbol,
          );

          // For AND (&pattern), continue if pattern matches
          // For NOT (!pattern), continue if pattern does NOT match
          final shouldContinue = action.isAnd ? predicateMatches : !predicateMatches;

          if (shouldContinue) {
            // Predicate succeeded - enqueue next state processing
            // Zero-width: processed with the same token in this frame step
            _withFrame(frame.context, (nextFrame) {
              _process(nextFrame, action.nextState);
            });
          }
        // If predicate failed, we simply don't enqueue (backtrack)
        case CallAction():
          final rule = action.rule;
          final pattern = action.pattern;
          final key = (rule, pattern);
          final isExecuted = _callers.containsKey(key);
          final caller = _callers.putIfAbsent(key, () => Caller(rule, pattern));

          caller.addReturn(frame.context, action.returnState);
          if (!isExecuted) {
            // Store callStart on the Caller so ReturnAction can emit BSR entries.
            caller.callStart = position;
            final callCtx = Context(caller, const GlushList.empty(), position);
            // Create local frame that will be conditionally added to nextFrames

            _withFrame(callCtx, (nextFrame) {
              for (final firstState in parser.stateMachine.ruleFirst[rule] ?? []) {
                _process(nextFrame, firstState);
              }
            });
          }
        case ReturnAction():
          final rule = action.rule;

          if (token != null && rule.guard != null && !rule.guard!.match(token)) {
            continue;
          }

          // Record BSR rule-completion entry BEFORE the ambiguity guard,
          // so every distinct (rule, callStart, position) span is captured.
          // The _returnedCallers guard below is only for parsing-state correctness.
          final callStart =
              frame.context.callStart ??
              (frame.caller is Caller ? (frame.caller as Caller).callStart : null);
          final lastPivot = frame.context.pivot;
          if ((bsr, callStart, lastPivot ?? callStart) case (
            var bsr?,
            var callStart?,
            var pivot?,
          )) {
            bsr.add(rule.symbolId!, callStart, pivot, position);
          }

          final caller = frame.caller;

          // Record BSR entries for all parent rules being returned to.
          // This must happen BEFORE the ambiguity guard because different
          // derivations of 'rule' might return to the same 'caller' context,
          // providing alternative pivots for the parent rule's sequence.
          final bsrSet = bsr;
          if (bsrSet != null && caller is Caller) {
            caller.forEach((ccaller, nextState, ccontext) {
              if (ccaller is Caller) {
                bsrSet.add(
                  ccaller.rule.symbolId!,
                  ccontext.callStart!,
                  caller.callStart!,
                  position,
                );
              }
            });
          }

          // Simple ambiguity handling: only process each caller once
          final shouldProcess = _returnedCallers.add(caller);
          if (!shouldProcess) continue;

          if (caller is Caller) {
            caller.forEach((ccaller, nextState, ccontext) {
              final nextMarks = ccontext.marks == null
                  ? frame.marks
                  : GlushList.branched<Mark>([
                      ccontext.marks!,
                    ]).addList(frame.marks ?? const GlushList.empty());

              final nextContext = Context(ccaller, nextMarks, ccontext.callStart, position);
              _withFrame(nextContext, (nextFrame) {
                _process(nextFrame, nextState);
              });
            });
          }
        case AcceptAction():
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
