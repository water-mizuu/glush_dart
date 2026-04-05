// ignore_for_file: comment_references

/// State machine-based parser implementation.
///
/// This module implements the core parsing engine for the Glush parser generator.
/// It converts an abstract grammar into a state machine and uses an LR-like algorithm
/// with support for:
/// - Recursive descent rule calls with Graph-Shared Stack (GSS) memoization
/// - Lookahead predicates for positive (&pattern) and negative (!pattern) assertions
/// - Operator precedence filtering for shift/reduce disambiguation
/// - Semantic actions and manual annotations (marks)
/// - Ambiguous parse paths
///
/// Key Classes:
/// - SMParser: Main parser interface with multiple parse methods
/// - Context: Parsing state carrying marks, caller info, and constraints
/// - Frame: A set of states to explore from a context
/// - Step: Processing state at a single input position
/// - Caller: Graph-Shared Stack node for rule call memoization
/// - PredicateTracker: Coordinator for lookahead predicate sub-parses
///
/// Parse Methods:
/// 1. recognize(): Boolean check (fastest)
/// 2. parse(): Marks-based parse with results
/// 3. parseAmbiguous(): All ambiguous interpretations merged
///
/// The parser uses a work-queue algorithm where frames at different input positions
/// can coexist, enabling proper handling of predicates without backtracking.
library glush.sm_parser;

import "package:glush/glush.dart" show StateMachine;
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_derivation.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/common/parser_base.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:glush/src/parser/state_machine/state_machine_export.dart";
import "package:glush/src/representation/evaluator.dart";

/// Main parser implementation using a state machine-based LR-like algorithm.
///
/// Converts an abstract grammar into a state machine (StateMachine) and drives
/// parsing using operator precedence filtering, memoization, and predicates.
/// Supports multiple parse modes: basic recognition and mark-based results.
///
/// Key capabilities:
/// - Fast [recognize] for boolean checks
/// - Marks-based [parse] for semantic annotations
/// - [parseAmbiguous] for ambiguity detection
/// - Lookahead predicates (&pattern, !pattern) for grammar constraints
/// - Operator precedence filtering for shift/reduce disambiguation
/// - Graph-Shared Stack (GSS) memoization for efficient rule processing
///
/// Critical for parsing complex grammars efficiently with support for
/// ambiguity and semantic actions.
final class SMParser extends GlushParserBase implements RecognizerAndMarksParser {
  /// Create a parser from a grammar.
  ///
  /// Builds the state machine on first use and initializes the parser state.
  /// The parser can then be reused across multiple parse() calls on different inputs.
  SMParser(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar);

  SMParser.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false});

  /// Create a parser from an imported state machine JSON.
  ///
  /// Quickly reconstructs a parser from a previously exported state machine
  /// without requiring grammar recompilation. Useful for production environments
  /// where fast startup is needed.
  ///
  /// Parameters:
  ///   [jsonString] - The exported state machine JSON from [StateMachine.exportToJson]
  ///   [grammar] - The grammar interface associated with this machine
  ///   [captureTokensAsMarks] - Whether to capture tokens as marks during parsing
  ///
  /// Returns:
  ///   An SMParser ready for immediate use
  factory SMParser.fromImported(String jsonString, [GrammarInterface? grammar]) {
    var stateMachine = importFromJson(jsonString, grammar);
    return SMParser.fromStateMachine(stateMachine);
  }

  static final Context _initialContext = Context(const RootCallerKey());

  /// The state machine constructed from the grammar.
  @override
  final StateMachine stateMachine;

  @override
  bool captureTokensAsMarks;

  /// Returns the grammar used to construct this parser's state machine.
  @override
  GrammarInterface get grammar => stateMachine.grammar;

  /// Render the parser's compiled state machine as Graphviz DOT.
  String toDot() => stateMachine.toDot();

  @override
  List<Frame> get initialFrames {
    var initialFrame = Frame(_initialContext, const GlushList.empty());
    initialFrame.nextStates.addAll(stateMachine.initialStates);

    return [initialFrame];
  }

  /// Recognize input without building a parse tree (boolean result).
  ///
  /// Fast path that only checks if the input matches, without marking or
  /// other semantic computation. This method must remain independent of the
  /// BSR/SPPF pipeline and rely only on the State Machine execution and mark
  /// bookkeeping. Returns true iff the entire input is accepted.
  @override
  bool recognize(String input) {
    return GlushProfiler.measure("parser.recognize", () {
      var parseState = createParseState(captureTokensAsMarks: captureTokensAsMarks);

      for (var codepoint in input.codeUnits) {
        parseState.processToken(codepoint);
        // If no frames remain, the parser cannot recover from this prefix.
        if (parseState.frames.isEmpty) {
          return false;
        }
      }

      return parseState.finish().accept;
    });
  }

  /// Parse input and return a [ParseSuccess] or [ParseError].
  ///
  /// This is the basic parsing method: runs the state machine on the input
  /// and returns true only if the entire input is accepted. This method must
  /// remain independent of the BSR/SPPF pipeline and rely only on the State
  /// Machine's marks system.
  ///
  /// Returns:
  /// - [ParseSuccess] if the entire input matches the grammar
  /// - [ParseError] if parsing fails at some position
  @override
  ParseOutcome parse(String input, {bool? captureTokensAsMarks}) {
    return GlushProfiler.measure("parser.parse", () {
      var parseState = createParseState(
        captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
      );

      for (var codepoint in input.codeUnits) {
        parseState.processToken(codepoint);
        // No active frames means the parse has already failed.
        if (parseState.frames.isEmpty) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();
      // Only a final accepted step counts as a successful parse.
      if (lastStep.accept) {
        var results = lastStep.acceptedContexts.values.first;
        var onlyPath = results.allPaths().first;

        return ParseSuccess(ParserResult(onlyPath));
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Parse input and return all ambiguous derivation paths.
  ///
  /// Like [parse], but records marks for all possible interpretations.
  /// In ambiguity mode, when multiple [state, caller, minPrec] tuples reach
  /// the same point, their mark lists are merged instead of deduplicated.
  /// This method must remain independent of the BSR/SPPF pipeline and derive
  /// ambiguity purely from the State Machine's marks system.
  ///
  /// Returns:
  /// - [ParseAmbiguousSuccess] if input matches (all interpretations merged)
  /// - [ParseError] if parsing fails
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    return GlushProfiler.measure("parser.parse_ambiguous", () {
      var shouldCapture = captureTokensAsMarks ?? this.captureTokensAsMarks;
      var parseState = createParseState(
        isSupportingAmbiguity: true,
        captureTokensAsMarks: shouldCapture,
      );

      for (var codepoint in input.codeUnits) {
        parseState.processToken(codepoint);
        // No active frames means the parse has already failed.
        if (parseState.frames.isEmpty) {
          return ParseError(parseState.position - 1);
        }
      }

      var lastStep = parseState.finish();

      // Ambiguous mode merges all accepted mark branches into one result.
      if (lastStep.accept) {
        var results = lastStep.acceptedContexts.values.toList();
        var branches = results.fold(const GlushList<Mark>.empty(), GlushList.branched);

        return ParseAmbiguousSuccess(branches);
      } else {
        return ParseError(parseState.position);
      }
    });
  }

  /// Count all possible parse trees without building them
  /// Internally count all derivations for a given input.
  ///
  /// Counts all possible parse trees without building them. Based on []
  /// and grammar-level recursion with memoization. Useful for understanding
  /// parser ambiguity without memory overhead.
  int countAllParses(String input) {
    var startSymbol = stateMachine.grammar.startSymbol;
    return _countDerivations(startSymbol, input, 0, input.length, {}, {});
  }

  /// Count the total number of parse trees for a rule without building them.
  ///
  /// This traverses the grammar recursively with memoization to count all possible
  /// derivations for a symbol spanning [start:end] in the input.
  ///
  /// The inProgress map detects cycles (left-recursive patterns) and breaks them
  /// by returning 0 when a cycle is detected. This prevents infinite loops.
  ///
  /// Used by [countAllParses] to give insight into parse ambiguity without
  /// the memory cost of building all trees.
  int _countDerivations(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    var key = "$symbol:$start:$end";

    if (memo.containsKey(key)) {
      return memo[key]!;
    }

    if (inProgress[key] == true) {
      return 0; // Avoid cycles
    }

    inProgress[key] = true;
    int totalCount = 0;

    var children = grammar.childrenRegistry[symbol] ?? [];

    if (symbol.symbol.startsWith("rul:")) {
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

  /// Count all derivations for a single pattern (matched against input[start:end]).
  ///
  /// Dispatches based on the pattern type:
  /// - eps: epsilon (empty) matches iff start == end
  /// - tok: token matches based on the token constraint (exact, range, etc.)
  /// - mar: marker (semantic annotation) matches iff start == end
  /// - alt: alternative - count both branches and sum
  /// - seq: sequence - sum over all split points (Earley-style)
  /// - plu: one-or-more - count one match, then star matches
  /// - sta: star - delegate to _countStar
  /// - cal/rca/rul/act: wrapper patterns - recurse on child
  /// - and/not: predicates - check child at start, return 1 or 0
  ///
  /// This structure mirrors the grammar representation where each pattern type
  /// has a defined strategy for counting derivations.
  int _countAlternatives(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, int> memo,
    Map<String, bool> inProgress,
  ) {
    var pattern = symbol.symbol;
    var children = grammar.childrenRegistry[symbol] ?? [];
    var split = pattern.split(":");
    if (split.length < 3) {
      return 0;
    }
    var [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          return start == end ? 1 : 0;
        }
      case "bos":
        {
          return start == end && start == 0 ? 1 : 0;
        }
      case "eof":
        {
          return start == end && end == input.length ? 1 : 0;
        }
      case "tok":
        {
          if (start + 1 != end) {
            return 0;
          }
          var unit = input.codeUnitAt(start);
          bool isMatching = switch (suffix[0]) {
            "." => true,
            ";" => unit == int.parse(suffix.substring(1)),
            "<" => unit <= int.parse(suffix.substring(1)),
            ">" => unit >= int.parse(suffix.substring(1)),
            "[" => () {
              var parts = suffix.substring(1).split(",");
              var min = int.parse(parts[0]);
              var max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
          return isMatching ? 1 : 0;
        }
      case "mar":
        return start == end ? 1 : 0;
      case "las":
      case "lae":
        return start == end ? 1 : 0;
      case "alt":
        return _countAlternatives(children.first, input, start, end, memo, inProgress) +
            _countAlternatives(children.last, input, start, end, memo, inProgress);
      case "lab":
        return _countAlternatives(children.single, input, start, end, memo, inProgress);
      case "opt":
        {
          var childCount = _countAlternatives(children.single, input, start, end, memo, inProgress);
          if (childCount > 0) {
            return childCount;
          }
          return start == end ? 1 : 0;
        }
      case "seq":
        {
          int totalCount = 0;
          for (int mid = start; mid <= end; mid++) {
            var leftCount = _countAlternatives(children.first, input, start, mid, memo, inProgress);
            if (leftCount > 0) {
              var rightCount = _countAlternatives(children.last, input, mid, end, memo, inProgress);
              totalCount += leftCount * rightCount;
            }
          }
          return totalCount;
        }
      case "sta":
        return _countRepetition(
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: false,
        );
      case "plu":
        return _countRepetition(
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: true,
        );
      case "rca" || "rul" || "act" || "pre":
        return _countDerivations(children.single, input, start, end, memo, inProgress);
      case "and":
      case "not":
        if (start == end) {
          var childCount = _countDerivations(
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
      case "neg":
        {
          var childCount = _countDerivations(children.single, input, start, end, memo, inProgress);
          return childCount == 0 ? 1 : 0;
        }
      case "con":
        {
          var leftCount = _countAlternatives(children.first, input, start, end, memo, inProgress);
          if (leftCount == 0) {
            return 0;
          }
          var rightCount = _countAlternatives(children.last, input, start, end, memo, inProgress);
          return leftCount * rightCount;
        }
      default:
        return 0;
    }
  }

  int _countRepetition({
    required PatternSymbol symbol,
    required PatternSymbol child,
    required String input,
    required int start,
    required int end,
    required Map<String, int> memo,
    required Map<String, bool> inProgress,
    required bool isPlus,
  }) {
    int totalCount = 0;

    if (!isPlus && start == end) {
      totalCount += 1;
    }

    if (isPlus) {
      totalCount += _countAlternatives(child, input, start, end, memo, inProgress);
    }

    // Force progress in the recursive branch to avoid epsilon loops.
    for (int mid = start + 1; mid <= end; mid++) {
      var leftCount = _countAlternatives(child, input, start, mid, memo, inProgress);
      if (leftCount == 0) {
        continue;
      }
      var rightCount = _countAlternatives(symbol, input, mid, end, memo, inProgress);
      totalCount += leftCount * rightCount;
    }

    return totalCount;
  }

  /// Enumerate all parse derivations for a rule (or pattern with rules).
  ///
  /// Uses the BSR (Binarised Shared Representation) to constrain search:
  /// only explores spans that the parser proved reachable.
  ///
  /// For rules, delegates to [_enumerateAlternatives] on the rule's body.
  /// For other patterns, directly enumerates.
  ///
  /// Memoization prevents redundant work; in-progress tracking detects cycles
  /// (which should not occur in grammars, but is defensive).
  ///
  /// Respects minPrecedenceLevel constraints for operator precedence filtering.
  Iterable<ParseDerivation> _enumerateDerivations(
    PatternSymbol symbol,
    int start,
    int end,
    String input,
    Map<String, List<ParseDerivation>?> memo, {
    int? minPrecedenceLevel,
    Map<String, bool>? inProgress,
  }) sync* {
    var key = '$symbol:$start:$end:${minPrecedenceLevel ?? ""}';
    if (memo.containsKey(key)) {
      var results = memo[key];
      if (results != null) {
        yield* results;
      }
      return;
    }

    inProgress ??= {};
    if (inProgress[key] == true) {
      return;
    }

    inProgress[key] = true;

    // For rules or other patterns, we check their children
    var children = grammar.childrenRegistry[symbol] ?? [];

    if (symbol.symbol.startsWith("rul:")) {
      // It's a rule, evaluate its body (the single child)
      if (children.isNotEmpty) {
        yield* _enumerateAlternatives(
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

  /// Enumerate all derivations for a single pattern.
  ///
  /// Like [_countAlternatives], dispatches based on pattern type:
  /// - Yields all (symbol, start, end, children) combinations
  /// - For seq, tries all split points and yields cartesian product of children
  /// - For plu/sta, yields hierarchical tree structures
  /// - For predicates (and/not), yields single-node trees
  /// - Respects minPrecedenceLevel for filtering
  ///
  /// The resulting [ParseDerivation] trees can be transformed to intermediate
  /// representations or evaluated to semantic values.
  Iterable<ParseDerivation> _enumerateAlternatives(
    PatternSymbol symbol,
    String input,
    int start,
    int end,
    Map<String, List<ParseDerivation>?> memo,
    Map<String, bool> inProgress, {
    int? minPrecedenceLevel,
  }) sync* {
    var pattern = symbol.symbol;
    var children = grammar.childrenRegistry[symbol] ?? [];
    var split = pattern.split(":");
    if (split.length < 3) {
      return;
    }
    var [prefix, _, suffix] = split;

    switch (prefix) {
      case "eps":
        {
          if (start == end) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "bos":
        {
          if (start == end && start == 0) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "eof":
        {
          if (start == end && end == input.length) {
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
              var unit = input.codeUnitAt(start);
              var parts = suffix.substring(1).split(",");
              var min = int.parse(parts[0]);
              var max = int.parse(parts[1]);
              return min <= unit && unit <= max;
            }(),
            _ => false,
          };
          if (start + 1 == end && isMatching) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "mar":
        if (start == end) {
          yield ParseDerivation(symbol, start, end, []);
        }
      case "las":
      case "lae":
        if (start == end) {
          yield ParseDerivation(symbol, start, end, []);
        }
      case "pre":
        {
          var prec = int.parse(suffix);
          if (minPrecedenceLevel != null && prec < minPrecedenceLevel) {
            return;
          }
          yield* _enumerateAlternatives(
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
            children.first,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
          yield* _enumerateAlternatives(
            children.last,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          );
        }
      case "lab":
        {
          for (var child in _enumerateAlternatives(
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
        }
      case "opt":
        {
          var childList = _enumerateAlternatives(
            children.single,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          ).toList();
          if (childList.isNotEmpty) {
            for (var child in childList) {
              yield ParseDerivation(symbol, start, end, [child]);
            }
          } else if (start == end) {
            yield ParseDerivation(symbol, start, end, []);
          }
        }
      case "seq":
        {
          for (int mid = start; mid <= end; mid++) {
            var leftList = _enumerateAlternatives(
              children.first,
              input,
              start,
              mid,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (leftList.isEmpty) {
              continue;
            }

            var rightList = _enumerateAlternatives(
              children.last,
              input,
              mid,
              end,
              memo,
              inProgress,
              minPrecedenceLevel: minPrecedenceLevel,
            ).toList();
            if (rightList.isEmpty) {
              continue;
            }

            for (var left in leftList) {
              for (var right in rightList) {
                yield ParseDerivation(symbol, start, end, [left, right]);
              }
            }
          }
        }
      case "sta":
        yield* _enumerateRepetition(
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: false,
          minPrecedenceLevel: minPrecedenceLevel,
        );
      case "plu":
        yield* _enumerateRepetition(
          symbol: symbol,
          child: children.single,
          input: input,
          start: start,
          end: end,
          memo: memo,
          inProgress: inProgress,
          isPlus: true,
          minPrecedenceLevel: minPrecedenceLevel,
        );
      case "rca":
        {
          var prec = suffix.isEmpty ? null : int.parse(suffix);
          yield* _enumerateDerivations(
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
        for (var child in _enumerateAlternatives(
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
          children.single,
          start,
          start,
          input,
          memo,
          inProgress: inProgress,
        ).any((_) => true)) {
          yield ParseDerivation(symbol, start, start, []);
        }
      case "neg":
        if (!_enumerateDerivations(
          children.single,
          start,
          end,
          input,
          memo,
          inProgress: inProgress,
          minPrecedenceLevel: minPrecedenceLevel,
        ).any((_) => true)) {
          yield ParseDerivation(symbol, start, end, []);
        }
      case "con":
        {
          var leftList = _enumerateAlternatives(
            children.first,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          ).toList();
          if (leftList.isEmpty) {
            return;
          }

          var rightList = _enumerateAlternatives(
            children.last,
            input,
            start,
            end,
            memo,
            inProgress,
            minPrecedenceLevel: minPrecedenceLevel,
          ).toList();
          if (rightList.isEmpty) {
            return;
          }

          for (var left in leftList) {
            for (var right in rightList) {
              yield ParseDerivation(symbol, start, end, [left, right]);
            }
          }
        }
    }
  }

  Iterable<ParseDerivation> _enumerateRepetition({
    required PatternSymbol symbol,
    required PatternSymbol child,
    required String input,
    required int start,
    required int end,
    required Map<String, List<ParseDerivation>?> memo,
    required Map<String, bool> inProgress,
    required bool isPlus,
    required int? minPrecedenceLevel,
  }) sync* {
    if (!isPlus && start == end) {
      yield ParseDerivation(symbol, start, end, []);
    }

    if (isPlus) {
      for (var base in _enumerateAlternatives(
        child,
        input,
        start,
        end,
        memo,
        inProgress,
        minPrecedenceLevel: minPrecedenceLevel,
      )) {
        yield ParseDerivation(symbol, start, end, [base]);
      }
    }

    // Force progress in the recursive branch to avoid epsilon loops.
    for (int mid = start + 1; mid <= end; mid++) {
      var leftList = _enumerateAlternatives(
        child,
        input,
        start,
        mid,
        memo,
        inProgress,
        minPrecedenceLevel: minPrecedenceLevel,
      ).toList();
      if (leftList.isEmpty) {
        continue;
      }

      var rightList = _enumerateAlternatives(
        symbol,
        input,
        mid,
        end,
        memo,
        inProgress,
        minPrecedenceLevel: minPrecedenceLevel,
      ).toList();
      if (rightList.isEmpty) {
        continue;
      }

      for (var left in leftList) {
        for (var right in rightList) {
          yield ParseDerivation(symbol, start, end, [left, right]);
        }
      }
    }
  }

  Object? evaluateParseTreeWith<T>(dynamic tree, String input, Evaluator<T> evaluator) {
    if (tree is ParseNode) {
      return evaluator.evaluate(tree);
    }
    return null;
  }
}
