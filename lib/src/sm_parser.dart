/// State machine-based parser implementation
library glush.sm_parser;

import 'dart:async';
import 'dart:collection';

import 'package:glush/src/grammar.dart';

import 'patterns.dart';
import 'state_machine.dart';
import 'mark.dart';
import 'list.dart';
import 'sppf.dart';
import 'bsr.dart';
export 'bsr.dart';

const isDebug = false;
void printDebug(String message) {
  if (isDebug) {
    print(message);
  }
}

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

final class ParseAmbiguousForestSuccess extends ParseOutcome {
  final GlushList<Mark> forest;

  ParseAmbiguousForestSuccess(this.forest);
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

  /// Pretty printDebug the parse tree
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

/// Node in a linked list of tokens, providing shared history for lagging frames.
class TokenNode {
  final int unit;
  TokenNode? next;
  TokenNode(this.unit);
}

/// Tracks the status of a lookahead sub-parse.
class PredicateTracker {
  final PatternSymbol symbol;
  final int startPos;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(Context, State)> waiters = [];

  PredicateTracker(this.symbol, this.startPos, {required this.isAnd});
}

class SMParser {
  final StateMachine stateMachine;
  late final List<Frame> _initialFrames;
  final GlushListManager<Mark> _markManager = GlushListManager<Mark>();
  final Map<int, TokenNode> _historyByPosition = {};
  TokenNode? _historyTail;
  final Map<(PatternSymbol, int), PredicateTracker> _predicateTrackers = {};
  bool captureTokensAsMarks;

  GrammarInterface get grammar => stateMachine.grammar;

  SMParser(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar) {
    const initialContext = Context(RootCallerKey(), const GlushList.empty());
    final initialFrame = Frame(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  /// Create parser from a pre-built state machine (used for imported machines)
  SMParser.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false}) {
    const initialContext = Context(RootCallerKey(), const GlushList.empty());
    final initialFrame = Frame(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  bool recognize(String input) {
    printDebug('[DEBUG] === START recognize("$input") ===');
    var frames = _initialFrames;
    int position = 0;

    for (final codepoint in input.codeUnits) {
      printDebug(
        '[DEBUG] recognize: position=$position, codepoint=$codepoint (${String.fromCharCode(codepoint)})',
      );
      final stepResult = _processToken(codepoint, position, frames);
      frames = stepResult.nextFrames;
      printDebug('[DEBUG] recognize: after _processToken, nextFrames.length=${frames.length}');
      if (frames.isEmpty) {
        printDebug('[DEBUG] recognize: FAILED - no frames after position $position');
        return false;
      }
      position++;
    }

    final lastStep = _processToken(null, position, frames);
    printDebug('[DEBUG] recognize: final _processToken, accept=${lastStep.accept}');
    printDebug('[DEBUG] === END recognize ===');
    return lastStep.accept;
  }

  ParseOutcome parse(String input) {
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

  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks = false}) {
    var frames = _initialFrames;
    int position = 0;

    final capture = captureTokensAsMarks;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: capture,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(
      null,
      position,
      frames,
      isSupportingAmbiguity: true,
      captureTokensAsMarks: capture,
    );

    if (lastStep.accept) {
      final mergedMarks = _markManager.branched(
        lastStep._acceptedContexts.map((c) => c.marks).toList(),
      );
      return ParseAmbiguousForestSuccess(mergedMarks);
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
        if (start == end) {
          final childCount = _countDerivations(
            children.single,
            input,
            start,
            start,
            memo,
            inProgress,
          );
          if ((childCount > 0) == (prefix == "and")) {
            return 1;
          }
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
        if (_enumerateDerivations(
          bsr,
          children.single,
          start,
          start,
          input,
          memo,
          inProgress: inProgress,
        ).any((_) => true)) {
          yield ParseDerivation(symbol, start, start, []);
        }
      case "not":
        if (!_enumerateDerivations(
          bsr,
          children.single,
          start,
          start,
          input,
          memo,
          inProgress: inProgress,
        ).any((_) => true)) {
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
        final results = <Object?>[];
        for (final child in tree.children) {
          results.add(_evaluateParseDerivation(child, input));
        }
        return results;
      case "plu":
      case "sta":
        final results = <Object?>[];
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
            if (childResults case List(length: 1, :List<Object?> single)) {
              return action.callback(span, single);
            }
            return action.callback(span, childResults);
          }(),
          _ => tree.children.isNotEmpty ? _evaluateParseDerivation(tree.children[0], input) : null,
        };
    }
  }

  List<String> extractParseTreeMarks(ParseTree tree, String input) {
    return _aggregateMarks(
      _flattenParseTreeMarks(_extractParseTreeMarks(parseTreeToDerivation(tree, input), input)),
    );
  }

  List<String> _aggregateMarks(List<Mark> marks) {
    final List<String> result = [];

    StringMark? builtMark;
    for (int i = 0; i < marks.length; ++i) {
      Object? current = marks[i];

      if (current is StringMark) {
        if (builtMark == null) {
          builtMark = current;
        } else {
          builtMark = StringMark(builtMark.value + current.value, builtMark.position);
        }
      } else if (current is NamedMark) {
        if (builtMark != null) {
          result.add(builtMark.value);
          builtMark = null;
        }
        result.add(current.name);
      }
    }

    // Add any remaining built mark at the end
    if (builtMark != null) {
      result.add(builtMark.value);
    }

    return result;
  }

  List<Mark> _flattenParseTreeMarks(Object? marks) {
    if (marks is StringMark) return [marks];
    if (marks is NamedMark) return [marks];
    if (marks is List<Object?>) return marks.expand((v) => _flattenParseTreeMarks(v)).toList();
    return [];
  }

  Object? _extractParseTreeMarks(ParseDerivation tree, String input) {
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
        return StringMark(tree.getMatchedText(input), tree.start);
      case "mar":
        return NamedMark(suffix, tree.start);
      case "alt":
      case "act":
      case "pre":
      case "cal":
      case "rca":
      case "rul":
        if (tree.children.isNotEmpty) {
          return _extractParseTreeMarks(tree.children[0], input);
        }
        return null;
      case "seq":
        final results = <Object?>[];
        for (final child in tree.children) {
          results.add(_extractParseTreeMarks(child, input));
        }
        return results;
      case "plu":
      case "sta":
        final results = <Object?>[];
        if (tree.children.isNotEmpty) {
          results.add(_extractParseTreeMarks(tree.children[0], input));
          if (tree.children.length > 1) {
            final rest = _extractParseTreeMarks(tree.children[1], input);
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
      case _:
        throw Error();
    }
  }

  Step _processToken(
    int? token,
    int position,
    List<Frame> frames, {
    String input = '',
    BsrSet? bsr,
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
  }) {
    // printDebug('Processing token $token at position $position with ${frames.length} frames');
    // Update global token history linked list
    if (token != null) {
      final node = TokenNode(token);
      if (_historyTail == null) {
        _historyTail = node;
      } else {
        _historyTail!.next = node;
        _historyTail = node;
      }
      _historyByPosition[position] = node;
    }

    // _historyByPosition updated via currentPosition check in lagging logic if needed
    // or handled by the Step constructor.
    if (_historyTail != null) {
      _historyByPosition[position] = _historyTail!;
    }

    final stepsAtPosition = <int, Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    void addFramesToQueue(List<Frame> newFrames) {
      for (final f in newFrames) {
        final pos = f.context.pivot ?? 0;
        workQueue.putIfAbsent(pos, () => []).add(f);
      }
    }

    addFramesToQueue(frames);

    while (workQueue.isNotEmpty) {
      final pos = workQueue.firstKey()!;
      if (pos > position) break; // Don't process ahead of current token

      final posFrames = workQueue.remove(pos)!;

      final currentStep = stepsAtPosition.putIfAbsent(pos, () {
        final posToken = (pos == position) ? token : _historyByPosition[pos]?.unit;
        return Step(
          this,
          posToken,
          pos,
          bsr: bsr,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
          requeue: addFramesToQueue, // Pass the adder directly
        );
      });

      for (final f in posFrames) {
        currentStep._processFrame(f);
      }

      // Check for exhausted predicates at this position
      printDebug('[DEBUG] === Checking exhausted predicates at position $pos ===');
      _checkExhaustedPredicates(workQueue, pos);

      if (pos < position) {
        addFramesToQueue(currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }
    }

    // Return the step for the current position so the parser can extract results
    return stepsAtPosition[position] ??
        Step(
          this,
          token,
          position,
          bsr: bsr,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
          requeue: addFramesToQueue, // Add required callback
        );
  }

  void _checkExhaustedPredicates(SplayTreeMap<int, List<Frame>> workQueue, int currentPosition) {
    printDebug(
      '[DEBUG] _checkExhaustedPredicates: checking ${_predicateTrackers.length} trackers at position=$currentPosition',
    );
    final toRemove = <(PatternSymbol, int)>{};
    for (final entry in _predicateTrackers.entries) {
      final tracker = entry.value;
      printDebug(
        '[DEBUG]   Tracker: pattern=${entry.key.$1}, pos=${entry.key.$2}, '
        'isAnd=${tracker.isAnd}, activeFrames=${tracker.activeFrames}, '
        'matched=${tracker.matched}, waitersCount=${tracker.waiters.length}',
      );

      if (tracker.activeFrames == 0 && !tracker.matched) {
        // Handle NOT predicate success (exhausted without match)
        printDebug('[DEBUG]     -> Exhausted without match (will trigger NOT predicates)');
        for (final (parentCtx, nextState) in tracker.waiters) {
          if (!tracker.isAnd) {
            printDebug('[DEBUG]       -> Requeueing NOT waiter');
            workQueue
                .putIfAbsent(currentPosition, () => [])
                .add(Frame(parentCtx)..nextStates.add(nextState));
          } else {
            printDebug('[DEBUG]       -> Skipping AND waiter (condition not met)');
          }
        }
        toRemove.add(entry.key);
      } else if (tracker.matched) {
        printDebug('[DEBUG]     -> Already matched');
        toRemove.add(entry.key);
      } else {
        printDebug('[DEBUG]     -> Still has active frames, keep waiting');
      }
    }
    for (final key in toRemove) {
      _predicateTrackers.remove(key);
    }
    printDebug('[DEBUG] _checkExhaustedPredicates: removed ${toRemove.length} trackers');
  }

  /// Check if a pattern matches at a given position in the input without consuming.
  /// Used for AND/NOT lookahead predicates.
  ///
  /// This is a fast check that determines if a pattern would match at startPos
  /// without actually advancing the parser state.
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

final class PredicateCallerKey extends CallerKey {
  final PatternSymbol pattern;
  final int startPos;

  const PredicateCallerKey(this.pattern, this.startPos);

  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKey && pattern == other.pattern && startPos == other.startPos;

  @override
  int get hashCode => Object.hash(pattern, startPos);
}

/// Caller tracking for rule returns (GSS node)
final class Caller extends CallerKey {
  final Rule rule;
  final Pattern pattern;
  final int startPos;
  final int? minPrecedenceLevel;

  /// Waiters in GSS: (parent caller, return state, min precedence, parent context)
  final List<(CallerKey?, State, int?, Context)> waiters = [];

  /// Recorded results (returns) for this caller
  final List<Context> returns = [];

  Caller(this.rule, this.pattern, this.startPos, this.minPrecedenceLevel);

  bool addWaiter(CallerKey? parent, State next, int? minPrec, Context cctx) {
    for (final w in waiters) {
      if (w.$1 == parent && w.$2 == next && w.$3 == minPrec && w.$4 == cctx) return false;
    }
    waiters.add((parent, next, minPrec, cctx));
    return true;
  }

  bool addReturn(Context ctx) {
    if (returns.contains(ctx)) return false;
    returns.add(ctx);
    return true;
  }

  void forEach(void Function(CallerKey?, State, int?, Context) callback) {
    for (final (key, state, minPrec, ctx) in waiters) {
      callback(key, state, minPrec, ctx);
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
class Context {
  /// The caller that created this context (for return actions).
  final CallerKey caller;

  /// The list of marks accumulated in this context.
  final GlushList<Mark> marks;

  /// The input position at which the rule associated with this context
  /// was invoked. Used to record BSR rule-completion entries.
  final int? callStart;

  /// The input position where the last matched symbol started.
  /// Used for midPoint in BSR nodes.
  final int? pivot;

  /// Pointer to the token history node for this context's current position.
  final TokenNode? tokenHistory;

  /// Minimum precedence level required for a return to be accepted.
  final int? minPrecedenceLevel;

  /// The precedence level of the result matched by this context.
  final int? precedenceLevel;

  /// Stack of active lookahead predicates.
  final GlushList<PredicateFrame> predicateStack;

  const Context(
    this.caller,
    this.marks, {
    this.callStart,
    this.pivot,
    this.tokenHistory,
    this.minPrecedenceLevel,
    this.precedenceLevel,
    this.predicateStack = const GlushList.empty(),
  });

  Context copyWith({
    CallerKey? caller,
    GlushList<Mark>? marks,
    int? callStart,
    int? pivot,
    TokenNode? tokenHistory,
    int? minPrecedenceLevel,
    int? precedenceLevel,
    GlushList<PredicateFrame>? predicateStack,
  }) {
    return Context(
      caller ?? this.caller,
      marks ?? this.marks,
      callStart: callStart ?? this.callStart,
      pivot: pivot ?? this.pivot,
      tokenHistory: tokenHistory ?? this.tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
      predicateStack: predicateStack ?? this.predicateStack,
    );
  }
}

/// A frame in the predicate stack, tracking a lookahead sub-parse.
class PredicateFrame {
  final Pattern pattern;
  final int startPos;
  final bool isAnd;

  const PredicateFrame(this.pattern, this.startPos, {required this.isAnd});
}

/// Frame for managing parsing states
class Frame {
  final Context context;
  final Set<State> nextStates;

  Frame(this.context) : nextStates = {};

  Frame copy() => Frame(context);

  CallerKey? get caller => context.caller;
  GlushList<Mark> get marks => context.marks;
}

/// Single step in parsing
class Step {
  static const int maxWorkListSize = 100000;
  static const int maxActiveContexts = 50000;

  final SMParser parser;
  final int? token;
  final int position;

  /// Optional BSR set to populate with rule-completion entries. When null,
  /// BSR recording is skipped (used by the plain recognize/parse paths).
  final BsrSet? bsr;

  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final GlushListManager<Mark> markManager;

  final List<Frame> nextFrames = [];
  final Map<(State, CallerKey, int?), List<GlushList<Mark>>> _nextFrameGroups = {};
  final Map<(State, CallerKey, int?), GlushList<Mark>> _activeContexts = {};
  final List<(State, Context)> _currentWorkList = [];

  final Map<(Rule, Pattern), Caller> _callers = {};
  final Set<CallerKey> _returnedCallers = {};
  final List<Context> _acceptedContexts = [];

  void _finishPredicate(PredicateTracker tracker, bool matched) {
    printDebug(
      '[DEBUG] _finishPredicate: '
      'tracker.isAnd=${tracker.isAnd}, '
      'matched=$matched, '
      'tracker.matched=${tracker.matched}, '
      'activeFrames=${tracker.activeFrames}, '
      'waitersCount=${tracker.waiters.length}',
    );

    if (tracker.matched) {
      printDebug('[DEBUG] _finishPredicate: Already matched, returning early');
      return;
    }
    if (matched) {
      printDebug(
        '[DEBUG] _finishPredicate: Matched! isAnd=${tracker.isAnd}, requeueing ${tracker.waiters.length} waiters',
      );
      tracker.matched = true;
      for (final (parentCtx, nextState) in tracker.waiters) {
        // Transfer active frame status from waiter back to worklist or drop
        if (parentCtx.caller case PredicateCallerKey pk) {
          final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
          parentTracker?.activeFrames--;
        }

        if (tracker.isAnd) {
          printDebug('[DEBUG] _finishPredicate: Requeueing waiter for AND predicate');
          requeue([Frame(parentCtx)..nextStates.add(nextState)]);
        }
      }
      tracker.waiters.clear(); // Clear to avoid double resume if exhausted happens later
    } else if (tracker.activeFrames == 0) {
      // Exhausted without matching
      printDebug(
        '[DEBUG] _finishPredicate: Exhausted without match! isAnd=${tracker.isAnd}, requeueing ${tracker.waiters.length} waiters',
      );
      for (final (parentCtx, nextState) in tracker.waiters) {
        // Transfer active frame status from waiter back to worklist or drop
        if (parentCtx.caller case PredicateCallerKey pk) {
          final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
          parentTracker?.activeFrames--;
        }

        if (!tracker.isAnd) {
          printDebug('[DEBUG] _finishPredicate: Requeueing waiter for NOT predicate');
          requeue([Frame(parentCtx)..nextStates.add(nextState)]);
        }
      }
      tracker.waiters.clear();
    }
  }

  final void Function(List<Frame>) requeue;

  Step(
    this.parser,
    this.token,
    this.position, {
    this.bsr,
    required this.markManager,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    required this.requeue,
  });

  /// Get the token that a specific frame should see.
  /// If the frame is at the current parsing position, it sees the current token.
  /// If it's lagging, it sees the next token from history.
  int? _getTokenFor(Frame frame) {
    final framePos = frame.context.pivot ?? 0;
    if (framePos == position) {
      return token;
    }
    return parser._historyByPosition[framePos]?.unit;
  }

  bool get accept => _acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    if (_acceptedContexts.isEmpty) return [];
    final markList = _acceptedContexts[0].marks;
    return markList.toList().cast<Mark>();
  }

  // _withFrame removed. Use Frame(context) directly.

  void _enqueue(State state, Context context) {
    if (_currentWorkList.length > maxWorkListSize) {
      throw Exception(
        'SMParser: Memory protection triggered - too many work items ($maxWorkListSize)',
      );
    }
    // Track active frames for predicate sub-parses
    if (context.caller case PredicateCallerKey pk) {
      final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
      if (tracker != null) {
        tracker.activeFrames++;
        printDebug(
          '[DEBUG] _enqueue: PredicateCallerKey frame enqueued! '
          'pattern=${pk.pattern}, startPos=${pk.startPos}, '
          'activeFrames now=${tracker.activeFrames}',
        );
      } else {
        printDebug(
          '[DEBUG] _enqueue: PredicateCallerKey frame but NO TRACKER! '
          'pattern=${pk.pattern}, startPos=${pk.startPos}',
        );
      }
    }

    final key = (state, context.caller, context.minPrecedenceLevel);
    if (isSupportingAmbiguity) {
      final existingMarks = _activeContexts[key];
      if (existingMarks != null) {
        final merged = markManager.branched([existingMarks, context.marks]);
        if (merged == existingMarks) return;
        _activeContexts[key] = merged;
        _currentWorkList.add((
          state,
          Context(
            context.caller,
            merged,
            callStart: context.callStart,
            pivot: context.pivot,
            tokenHistory: context.tokenHistory,
            minPrecedenceLevel: context.minPrecedenceLevel,
          ),
        ));
        return;
      }
      _activeContexts[key] = context.marks;
    } else {
      // In non-ambiguous mode, if we already reached this state/caller, we skip
      if (_activeContexts.containsKey(key)) return;
      if (_activeContexts.length > maxActiveContexts) {
        throw Exception(
          'SMParser: Memory protection triggered - too many states per position ($maxActiveContexts)',
        );
      }
      _activeContexts[key] = context.marks;
    }
    _currentWorkList.add((state, context));
  }

  void _process(Frame frame, State state) {
    final isPredicateFrame = frame.context.caller is PredicateCallerKey;
    if (isPredicateFrame || state.id == 0 || state.id == 2) {
      final actionIds = state.actions
          .map((a) {
            if (a case PredicateAction(:var isAnd, :var nextState))
              return 'Predicate(isAnd=$isAnd, next=${nextState.id})';
            if (a case SemanticAction(:var nextState)) return 'Semantic(next=${nextState.id})';
            if (a case TokenAction()) return 'Token(${a.pattern})';
            if (a case CallAction()) return 'Call';
            if (a case ReturnAction()) return 'Return';
            if (a case AcceptAction()) return 'Accept';
            if (a case MarkAction()) return 'Mark';
            return a.runtimeType.toString();
          })
          .join(', ');
      printDebug(
        '[DEBUG] _process: state=${state.id}, actions=${state.actions.length}, isPredicateFrame=$isPredicateFrame, actionList=[$actionIds]',
      );
    }
    for (final action in state.actions) {
      if (isPredicateFrame) {
        printDebug('[DEBUG]   -> Processing action: ${action.runtimeType}');
      }
      switch (action) {
        case SemanticAction():
          final semanticCtx = Context(
            frame.caller ?? const RootCallerKey(),
            frame.marks,
            callStart: frame.context.callStart,
            pivot: frame.context.pivot,
            tokenHistory: frame.context.tokenHistory,
          );

          _enqueue(action.nextState, semanticCtx);
        case TokenAction():
          final token = _getTokenFor(frame);
          final tokenChar = token != null ? String.fromCharCode(token) : 'null';
          final patternStr = action.pattern.toString();
          final isPredicateFrame = frame.context.caller is PredicateCallerKey;

          if (isPredicateFrame || frame.caller is Caller) {
            printDebug(
              '[DEBUG]   TokenAction: pattern=$patternStr, token=$tokenChar (code=$token), position=$position, nextState=${action.nextState.id}, isPredicateFrame=$isPredicateFrame',
            );
          }

          if (token != null && action.pattern.match(token)) {
            if (isPredicateFrame || frame.caller is Caller) {
              printDebug(
                '[DEBUG]     -> MATCH! Adding frame with nextState=${action.nextState.id} to nextFrameGroups',
              );
            }

            var newMarks = frame.marks;
            if (captureTokensAsMarks) {
              // Optional: capture all tokens as marks for debugging/forest extraction
              final strMark = StringMark(String.fromCharCode(token), position);
              newMarks = newMarks.add(markManager, strMark);
            } else if (action.pattern case Token(:var choice) when choice is! ExactToken) {
              // Standard behavior: capture ranges/any tokens
              final strMark = StringMark(String.fromCharCode(token), position);
              newMarks = newMarks.add(markManager, strMark);
            }

            final bsrSet = bsr;
            if (bsrSet != null && frame.caller is Caller) {
              final rule = (frame.caller as Caller).rule;
              bsrSet.add(rule.symbolId!, frame.context.callStart!, position, position + 1);
            }

            final nextKey = (
              action.nextState,
              frame.caller ?? const RootCallerKey(),
              frame.context.minPrecedenceLevel,
            );
            _nextFrameGroups.putIfAbsent(nextKey, () => []).add(newMarks);
          } else {
            if (isPredicateFrame || frame.caller is Caller) {
              printDebug(
                '[DEBUG]     -> NO MATCH (token=$token vs pattern expects=${action.pattern}). No frame queued!',
              );
            }
          }
        case MarkAction():
          final mark = NamedMark(action.name, position);
          final markCtx = Context(
            frame.caller ?? const RootCallerKey(),
            frame.marks.add(markManager, mark),
            callStart: frame.context.callStart,
            pivot: frame.context.pivot,
            tokenHistory: frame.context.tokenHistory,
          );

          final bsrSet = bsr;
          if (bsrSet != null && frame.caller is Caller) {
            final rule = (frame.caller as Caller).rule;
            bsrSet.add(rule.symbolId!, frame.context.callStart!, position, position);
          }

          _enqueue(action.nextState, markCtx);
        case PredicateAction():
          // Predicate checking as an integrated sub-parse
          final symbol = action.symbol;
          final subParseKey = (symbol, position);

          final isFirst = !parser._predicateTrackers.containsKey(subParseKey);
          final tracker = parser._predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTracker(symbol, position, isAnd: action.isAnd),
          );
          tracker.waiters.add((frame.context, action.nextState));

          // Maintain activeFrames count for parent predicate if we are in a sub-parse
          if (frame.context.caller case PredicateCallerKey pk) {
            final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
            parentTracker?.activeFrames++;
          }

          printDebug(
            '[DEBUG] PredicateAction started: '
            'isAnd=${action.isAnd}, '
            'symbol=$symbol, '
            'position=$position, '
            'isFirst=$isFirst, '
            'waitersCount=${tracker.waiters.length}',
          );

          if (isFirst) {
            final predicateCaller = PredicateCallerKey(symbol, position);
            final predicateCtx = Context(
              predicateCaller,
              const GlushList.empty(),
              callStart: position,
              pivot: position,
              tokenHistory: frame.context.tokenHistory,
            );

            printDebug('[DEBUG] PredicateAction - Starting sub-parse for symbol=$symbol');

            // The symbol in PredicateAction is now always the Rule's symbol ID
            final states = parser.stateMachine.ruleFirst[symbol];
            if (states != null) {
              for (final firstState in states) {
                _enqueue(firstState, predicateCtx);
              }
            } else {
              throw StateError(
                'Predicate symbol must resolve to a rule with first states: $symbol',
              );
            }
          }
        case CallAction():
          final rule = action.rule;
          final pattern = action.pattern;
          final key = (rule, pattern);

          printDebug('[DEBUG] CallAction: rule=${rule.name}, returnState=${action.returnState}');

          final isNewCaller = !_callers.containsKey(key);
          final caller = _callers.putIfAbsent(
            key,
            () => Caller(rule, pattern, position, action.minPrecedenceLevel),
          );

          final isNewWaiter = caller.addWaiter(
            frame.caller,
            action.returnState,
            action.minPrecedenceLevel,
            frame.context,
          );

          if (isNewCaller) {
            final callCtx = Context(
              caller,
              const GlushList.empty(),
              callStart: position,
              pivot: position,
              tokenHistory: frame.context.tokenHistory,
              minPrecedenceLevel: action.minPrecedenceLevel,
            );
            printDebug('[DEBUG]   CallAction: Starting first states of rule=${rule.name}');
            for (final firstState in parser.stateMachine.ruleFirst[rule.symbolId!] ?? []) {
              _enqueue(firstState, callCtx);
            }
          } else if (isNewWaiter) {
            // Replay existing returns for this new waiter
            for (final rctx in caller.returns) {
              _triggerReturn(
                caller,
                frame.caller,
                action.returnState,
                action.minPrecedenceLevel,
                frame.context,
                rctx,
              );
            }
          }
        case ReturnAction():
          final rule = action.rule;
          final token = _getTokenFor(frame);

          // Precedence Filtering
          final minPrec = frame.context.minPrecedenceLevel;
          final prec = action.precedenceLevel;

          if (minPrec != null && prec != null && prec < minPrec) {
            continue;
          }

          if (token != null && rule.guard != null && !rule.guard!.match(token)) {
            continue;
          }

          final caller = frame.caller;
          final callStart = frame.context.callStart ?? (caller is Caller ? caller.startPos : null);
          final lastPivot = frame.context.pivot;
          if ((bsr, callStart, lastPivot ?? callStart) case (
            var bsr?,
            var callStart?,
            var pivot?,
          )) {
            bsr.add(rule.symbolId!, callStart, pivot, position);
          }

          if (caller is PredicateCallerKey) {
            final subParseKey = (caller.pattern, caller.startPos);
            final tracker = parser._predicateTrackers[subParseKey];

            printDebug(
              '[DEBUG] ReturnAction from PredicateCallerKey: '
              'rule=${rule.name}, '
              'pattern=${caller.pattern}, '
              'startPos=${caller.startPos}, '
              'position=$position, '
              'has tracker=${tracker != null}',
            );

            if (tracker != null) {
              printDebug('[DEBUG] ReturnAction: Calling _finishPredicate with matched=true');
              _finishPredicate(tracker, true);
            }
            continue;
          }

          final bsrSet = bsr;
          if (bsrSet != null && caller is Caller) {
            caller.forEach((ccaller, nextState, minPrec, ccontext) {
              if (ccaller is Caller) {
                bsrSet.add(ccaller.rule.symbolId!, ccontext.callStart!, caller.startPos, position);
              }
            });
          }

          if (!isSupportingAmbiguity && !_returnedCallers.add(caller ?? const RootCallerKey())) {
            continue;
          }

          if (caller is Caller) {
            final returnCtx = frame.context.copyWith(precedenceLevel: prec);
            if (caller.addReturn(returnCtx)) {
              for (final waiter in caller.waiters) {
                _triggerReturn(caller, waiter.$1, waiter.$2, waiter.$3, waiter.$4, returnCtx);
              }
            }
          }
        case AcceptAction():
          printDebug(
            '[DEBUG]   AcceptAction: ACCEPTING! position=$position, caller=${frame.context.caller.runtimeType}',
          );
          _acceptedContexts.add(frame.context);
      }
    }
  }

  void _triggerReturn(
    Caller caller,
    CallerKey? parent,
    State nextState,
    int? minPrec,
    Context parentCtx,
    Context returnCtx,
  ) {
    final effectiveParent = parent ?? const RootCallerKey();

    if (minPrec != null &&
        returnCtx.precedenceLevel != null &&
        returnCtx.precedenceLevel! < minPrec) {
      return;
    }

    final nextMarks = markManager.branched([parentCtx.marks]).addList(markManager, returnCtx.marks);
    final nextContext = Context(
      effectiveParent,
      nextMarks,
      callStart: parentCtx.callStart,
      pivot: position,
      tokenHistory: parentCtx.tokenHistory,
      // FIX: Keep parent's constraint
      minPrecedenceLevel: parentCtx.minPrecedenceLevel,
    );

    // For BSR recording
    final bsrSet = bsr;
    if (bsrSet != null && parent is Caller) {
      bsrSet.add(parent.rule.symbolId!, parentCtx.callStart!, caller.startPos, position);
    }

    _enqueue(nextState, nextContext);
  }

  void _finalize() {
    printDebug('[DEBUG] _finalize called: nextFrameGroups has ${_nextFrameGroups.length} entries');
    for (final MapEntry(
          key: (State state, CallerKey caller, int? minPrecedenceLevel),
          value: markLists,
        )
        in _nextFrameGroups.entries) {
      final callerType = caller.runtimeType.toString();
      final isPredicateCaller = caller is PredicateCallerKey;
      printDebug(
        '[DEBUG]   finalize entry: state=${state.id}, caller=$callerType, '
        'isPredicateCaller=$isPredicateCaller, markListsCount=${markLists.length}',
      );

      final mergedMarks = markManager.branched(markLists);
      final nextTokenHistory = parser._historyByPosition[position];

      int? nextCallStart;
      if (caller is Caller) {
        nextCallStart = caller.startPos;
      } else if (caller is RootCallerKey) {
        nextCallStart = 0;
      }

      final nextFrame = Frame(
        Context(
          caller,
          mergedMarks,
          callStart: nextCallStart,
          pivot: position + 1,
          tokenHistory: nextTokenHistory,
          minPrecedenceLevel: minPrecedenceLevel,
        ),
      );
      nextFrame.nextStates.add(state);

      // Track active frames for predicate sub-parses
      if (caller case PredicateCallerKey pk) {
        final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
        if (tracker != null) {
          tracker.activeFrames++;
          printDebug(
            '[DEBUG]   finalize: PredicateCallerKey frame promoted to nextFrames! '
            'pattern=${pk.pattern}, startPos=${pk.startPos}, '
            'activeFrames now=${tracker.activeFrames}',
          );
        }
      }

      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
    printDebug('[DEBUG] _finalize done: nextFrames.length=${nextFrames.length}');
  }

  void _processFrame(Frame frame) {
    final isPredicateCtx = frame.context.caller is PredicateCallerKey;
    if (isPredicateCtx || frame.nextStates.length > 1) {
      printDebug(
        '[DEBUG] _processFrame: frame has ${frame.nextStates.length} nextStates: ${frame.nextStates.map((s) => "state=${s.id}").join(", ")}',
      );
    }
    for (final state in frame.nextStates) {
      _enqueue(state, frame.context);
    }

    while (_currentWorkList.isNotEmpty) {
      final (state, context) = _currentWorkList.removeAt(0);
      final isWorkListPredicateFrame = context.caller is PredicateCallerKey;
      printDebug(
        '[DEBUG]   WorkList item: state=${state.id}, caller=${context.caller.runtimeType}, '
        'isPredicateCaller=$isWorkListPredicateFrame',
      );

      // Decrement activeFrames when processing
      if (context.caller case PredicateCallerKey pk) {
        final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
        if (tracker != null) {
          tracker.activeFrames--;
          printDebug('[DEBUG]     Decrementing activeFrames to ${tracker.activeFrames}');
        }
      }

      final key = (state, context.caller, context.minPrecedenceLevel);
      final currentMarks = isSupportingAmbiguity ? _activeContexts[key]! : context.marks;
      final effectiveContext = Context(
        context.caller,
        currentMarks,
        callStart: context.callStart,
        pivot: context.pivot,
        tokenHistory: context.tokenHistory,
        minPrecedenceLevel: context.minPrecedenceLevel,
      );
      _process(Frame(effectiveContext), state);
    }
    _finalize();
  }

  void addFrame(Context context, State state) {
    _enqueue(state, context);
  }
}
