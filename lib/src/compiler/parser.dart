/// Parser for grammar files
library glush.grammar_file_parser;

import 'format.dart';

class GrammarFileParseError implements Exception {
  final String message;
  final int line;
  final int column;

  GrammarFileParseError(this.message, {this.line = -1, this.column = -1});

  @override
  String toString() {
    if (line >= 0 && column >= 0) {
      return 'GrammarFileParseError at line $line, column $column: $message';
    }
    return 'GrammarFileParseError: $message';
  }
}

/// Tokenizer for grammar files
class _Token {
  final _TokenType type;
  final String value;
  final int line;
  final int column;

  _Token(this.type, this.value, this.line, this.column);

  @override
  String toString() => '$type($value)';
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
  bang, // !
  eof, // \0
  lesser, // <
  greater, // >
  dot, // .
  backslashLiteral, // \n, \s, etc.
  colon, // :
}

class _Tokenizer {
  final String source;
  int position = 0;
  int line = 1;
  int column = 1;
  late List<_Token> tokens;

  _Tokenizer(this.source) {
    _tokenize();
  }

  void _tokenize() {
    tokens = [];
    while (position < source.length) {
      _skipWhitespace();
      if (position >= source.length) break;

      final ch = source[position];

      // Comments
      if (ch == '#') {
        _skipComment();
        continue;
      }

      // Literals
      if (ch == "'" || ch == '"') {
        tokens.add(_readLiteral());
        continue;
      }

      // Character ranges
      if (ch == '[') {
        tokens.add(_readCharRange());
        continue;
      }

      // Backslash literals (e.g., \n, \s)
      if (ch == '\\') {
        tokens.add(_readBackslashLiteral());
        continue;
      }

      // Single-character tokens
      final tokenMap = {
        '=': _TokenType.equals,
        ';': _TokenType.semicolon,
        '|': _TokenType.pipe,
        '*': _TokenType.star,
        '+': _TokenType.plus,
        '?': _TokenType.question,
        '(': _TokenType.lparen,
        ')': _TokenType.rparen,
        '\$': _TokenType.dollar,
        '^': _TokenType.caret,
        '{': _TokenType.lbrace,
        '}': _TokenType.rbrace,
        '&': _TokenType.ampersand,
        '!': _TokenType.bang,
        '<': _TokenType.lesser,
        '>': _TokenType.greater,
        '.': _TokenType.dot,
        ':': _TokenType.colon,
      };

      if (tokenMap.containsKey(ch)) {
        tokens.add(_Token(tokenMap[ch]!, ch, line, column));
        _advance();
        continue;
      }

      // Identifiers or numbers
      if (_isIdentifierStart(ch) || ch.contains(RegExp(r'[0-9]'))) {
        tokens.add(_readIdentifier());
        continue;
      }

      throw GrammarFileParseError('Unexpected character: $ch', line: line, column: column);
    }

    tokens.add(_Token(_TokenType.eof, '', line, column));
  }

  _Token _readLiteral() {
    final quote = source[position];
    final startLine = line;
    final startCol = column;
    _advance();

    final buffer = StringBuffer();
    while (position < source.length && source[position] != quote) {
      if (source[position] == '\\' && position + 1 < source.length) {
        _advance();
        final next = source[position];
        buffer.write(next);
        _advance();
      } else {
        buffer.write(source[position]);
        _advance();
      }
    }

    if (position >= source.length) {
      throw GrammarFileParseError('Unterminated string literal', line: startLine, column: startCol);
    }

    _advance(); // closing quote
    return _Token(_TokenType.literal, buffer.toString(), startLine, startCol);
  }

  _Token _readBackslashLiteral() {
    final startLine = line;
    final startCol = column;
    _advance(); // \

    if (position >= source.length) {
      throw GrammarFileParseError(
        'Unexpected end of file after \\',
        line: startLine,
        column: startCol,
      );
    }

    final char = source[position];
    _advance();
    return _Token(_TokenType.backslashLiteral, char, startLine, startCol);
  }

  _Token _readCharRange() {
    final startLine = line;
    final startCol = column;
    _advance(); // [

    final buffer = StringBuffer();
    buffer.write('[');

    while (position < source.length && source[position] != ']') {
      buffer.write(source[position]);
      _advance();
    }

    if (position >= source.length) {
      throw GrammarFileParseError(
        'Unterminated character range',
        line: startLine,
        column: startCol,
      );
    }

    buffer.write(']');
    _advance(); // ]

    return _Token(_TokenType.charRange, buffer.toString(), startLine, startCol);
  }

  _Token _readIdentifier() {
    final startLine = line;
    final startCol = column;
    final buffer = StringBuffer();

    while (position < source.length && _isIdentifierChar(source[position])) {
      buffer.write(source[position]);
      _advance();
    }

    return _Token(_TokenType.identifier, buffer.toString(), startLine, startCol);
  }

  void _skipWhitespace() {
    while (position < source.length && source[position].trim().isEmpty) {
      if (source[position] == '\n') {
        line++;
        column = 1;
      } else {
        column++;
      }
      position++;
    }
  }

  void _skipComment() {
    while (position < source.length && source[position] != '\n') {
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
      if (source[position] == '\n') {
        line++;
        column = 1;
      } else {
        column++;
      }
      position++;
    }
  }

  bool _isIdentifierStart(String ch) => ch.contains(RegExp(r'[a-zA-Z_]'));

  bool _isIdentifierChar(String ch) => ch.contains(RegExp(r'[a-zA-Z0-9_]'));
}

/// Parser for grammar files
class GrammarFileParser {
  final String source;
  late List<_Token> tokens;
  int tokenIndex = 0;
  Map<PatternExpr, int> lastParsedPrecedenceLevels = {};

  GrammarFileParser(this.source) {
    final tokenizer = _Tokenizer(source);
    tokens = tokenizer.tokens;
  }

  GrammarFile parse() {
    final rules = <RuleDefinition>[];

    while (!_isAtEnd()) {
      if (_peek().type == _TokenType.eof) break;

      final rule = _parseRule();
      if (rule != null) {
        rules.add(rule);
      }
    }

    if (rules.isEmpty) {
      throw GrammarFileParseError('No rules defined in grammar file');
    }

    return GrammarFile(name: 'grammar', rules: rules);
  }

  RuleDefinition? _parseRule() {
    if (_peek().type != _TokenType.identifier) {
      return null;
    }

    final ruleName = _advance().value;

    if (_peek().type != _TokenType.equals) {
      throw GrammarFileParseError(
        'Expected "=" after rule name',
        line: _peek().line,
        column: _peek().column,
      );
    }

    _advance(); // consume =

    final pattern = _parsePattern();

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
    final parts = <PatternExpr>[];
    final precedenceLevels = <PatternExpr, int>{};

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

    final result = parts.length == 1 ? parts[0] : AlternationPattern(parts);

    // Store precedence levels for access by _parseRule
    lastParsedPrecedenceLevels = precedenceLevels;

    return result;
  }

  /// Check if the current position has a precedence prefix (number followed by pipe)
  bool _isPrecedencePrefixAhead() {
    final type = _peek().type;
    if (type == _TokenType.identifier) {
      final token = _peek().value;
      if (int.tryParse(token) != null) {
        final nextIndex = tokenIndex + 1;
        return nextIndex < tokens.length && tokens[nextIndex].type == _TokenType.pipe;
      }
    }
    return false;
  }

  /// Try to parse an integer followed by a pipe
  /// Returns the integer if found, null otherwise
  int? _tryParsePrecedenceLevel() {
    if (_peek().type == _TokenType.identifier) {
      final token = _peek().value;
      // Check if it's a number
      if (int.tryParse(token) != null) {
        final level = int.parse(token);
        // Look ahead to see if next token is pipe
        final nextIndex = tokenIndex + 1;
        if (nextIndex < tokens.length && tokens[nextIndex].type == _TokenType.pipe) {
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
    final parts = [_parseConjunction()];

    while (_isSequenceContinuation()) {
      parts.add(_parseConjunction());
    }

    if (parts.length == 1) return parts[0];
    return SequencePattern(parts);
  }

  /// Parse: expr & expr & expr
  PatternExpr _parseConjunction() {
    final parts = [_parsePrefix()];

    while (_peek().type == _TokenType.ampersand) {
      _advance(); // consume &
      parts.add(_parsePrefix());
    }

    if (parts.length == 1) return parts[0];
    return ConjunctionPattern(parts);
  }

  /// Parse prefix predicates: &expr, !expr
  PatternExpr _parsePrefix() {
    final type = _peek().type;
    if (type == _TokenType.ampersand || type == _TokenType.bang) {
      _advance();
      final inner = _parseRepetition();
      return PredicatePattern(inner, isAnd: type == _TokenType.ampersand);
    }
    return _parseRepetition();
  }

  bool _isSequenceContinuation() {
    final type = _peek().type;

    // Don't continue sequence if we see a number followed by pipe (precedence prefix)
    // This handles cases where precedence is on a new line, like:
    //   expr = foo
    //   5| 'a'
    if (type == _TokenType.identifier) {
      final token = _peek().value;
      if (int.tryParse(token) != null) {
        final nextIndex = tokenIndex + 1;
        if (nextIndex < tokens.length && tokens[nextIndex].type == _TokenType.pipe) {
          return false; // This is a precedence prefix, not a sequence continuation
        }
      }
    }

    if (type == _TokenType.identifier) {
      final nextIndex = tokenIndex + 1;
      if (nextIndex < tokens.length && tokens[nextIndex].type == _TokenType.equals) {
        return false; // This is now a new rule.
      }
    }

    if (type == _TokenType.dollar) {
      final nextIndex = tokenIndex + 1;
      if (nextIndex < tokens.length && tokens[nextIndex].type == _TokenType.identifier) {
        return true; // This is now a new rule.
      }
    }

    return type == _TokenType.identifier ||
        type == _TokenType.literal ||
        type == _TokenType.charRange ||
        type == _TokenType.backslashLiteral ||
        type == _TokenType.lparen ||
        type == _TokenType.dot;
  }

  /// Parse: expr*, expr+, expr?
  PatternExpr _parseRepetition() {
    var pattern = _parsePrimary();

    while (true) {
      final type = _peek().type;
      if (type == _TokenType.star) {
        _advance();
        pattern = RepetitionPattern(pattern, RepetitionKind.zeroOrMore);
      } else if (type == _TokenType.plus) {
        _advance();
        pattern = RepetitionPattern(pattern, RepetitionKind.oneOrMore);
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
    final type = _peek().type;

    if (type == _TokenType.dot) {
      _advance();
      return AnyPattern();
    }

    if (type == _TokenType.literal) {
      final literal = _advance().value;
      return LiteralPattern(literal);
    }

    if (type == _TokenType.charRange) {
      final rangeStr = _advance().value;
      final ranges = _parseCharRanges(rangeStr);
      return CharRangePattern(ranges);
    }

    if (type == _TokenType.backslashLiteral) {
      final char = _advance().value;
      return BackslashLiteralPattern(char);
    }

    if (type == _TokenType.dollar) {
      _advance(); // consume $
      if (_peek().type != _TokenType.identifier) {
        throw GrammarFileParseError(
          'Expected identifier after \$',
          line: _peek().line,
          column: _peek().column,
        );
      }
      final markName = _advance().value;
      return MarkerPattern(markName);
    }

    if (type == _TokenType.identifier) {
      final id = _advance().value;

      // Check for label: name:pattern
      if (_peek().type == _TokenType.colon) {
        _advance(); // consume :
        final inner = _parsePrimary();
        return LabeledPattern(id, inner);
      }

      final ruleName = id;
      int? precedenceConstraint;

      // Optional precedence constraint like expr^2
      if (_peek().type == _TokenType.caret) {
        _advance(); // consume ^
        if (_peek().type == _TokenType.identifier) {
          final constraintStr = _peek().value;
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
      final codePoint = int.tryParse(_peek().value);
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
      final codePoint = int.tryParse(_peek().value);
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
      final pattern = _parsePattern();
      if (_peek().type != _TokenType.rparen) {
        throw GrammarFileParseError('Expected ")"', line: _peek().line, column: _peek().column);
      }
      _advance();
      return GroupPattern(pattern);
    }

    throw GrammarFileParseError(
      'Unexpected token: ${_peek().value}',
      line: _peek().line,
      column: _peek().column,
    );
  }

  List<CharRange> _parseCharRanges(String rangeStr) {
    // Parse "[a-z]" or "[0-9a-zA-Z]"
    if (!rangeStr.startsWith('[') || !rangeStr.endsWith(']')) {
      throw GrammarFileParseError('Invalid character range: $rangeStr');
    }

    final inner = rangeStr.substring(1, rangeStr.length - 1);
    final ranges = <CharRange>[];

    int i = 0;

    int readCode() {
      if (i < inner.length && inner[i] == '\\' && i + 1 < inner.length) {
        i++; // consume backslash
        final escaped = inner[i++];
        return switch (escaped) {
          'n' => 10,
          'r' => 13,
          't' => 9,
          '0' => 0,
          _ => escaped.codeUnitAt(0), // \\ \] etc.
        };
      }
      return inner.codeUnitAt(i++);
    }

    while (i < inner.length) {
      final startCode = readCode();
      if (i < inner.length && inner[i] == '-') {
        i++; // consume '-'
        final endCode = readCode();
        ranges.add(CharRange(startCode, endCode));
      } else {
        ranges.add(CharRange(startCode, startCode));
      }
    }

    return ranges;
  }

  _Token _peek() {
    if (tokenIndex >= tokens.length) {
      return tokens.last;
    }
    return tokens[tokenIndex];
  }

  _Token _advance() {
    final token = _peek();
    if (tokenIndex < tokens.length - 1) {
      tokenIndex++;
    }
    return token;
  }

  bool _isAtEnd() => _peek().type == _TokenType.eof;
}
