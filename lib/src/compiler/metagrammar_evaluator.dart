/// Evaluator for the metagrammar that transforms parse trees into GrammarFile objects
library glush.metagrammar_evaluator;

import "package:glush/src/compiler/format.dart";
import "package:glush/src/representation/evaluator.dart";

const metaGrammarString = r"""
# ==========================
#   Full Meta Grammar
# ==========================
full = $full start _ file:file _ eof

file = $rules left:file _ right:rule
     | rule

# Allow trailing trivia after a rule body so line comments behave
# like whitespace instead of becoming the next token stream.
rule = $rule     name:ident                        _ '=' _ body:choice _ (';')?
     | $dataRule name:ident '(' params:params? ')' _ '=' _ body:choice _ (';')?

choice = $rest left:choice _ (prec:number _)? '|' _ right:seq
       | $first ((prec:number _)? '|' _)? body:seq

seq = $seq left:seq _ &isContinuation right:conj
    | conj

conj = $conj left:conj _ "&&" _ right:prefix
      | prefix

prefix = $and '&' atom:rep
       | $not '!' atom:rep
       | rep

rep = $rep atom:primary kind:repKind
    | primary

repKind = $star '*'      | $plus '+'
        | $starBang "*!" | $plusBang "+!"
        | $question '?'

primary = $group '(' _ inner:choice _ ')'
        | $label name:ident ':' atom:primary
        | $mark '$' name:ident
        | $start "start"
        | $end "eof"
        | $call name:ident ('^' prec:number)?
        | $lit literal
        | $range charRange
        | $any '.'

# Helpers
isContinuation = ident !(_ [=]) !isRuleDeclarationAhead
               | literal | charRange
               | '[' | '(' | '.' | '!' | '&'

isRuleDeclarationAhead = !$ balancedParenthesis? _ "="
balancedParenthesis    = "(" balancedParenthesis ")" | !")" .

params = $params left:params _ ',' _ right:param
       | $param  right:param
param = ident

# Terminals
ident = [A-Za-z$_] [A-Za-z$_0-9]*!
literal = ['] ([\] . | !['] .)*! [']
        | ["] ([\] . | !["] .)*! ["]
charRange = '[' (!']' .)*! ']'
number = [0-9]+

_ = $ws (plain_ws | comment | newline)*!
comment = '#' (!newline .)* (newline | eof)
plain_ws() = [ \t]+!
newline = [\n\r]+!
    """;

/// Constructs an [Evaluator] configured to transform metagrammar parse trees into [GrammarFile] objects.
///
/// This evaluator defines a mapping between the "marks" produced by the
/// metagrammar (defined in `grammar_string_parser.dart`) and the constructors for
/// the grammar AST (defined in `format.dart`).
///
/// Each entry in the evaluator handles a specific grammar construct:
/// - **Rule Definitions**: Capturing names, parameters, and bodies.
/// - **Parsing Expressions**: Building sequences, alternations, repetitions, etc.
/// - **Guard Expressions**: Resolving comparisons and arithmetic in `if` guards.
/// - **Arguments**: Binding values to parameters in rule calls.
Evaluator<Object> createMetagrammarEvaluator() {
  return Evaluator<Object>({
    // Top level (rule-prefixed marks)
    "full.full": (ctx) {
      var file = ctx<Object>("file");
      // file can be either a GrammarFile or a single RuleDefinition
      if (file is GrammarFile) {
        return file;
      } else if (file is RuleDefinition) {
        return GrammarFile(name: "", rules: [file]);
      }
      throw StateError("Unexpected file type: ${file.runtimeType}");
    },

    // File structure - accumulate rules (rule-prefixed marks)
    "file.rules": (ctx) {
      var left = ctx<Object>("left");
      var right = ctx<RuleDefinition>("right");

      late GrammarFile file;
      if (left is GrammarFile) {
        file = left;
      } else if (left is RuleDefinition) {
        file = GrammarFile(name: "", rules: [left]);
      } else {
        throw StateError("Unexpected left type: ${left.runtimeType}");
      }

      file.rules.add(right);
      return file;
    },

    // Note: single rule case is handled implicitly by returning RuleDefinition from rule handler
    // The full handler then converts single rules to GrammarFile

    // Rule definitions (rule-prefixed marks)
    "rule.rule": (ctx) {
      var name = ctx<String>("name");
      var body = ctx<PatternExpr>("body");
      return RuleDefinition(name: name, pattern: body);
    },

    "rule.dataRule": (ctx) {
      var name = ctx<String>("name");
      var params = ctx.optional<List<String>>("params") ?? [];
      var body = ctx<PatternExpr>("body");
      return RuleDefinition(name: name, pattern: body, parameters: params);
    },

    // Choice patterns (alternation - rule-prefixed marks)
    "choice.rest": (ctx) {
      var left = ctx<PatternExpr>("left");
      var right = ctx<PatternExpr>("right");

      // Try to get prec - it might be null or might be an int
      int? precedence;
      try {
        // First, try getting it as optional int
        precedence = ctx.optional<int>("prec");
      } on Exception {
        // If that fails, try getting it as optional Object and parse manually
        var rawPrec = ctx.optional<Object>("prec");
        if (rawPrec != null) {
          if (rawPrec is int) {
            precedence = rawPrec;
          } else if (rawPrec is String) {
            precedence = int.tryParse(rawPrec);
          }
        }
      }

      // Wrap right with precedence if specified
      var rightPattern = precedence != null ? PrecedenceExpr(precedence, right) : right;

      if (left case AlternationPattern(patterns: var patterns)) {
        patterns.add(rightPattern);
        return left;
      } else {
        return AlternationPattern([left, rightPattern]);
      }
    },

    "choice.first": (ctx) {
      var body = ctx<PatternExpr>("body");

      // Try to get prec - it might be null or might be an int
      int? precedence;
      try {
        // First, try getting it as optional int
        precedence = ctx.optional<int>("prec");
      } on Exception {
        // If that fails, try getting it as optional Object and parse manually
        var rawPrec = ctx.optional<Object>("prec");
        if (rawPrec != null) {
          if (rawPrec is int) {
            precedence = rawPrec;
          } else if (rawPrec is String) {
            precedence = int.tryParse(rawPrec);
          }
        }
      }

      // Wrap with precedence if specified
      return precedence != null ? PrecedenceExpr(precedence, body) : body;
    },

    "branch.none": (ctx) {
      var body = ctx<PatternExpr>("body");
      return body;
    },

    // Sequence patterns (rule-prefixed marks)
    "seq.seq": (ctx) {
      var left = ctx<PatternExpr>("left");
      var right = ctx<PatternExpr>("right");

      if (left case SequencePattern(patterns: var patterns)) {
        patterns.add(right);
        return left;
      } else {
        return SequencePattern([left, right]);
      }
    },

    // Conjunction patterns (rule-prefixed marks)
    "conj.conj": (ctx) {
      var left = ctx<PatternExpr>("left");
      var right = ctx<PatternExpr>("right");

      if (left case ConjunctionPattern(patterns: var patterns)) {
        patterns.add(right);
        return left;
      } else {
        return ConjunctionPattern([left, right]);
      }
    },

    // Prefix operators (lookahead/lookahead-not) OR unary argExpr operators (rule-prefixed marks)
    "prefix.and": (ctx) {
      // Only used in primary patterns for positive lookahead
      var atom = ctx<PatternExpr>("atom");
      return PredicatePattern(atom, isAnd: true);
    },

    "prefix.not": (ctx) {
      // Predicate pattern in primary context
      var atom = ctx<PatternExpr>("atom");
      return PredicatePattern(atom, isAnd: false);
    },

    // Repetition (rule-prefixed marks)
    "rep.rep": (ctx) {
      var atom = ctx<PatternExpr>("atom");
      var kindMark = ctx<String>("kind");

      // Create the appropriate pattern type based on the mark
      return switch (kindMark) {
        "star" => StarPattern(atom),
        "plus" => PlusPattern(atom),
        "starBang" => StarBangPattern(atom),
        "plusBang" => PlusBangPattern(atom),
        "question" => RepetitionPattern(atom, RepetitionKind.optional),
        _ => throw StateError("Unknown repetition kind: $kindMark"),
      };
    },

    // Repetition kind marks - these return the mark name as a string
    "repKind.star": (ctx) => "star",
    "repKind.plus": (ctx) => "plus",
    "repKind.starBang": (ctx) => "starBang",
    "repKind.plusBang": (ctx) => "plusBang",
    "repKind.question": (ctx) => "question",

    // Primary patterns (rule-prefixed marks)
    "primary.group": (ctx) {
      var inner = ctx<PatternExpr>("inner");
      return GroupPattern(inner);
    },

    "primary.label": (ctx) {
      var name = ctx<String>("name");
      var atom = ctx<PatternExpr>("atom");
      return LabeledPattern(name, atom);
    },

    "primary.mark": (ctx) {
      var name = ctx<String>("name");
      return MarkerPattern(name);
    },

    "primary.start": (_) => const StartPattern(),

    "primary.end": (_) => const EofPattern(),

    "primary.call": (ctx) {
      var name = ctx<String>("name");

      // Try to get prec - it might be null or might be an int
      int? prec;
      try {
        // First, try getting it as optional int
        prec = ctx.optional<int>("prec");
      } on Exception {
        // If that fails, try getting it as optional Object and parse manually
        var rawPrec = ctx.optional<Object>("prec");
        if (rawPrec != null) {
          if (rawPrec is int) {
            prec = rawPrec;
          } else if (rawPrec is String) {
            prec = int.tryParse(rawPrec);
          }
        }
      }

      return RuleRefPattern(name, precedenceConstraint: prec);
    },

    "primary.lit": (ctx) {
      // Terminal pattern - use span directly
      var literal = ctx.span;
      return _parseLiteralPattern(literal);
    },

    "primary.range": (ctx) {
      // Terminal pattern - use span directly
      var charRange = ctx.span;
      var ranges = _parseCharRanges(charRange);
      return CharRangePattern(ranges);
    },

    "primary.any": (_) => const AnyPattern(),

    // Identifiers and terminals - extract raw values from span
    "ident": (ctx) => ctx.span,

    "literal": (ctx) {
      // Extract the string value (removing quotes and handling escapes)
      var span = ctx.span;
      if ((span.startsWith("'") && span.endsWith("'")) ||
          (span.startsWith('"') && span.endsWith('"'))) {
        return _unquote(span.substring(1, span.length - 1));
      }
      return span;
    },

    "charRange": (ctx) => ctx.span,

    "number": (ctx) => int.parse(ctx.span),

    // Parameter lists (rule-prefixed marks)
    "params.params": (ctx) {
      var list = ctx.optional<List<String>>("left") ?? [];
      var right = ctx<String>("right");
      list.add(right);
      return list;
    },

    "params.param": (ctx) => ctx<String>("right"),

    // Whitespace and comments - typically ignored (rule-prefixed marks)
    "_.ws": (_) => null,
  });
}

/// Normalizes a string by removing quotes and resolving escape sequences.
///
/// This is used for both [LiteralPattern] values and string literals in guard
/// expressions. It ensures that `\n` in a grammar file is treated as a
/// newline character (0x0A) rather than a backslash and the letter 'n'.
String _unquote(String escaped) {
  var buffer = StringBuffer();
  for (int i = 0; i < escaped.length; i++) {
    if (escaped[i] == r"\" && i + 1 < escaped.length) {
      i++;
      var codePoint = _parseEscapeSequence(escaped[i]);
      buffer.writeCharCode(codePoint);
    } else {
      buffer.write(escaped[i]);
    }
  }
  return buffer.toString();
}

/// Parse a literal pattern from raw span (e.g., '"hello"' or "'world'")
LiteralPattern _parseLiteralPattern(String span) {
  // Remove quotes and unescape
  if ((span.startsWith("'") && span.endsWith("'")) ||
      (span.startsWith('"') && span.endsWith('"'))) {
    var unquoted = _unquote(span.substring(1, span.length - 1));
    return LiteralPattern(unquoted);
  }
  return LiteralPattern(span);
}

/// Parses a character range string (e.g., `[a-zA-Z]`) into a list of [CharRange] objects.
///
/// It handles the bracket delimiters, internal ranges using the `-` operator,
/// and escape sequences within the range.
List<CharRange> _parseCharRanges(String rangeStr) {
  if (!rangeStr.startsWith("[") || !rangeStr.endsWith("]")) {
    throw FormatException("Invalid character range: $rangeStr");
  }

  var content = rangeStr.substring(1, rangeStr.length - 1);
  var ranges = <CharRange>[];

  int i = 0;
  while (i < content.length) {
    // Handle escape sequences
    if (content[i] == r"\") {
      if (i + 1 >= content.length) {
        throw const FormatException("Invalid escape sequence in character range");
      }
      i++;
      var codePoint = _parseEscapeSequence(content[i]);
      ranges.add(CharRange(codePoint, codePoint));
      i++;
    } else {
      var startCode = content.codeUnitAt(i);
      i++;

      // Check for range notation (-)
      if (i < content.length && content[i] == "-" && i + 1 < content.length) {
        i++; // skip -
        int endCode;
        if (content[i] == r"\") {
          i++;
          endCode = _parseEscapeSequence(content[i]);
          i++;
        } else {
          endCode = content.codeUnitAt(i);
          i++;
        }
        ranges.add(CharRange(startCode, endCode));
      } else {
        // Single character
        ranges.add(CharRange(startCode, startCode));
      }
    }
  }

  return ranges;
}

/// Parses escape sequences like \n, \t, etc.
int _parseEscapeSequence(String char) {
  return switch (char) {
    "n" => 0x0A, // newline
    "r" => 0x0D, // carriage return
    "t" => 0x09, // tab
    "f" => 0x0C, // form feed
    "b" => 0x08, // backspace
    "0" => 0x00, // null
    "x" => 0x78, // literal x (would need hex parsing for proper support)
    _ => char.codeUnitAt(0), // literal character
  };
}
