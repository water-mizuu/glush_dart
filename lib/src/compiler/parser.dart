/// Parser for grammar files
library glush.grammar_file_parser;

import "package:glush/src/compiler/format.dart";

class GrammarFileParseError implements Exception {
  GrammarFileParseError(this.message, {this.line = -1, this.column = -1});
  final String message;
  final int line;
  final int column;

  @override
  String toString() {
    if (line >= 0 && column >= 0) {
      return "GrammarFileParseError at line $line, column $column: $message";
    }
    return "GrammarFileParseError: $message";
  }
}

/// Tokenizer for grammar files
class _Token {
  _Token(this.type, this.value, this.line, this.column);
  final _TokenType type;
  final String value;
  final int line;
  final int column;

  @override
  String toString() => "$type($value)";
}

enum _TokenType {
  identifier,
  literal, // 'x' or "string"
  charRange, // [a-z]
  equals, // =
  semicolon, // ;
  pipe, // |
  star, // *
  plus, // +
  question, // ?
  lparen, // (
  rparen, // )
  dollar, // $
  caret, // ^
  lbrace, // {
  rbrace, // }
  ampersand, // &
  doubleAmpersand, // &&
  bang, // !
  eof, // \0
  lesser, // <
  greater, // >
  dot, // .
  backslashLiteral, // \n, \s, etc.
  colon, // :
}

class _Tokenizer {
  _Tokenizer(this.source) {
    _tokenize();
  }
  final String source;
  int position = 0;
  int line = 1;
  int column = 1;
  late List<_Token> _tokens;

  void _tokenize() {
    _tokens = [];
    while (position < source.length) {
      _skipWhitespace();
      if (position >= source.length) {
        break;
      }

      var ch = source[position];

      // Comments
      if (ch == "#") {
        _skipComment();
        continue;
      }

      // Literals
      if (ch == "'" || ch == '"') {
        _tokens.add(_readLiteral());
        continue;
      }

      // Character ranges
      if (ch == "[") {
        _tokens.add(_readCharRange());
        continue;
      }

      // Backslash literals (e.g., \n, \s)
      if (ch == r"\") {
        _tokens.add(_readBackslashLiteral());
        continue;
      }

      if (ch == "&") {
        if (position + 1 < source.length && source[position + 1] == "&") {
          _tokens.add(_Token(_TokenType.doubleAmpersand, "&&", line, column));
          position += 2;
          continue;
        }
        _tokens.add(_Token(_TokenType.ampersand, "&", line, column));
        position++;
        continue;
      }

      // Single-character tokens
      var tokenMap = {
        "=": _TokenType.equals,
        ";": _TokenType.semicolon,
        "|": _TokenType.pipe,
        "*": _TokenType.star,
        "+": _TokenType.plus,
        "?": _TokenType.question,
        "(": _TokenType.lparen,
        ")": _TokenType.rparen,
        r"$": _TokenType.dollar,
        "^": _TokenType.caret,
        "{": _TokenType.lbrace,
        "}": _TokenType.rbrace,
        "!": _TokenType.bang,
        "<": _TokenType.lesser,
        ">": _TokenType.greater,
        ".": _TokenType.dot,
        ":": _TokenType.colon,
      };

      if (tokenMap.containsKey(ch)) {
        _tokens.add(_Token(tokenMap[ch]!, ch, line, column));
        _advance();
        continue;
      }

      // Identifiers or numbers
      if (_isIdentifierStart(ch) || ch.contains(RegExp("[0-9]"))) {
        _tokens.add(_readIdentifier());
        continue;
      }

      throw GrammarFileParseError("Unexpected character: $ch", line: line, column: column);
    }

    _tokens.add(_Token(_TokenType.eof, "", line, column));
  }

  _Token _readLiteral() {
    var quote = source[position];
    var startLine = line;
    var startCol = column;
    _advance();

    var buffer = StringBuffer();
    while (position < source.length && source[position] != quote) {
      if (source[position] == r"\" && position + 1 < source.length) {
        _advance();
        var next = source[position];
        buffer.write(next);
        _advance();
      } else {
        buffer.write(source[position]);
        _advance();
      }
    }

    if (position >= source.length) {
      throw GrammarFileParseError("Unterminated string literal", line: startLine, column: startCol);
    }

    _advance(); // closing quote
    return _Token(_TokenType.literal, buffer.toString(), startLine, startCol);
  }

  _Token _readBackslashLiteral() {
    var startLine = line;
    var startCol = column;
    _advance(); // \

    if (position >= source.length) {
      throw GrammarFileParseError(
        r"Unexpected end of file after \",
        line: startLine,
        column: startCol,
      );
    }

    var char = source[position];
    _advance();
    return _Token(_TokenType.backslashLiteral, char, startLine, startCol);
  }

  _Token _readCharRange() {
    var startLine = line;
    var startCol = column;
    _advance(); // [

    var buffer = StringBuffer();
    buffer.write("[");

    while (position < source.length && source[position] != "]") {
      buffer.write(source[position]);
      _advance();
    }

    if (position >= source.length) {
      throw GrammarFileParseError(
        "Unterminated character range",
        line: startLine,
        column: startCol,
      );
    }

    buffer.write("]");
    _advance(); // ]

    return _Token(_TokenType.charRange, buffer.toString(), startLine, startCol);
  }

  _Token _readIdentifier() {
    var startLine = line;
    var startCol = column;
    var buffer = StringBuffer();

    while (position < source.length && _isIdentifierChar(source[position])) {
      buffer.write(source[position]);
      _advance();
    }

    return _Token(_TokenType.identifier, buffer.toString(), startLine, startCol);
  }

  void _skipWhitespace() {
    while (position < source.length && source[position].trim().isEmpty) {
      if (source[position] == "\n") {
        line++;
        column = 1;
      } else {
        column++;
      }
      position++;
    }
  }

  void _skipComment() {
    while (position < source.length && source[position] != "\n") {
      position++;
    }
    if (position < source.length) {
      line++;
      column = 1;
      position++;
    }
  }

  void _advance() {
    if (position < source.length) {
      if (source[position] == "\n") {
        line++;
        column = 1;
      } else {
        column++;
      }
      position++;
    }
  }

  bool _isIdentifierStart(String ch) => ch.contains(RegExp("[a-zA-Z_]"));

  bool _isIdentifierChar(String ch) => ch.contains(RegExp("[a-zA-Z0-9_]"));
}

/// Parser for grammar files
class GrammarFileParser {
  GrammarFileParser(this.source) {
    var tokenizer = _Tokenizer(source);
    _tokens = tokenizer._tokens;
  }
  final String source;
  late List<_Token> _tokens;
  int tokenIndex = 0;
  Map<PatternExpr, int> lastParsedPrecedenceLevels = {};

  GrammarFile parse() {
    var rules = <RuleDefinition>[];

    while (!_isAtEnd()) {
      var token = _peek();
      if (token.type == _TokenType.eof) {
        break;
      }
      var rule = _parseRule();
      if (rule != null) {
        rules.add(rule);
        continue;
      }

      throw GrammarFileParseError(
        "Expected a rule definition",
        line: token.line,
        column: token.column,
      );
    }

    if (rules.isEmpty) {
      throw GrammarFileParseError("No rules defined in grammar file");
    }

    return GrammarFile(name: "grammar", rules: rules);
  }

  RuleDefinition? _parseRule() {
    if (_peek().type != _TokenType.identifier) {
      return null;
    }

    var ruleName = _advance().value;

    if (_peek().type != _TokenType.equals) {
      throw GrammarFileParseError(
        'Expected "=" after rule name',
        line: _peek().line,
        column: _peek().column,
      );
    }

    _advance(); // consume =

    var pattern = _parsePattern();

    // Consume optional semicolon
    if (_peek().type == _TokenType.semicolon) {
      _advance();
    }

    return RuleDefinition(
      name: ruleName,
      pattern: pattern,
      precedenceLevels: lastParsedPrecedenceLevels,
    );
  }

  PatternExpr _parsePattern() {
    return _parseAlternation();
  }

  /// Parse: [prec|]expr [ [prec|]expr] [| [prec|]expr]
  /// Where prec is an optional number (like "5|" or "6|")
  /// Precedence prefixes can implicitly start new alternatives
  PatternExpr _parseAlternation() {
    var parts = <PatternExpr>[];
    var precedenceLevels = <PatternExpr, int>{};

    // Parse first alternative
    int? precedenceLevel = _tryParsePrecedenceLevel();
    PatternExpr pattern = _parseSequence();
    parts.add(pattern);
    if (precedenceLevel != null) {
      precedenceLevels[pattern] = precedenceLevel;
    }

    // Continue while we see | OR a precedence prefix (N|)
    // A precedence prefix can implicitly start a new alternative
    while (_peek().type == _TokenType.pipe || _isPrecedencePrefixAhead()) {
      // Consume explicit | if present
      if (_peek().type == _TokenType.pipe) {
        _advance();
      }

      // Parse next alternative with optional precedence
      precedenceLevel = _tryParsePrecedenceLevel();
      pattern = _parseSequence();
      parts.add(pattern);
      if (precedenceLevel != null) {
        precedenceLevels[pattern] = precedenceLevel;
      }
    }

    var result = parts.length == 1 ? parts[0] : AlternationPattern(parts);

    // Store precedence levels for access by _parseRule
    lastParsedPrecedenceLevels = precedenceLevels;

    return result;
  }

  /// Check if the current position has a precedence prefix (number followed by pipe)
  bool _isPrecedencePrefixAhead() {
    var type = _peek().type;
    if (type == _TokenType.identifier) {
      var token = _peek().value;
      if (int.tryParse(token) != null) {
        var nextIndex = tokenIndex + 1;
        return nextIndex < _tokens.length && _tokens[nextIndex].type == _TokenType.pipe;
      }
    }
    return false;
  }

  /// Try to parse an integer followed by a pipe
  /// Returns the integer if found, null otherwise
  int? _tryParsePrecedenceLevel() {
    if (_peek().type == _TokenType.identifier) {
      var token = _peek().value;
      // Check if it's a number
      if (int.tryParse(token) != null) {
        var level = int.parse(token);
        // Look ahead to see if next token is pipe
        var nextIndex = tokenIndex + 1;
        if (nextIndex < _tokens.length && _tokens[nextIndex].type == _TokenType.pipe) {
          _advance(); // consume the number
          _advance(); // consume the pipe
          return level;
        }
      }
    }
    return null;
  }

  /// Parse: expr expr expr
  PatternExpr _parseSequence() {
    var startingMark = _tryParseMainMark();

    var parts = [_parseConjunction()];

    while (_isSequenceContinuation()) {
      parts.add(_parseConjunction());
    }

    PatternExpr result = parts.length == 1 ? parts[0] : SequencePattern(parts);
    if (startingMark != null) {
      result = LabeledPattern(startingMark.name, result);
    }

    return result;
  }

  MarkerPattern? _tryParseMainMark() {
    if (_peek().type == _TokenType.dollar &&
        tokenIndex + 1 < _tokens.length &&
        _tokens[tokenIndex + 1].type == _TokenType.identifier) {
      _advance(); // consume $
      var value = _advance().value;
      return MarkerPattern(value);
    }

    return null;
  }

  /// Parse: expr & expr & expr
  PatternExpr _parseConjunction() {
    var parts = [_parsePrefix()];

    while (_peek().type == _TokenType.doubleAmpersand) {
      _advance(); // consume &
      parts.add(_parsePrefix());
    }

    if (parts.length == 1) {
      return parts[0];
    }
    return ConjunctionPattern(parts);
  }

  /// Parse prefix predicates: &expr, !expr
  PatternExpr _parsePrefix() {
    var type = _peek().type;
    if (type == _TokenType.ampersand || type == _TokenType.bang) {
      _advance();
      var inner = _parseRepetition();
      return PredicatePattern(inner, isAnd: type == _TokenType.ampersand);
    }
    return _parseRepetition();
  }

  bool _isSequenceContinuation() {
    var type = _peek().type;

    // Don't continue sequence if we see a number followed by pipe (precedence prefix)
    // This handles cases where precedence is on a new line, like:
    //   expr = foo
    //   5| 'a'
    if (type == _TokenType.identifier) {
      var token = _peek().value;
      if (int.tryParse(token) != null) {
        var nextIndex = tokenIndex + 1;
        if (nextIndex < _tokens.length && _tokens[nextIndex].type == _TokenType.pipe) {
          return false; // This is a precedence prefix, not a sequence continuation
        }
      }
    }

    if (type == _TokenType.identifier) {
      var nextIndex = tokenIndex + 1;
      if (nextIndex < _tokens.length && _tokens[nextIndex].type == _TokenType.equals) {
        return false; // This is now a new rule.
      }
    }

    if (type == _TokenType.dollar) {
      return true;
    }

    return type == _TokenType.identifier ||
        type == _TokenType.literal ||
        type == _TokenType.charRange ||
        type == _TokenType.backslashLiteral ||
        type == _TokenType.lparen ||
        type == _TokenType.caret ||
        type == _TokenType.dollar ||
        type == _TokenType.ampersand ||
        type == _TokenType.bang ||
        type == _TokenType.dot;
  }

  /// Parse: expr*, expr+, expr?
  PatternExpr _parseRepetition() {
    var pattern = _parsePrimary();

    while (true) {
      var type = _peek().type;
      if (type == _TokenType.star) {
        _advance();
        pattern = StarPattern(pattern);
      } else if (type == _TokenType.plus) {
        _advance();
        pattern = PlusPattern(pattern);
      } else if (type == _TokenType.question) {
        _advance();
        pattern = RepetitionPattern(pattern, RepetitionKind.optional);
      } else {
        break;
      }
    }

    return pattern;
  }

  /// Parse: literal, identifier, [a-z], (pattern)
  PatternExpr _parsePrimary() {
    var type = _peek().type;

    if (type == _TokenType.dot) {
      _advance();
      return const AnyPattern();
    }

    if (type == _TokenType.literal) {
      var literal = _advance().value;
      return LiteralPattern(literal);
    }

    if (type == _TokenType.charRange) {
      var token = _peek();
      _advance();
      var ranges = _parseCharRanges(token.value, line: token.line, column: token.column);
      return CharRangePattern(ranges);
    }

    if (type == _TokenType.backslashLiteral) {
      var char = _advance().value;
      return BackslashLiteralPattern(char);
    }

    if (type == _TokenType.dollar) {
      _advance(); // consume $
      if (_peek().type != _TokenType.identifier) {
        return const EofPattern();
      }
      var markName = _advance().value;
      return MarkerPattern(markName);
    }

    if (type == _TokenType.caret) {
      _advance();
      return const StartPattern();
    }

    if (type == _TokenType.identifier) {
      var id = _advance().value;

      if (id == "start") {
        return const StartPattern();
      }
      if (id == "eof") {
        return const EofPattern();
      }

      // Check for label: name:pattern
      if (_peek().type == _TokenType.colon) {
        _advance(); // consume :
        var inner = _parsePrimary();
        return LabeledPattern(id, inner);
      }

      var ruleName = id;
      int? precedenceConstraint;

      // Optional precedence constraint like expr^2
      if (_peek().type == _TokenType.caret) {
        _advance(); // consume ^
        if (_peek().type == _TokenType.identifier) {
          var constraintStr = _peek().value;
          if (int.tryParse(constraintStr) != null) {
            precedenceConstraint = int.parse(constraintStr);
            _advance();
          }
        }
      }

      return RuleRefPattern(ruleName, precedenceConstraint: precedenceConstraint);
    }

    if (type == _TokenType.lesser) {
      _advance();
      var codePoint = int.tryParse(_peek().value);
      if (codePoint == null) {
        throw GrammarFileParseError(
          'Expected integer after "<"',
          line: _peek().line,
          column: _peek().column,
        );
      }
      _advance();
      return LessThanPattern(codePoint);
    }

    if (type == _TokenType.greater) {
      _advance();
      var codePoint = int.tryParse(_peek().value);
      if (codePoint == null) {
        throw GrammarFileParseError(
          'Expected integer after ">"',
          line: _peek().line,
          column: _peek().column,
        );
      }
      _advance();
      return GreaterThanPattern(codePoint);
    }

    if (type == _TokenType.lparen) {
      _advance();
      var pattern = _parsePattern();
      if (_peek().type != _TokenType.rparen) {
        throw GrammarFileParseError('Expected ")"', line: _peek().line, column: _peek().column);
      }
      _advance();
      return GroupPattern(pattern);
    }

    throw GrammarFileParseError(
      "Unexpected token: ${_peek().value}",
      line: _peek().line,
      column: _peek().column,
    );
  }

  List<CharRange> _parseCharRanges(String rangeStr, {required int line, required int column}) {
    // Parse "[a-z]" or "[0-9a-zA-Z]"
    if (!rangeStr.startsWith("[") || !rangeStr.endsWith("]")) {
      throw GrammarFileParseError("Invalid character range: $rangeStr", line: line, column: column);
    }

    var inner = rangeStr.substring(1, rangeStr.length - 1);
    if (inner.isEmpty) {
      throw GrammarFileParseError("Empty character range", line: line, column: column);
    }

    var ranges = <CharRange>[];

    int i = 0;

    int readCode() {
      if (i >= inner.length) {
        throw GrammarFileParseError("Unterminated character range", line: line, column: column);
      }
      if (i < inner.length && inner[i] == r"\" && i + 1 < inner.length) {
        i++; // consume backslash
        var escaped = inner[i++];
        return switch (escaped) {
          "n" => 10,
          "r" => 13,
          "t" => 9,
          "0" => 0,
          _ => escaped.codeUnitAt(0), // \\ \] etc.
        };
      }
      return inner.codeUnitAt(i++);
    }

    while (i < inner.length) {
      var startCode = readCode();
      if (i < inner.length && inner[i] == "-") {
        i++; // consume '-'
        var endCode = readCode();
        if (endCode < startCode) {
          throw GrammarFileParseError(
            "Invalid character range: $rangeStr",
            line: line,
            column: column,
          );
        }
        ranges.add(CharRange(startCode, endCode));
      } else {
        ranges.add(CharRange(startCode, startCode));
      }
    }

    return ranges;
  }

  _Token _peek() {
    if (tokenIndex >= _tokens.length) {
      return _tokens.last;
    }
    return _tokens[tokenIndex];
  }

  _Token _advance() {
    var token = _peek();
    if (tokenIndex < _tokens.length - 1) {
      tokenIndex++;
    }
    return token;
  }

  bool _isAtEnd() => _peek().type == _TokenType.eof;
}
