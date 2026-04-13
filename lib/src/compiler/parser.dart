/// Parser for grammar files
library glush.grammar_file_parser;

import "dart:convert";

import "package:glush/src/compiler/format.dart";
import "package:glush/src/core/profiling.dart";

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
  doublePipe, // ||
  comma, // ,
  star, // *
  plus, // +
  starBang, // *!
  plusBang, // +!
  question, // ?
  slash, // /
  percent, // %
  lparen, // (
  rparen, // )
  dollar, // $
  caret, // ^
  lbrace, // {
  rbrace, // }
  ampersand, // &
  doubleAmpersand, // &&
  bang, // !
  tilde, // ~
  equalEqual, // ==
  bangEqual, // !=
  lesserEqual, // <=
  greaterEqual, // >=
  minus, // -
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

      if (ch == "|") {
        if (position + 1 < source.length && source[position + 1] == "|") {
          _tokens.add(_Token(_TokenType.doublePipe, "||", line, column));
          position += 2;
          continue;
        }
      }

      if (position + 1 < source.length) {
        var next = source[position + 1];
        var twoChar = "$ch$next";
        var twoCharType = switch (twoChar) {
          "==" => _TokenType.equalEqual,
          "!=" => _TokenType.bangEqual,
          "<=" => _TokenType.lesserEqual,
          ">=" => _TokenType.greaterEqual,
          "&&" => _TokenType.doubleAmpersand,
          "*!" => _TokenType.starBang,
          "+!" => _TokenType.plusBang,
          _ => null,
        };
        if (twoCharType != null) {
          _tokens.add(_Token(twoCharType, twoChar, line, column));
          position += 2;
          column += 2;
          continue;
        }
      }

      // Single-character tokens
      var tokenMap = {
        "=": _TokenType.equals,
        ";": _TokenType.semicolon,
        ",": _TokenType.comma,
        "|": _TokenType.pipe,
        "*": _TokenType.star,
        "/": _TokenType.slash,
        "%": _TokenType.percent,
        "+": _TokenType.plus,
        "?": _TokenType.question,
        "&": _TokenType.ampersand,
        "(": _TokenType.lparen,
        ")": _TokenType.rparen,
        "^": _TokenType.caret,
        "{": _TokenType.lbrace,
        "}": _TokenType.rbrace,
        r"$": _TokenType.dollar,
        "!": _TokenType.bang,
        "~": _TokenType.tilde,
        "<": _TokenType.lesser,
        ">": _TokenType.greater,
        ".": _TokenType.dot,
        ":": _TokenType.colon,
        "-": _TokenType.minus,
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
    return GlushProfiler.measure("compiler.grammar_file_parse", () {
      var rules = <RuleDefinition>[];

      while (!_isAtEnd()) {
        var token = _peek();
        if (token.type == _TokenType.eof) {
          break;
        }
        var rule = _parseRule();
        if (rule != null) {
          rules.add(rule);
          GlushProfiler.increment("compiler.rules_parsed");
          continue;
        }

        throw GrammarFileParseError(
          "Expected a rule definition, got $token",
          line: token.line,
          column: token.column,
        );
      }

      if (rules.isEmpty) {
        throw GrammarFileParseError("No rules defined in grammar file");
      }

      return GrammarFile(name: "grammar", rules: rules);
    });
  }

  RuleDefinition? _parseRule() {
    if (_peek().type != _TokenType.identifier) {
      return null;
    }

    var ruleName = _advance().value;
    var parameters = <String>[];

    if (_peek().type == _TokenType.lparen) {
      parameters = _parseParameterList();
    }

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
      parameters: parameters,
      precedenceLevels: lastParsedPrecedenceLevels,
    );
  }

  List<String> _parseParameterList() {
    _advance(); // consume (
    var parameters = <String>[];

    if (_peek().type == _TokenType.rparen) {
      _advance();
      return parameters;
    }

    while (true) {
      if (_peek().type != _TokenType.identifier) {
        throw GrammarFileParseError(
          "Expected parameter name",
          line: _peek().line,
          column: _peek().column,
        );
      }
      parameters.add(_advance().value);

      if (_peek().type == _TokenType.comma) {
        _advance();
        if (_peek().type == _TokenType.rparen) {
          _advance();
          break;
        }
        continue;
      }

      if (_peek().type == _TokenType.rparen) {
        _advance();
        break;
      }

      throw GrammarFileParseError(
        'Expected "," or ")" after parameter name',
        line: _peek().line,
        column: _peek().column,
      );
    }

    return parameters;
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
    var guard = _tryParseGuardPrefix();
    var startingMark = _tryParseMainMark();

    var parts = [_parseConjunction()];

    while (_isSequenceContinuation()) {
      parts.add(_parseConjunction());
    }

    PatternExpr result = parts.length == 1 ? parts[0] : SequencePattern(parts);
    if (startingMark != null) {
      result = MainMarkPattern(startingMark.name, result);
    }

    if (guard != null) {
      result = IfPattern(guard, result);
    }

    return result;
  }

  CallArgumentValueNode? _tryParseGuardPrefix() {
    if (_peek().type != _TokenType.identifier || _peek().value != "if") {
      return null;
    }
    if (tokenIndex + 1 >= _tokens.length || _tokens[tokenIndex + 1].type != _TokenType.lparen) {
      return null;
    }

    _advance(); // consume if
    _advance(); // consume (
    var guard = _parseExpression();
    if (_peek().type != _TokenType.rparen) {
      throw GrammarFileParseError(
        'Expected ")" after if guard',
        line: _peek().line,
        column: _peek().column,
      );
    }
    _advance(); // consume )
    return guard;
  }

  CallArgumentValueNode _parseExpression() => _parseLogicalOr();

  CallArgumentValueNode _parseLogicalOr() {
    var expr = _parseLogicalAnd();
    while (_peek().type == _TokenType.doublePipe) {
      _advance();
      expr = ExpressionBinaryNode(expr, ExpressionBinaryOperator.logicalOr, _parseLogicalAnd());
    }
    return expr;
  }

  CallArgumentValueNode _parseLogicalAnd() {
    var expr = _parseEquality();
    while (_peek().type == _TokenType.doubleAmpersand) {
      _advance();
      expr = ExpressionBinaryNode(expr, ExpressionBinaryOperator.logicalAnd, _parseEquality());
    }
    return expr;
  }

  CallArgumentValueNode _parseEquality() {
    var expr = _parseComparison();
    while (_peek().type == _TokenType.equalEqual || _peek().type == _TokenType.bangEqual) {
      var operator = switch (_advance().type) {
        _TokenType.equalEqual => ExpressionBinaryOperator.equals,
        _TokenType.bangEqual => ExpressionBinaryOperator.notEquals,
        _ => throw StateError("Unexpected equality operator"),
      };
      expr = ExpressionBinaryNode(expr, operator, _parseComparison());
    }
    return expr;
  }

  CallArgumentValueNode _parseComparison() {
    var expr = _parseAdditive();
    while (true) {
      var operator = switch (_peek().type) {
        _TokenType.lesser => ExpressionBinaryOperator.lessThan,
        _TokenType.lesserEqual => ExpressionBinaryOperator.lessOrEqual,
        _TokenType.greater => ExpressionBinaryOperator.greaterThan,
        _TokenType.greaterEqual => ExpressionBinaryOperator.greaterOrEqual,
        _ => null,
      };
      if (operator == null) {
        break;
      }
      _advance();
      expr = ExpressionBinaryNode(expr, operator, _parseAdditive());
    }
    return expr;
  }

  CallArgumentValueNode _parseAdditive() {
    var expr = _parseMultiplicative();
    while (_peek().type == _TokenType.plus || _peek().type == _TokenType.minus) {
      var operator = switch (_advance().type) {
        _TokenType.plus => ExpressionBinaryOperator.add,
        _TokenType.minus => ExpressionBinaryOperator.subtract,
        _ => throw StateError("Unexpected additive operator"),
      };
      expr = ExpressionBinaryNode(expr, operator, _parseMultiplicative());
    }
    return expr;
  }

  CallArgumentValueNode _parseMultiplicative() {
    var expr = _parseUnary();
    while (_peek().type == _TokenType.star ||
        _peek().type == _TokenType.slash ||
        _peek().type == _TokenType.percent) {
      var operator = switch (_advance().type) {
        _TokenType.star => ExpressionBinaryOperator.multiply,
        _TokenType.slash => ExpressionBinaryOperator.divide,
        _TokenType.percent => ExpressionBinaryOperator.modulo,
        _ => throw StateError("Unexpected multiplicative operator"),
      };
      expr = ExpressionBinaryNode(expr, operator, _parseUnary());
    }
    return expr;
  }

  CallArgumentValueNode _parseUnary() {
    if (_peek().type == _TokenType.bang) {
      _advance();
      return ExpressionUnaryNode(ExpressionUnaryOperator.logicalNot, _parseUnary());
    }

    if (_peek().type case _TokenType.minus) {
      _advance();
      return ExpressionUnaryNode(ExpressionUnaryOperator.negate, _parseUnary());
    }

    return _parsePostfix();
  }

  CallArgumentValueNode _parsePostfix() {
    var expr = _parseExpressionPrimary();
    while (_peek().type == _TokenType.dot) {
      var dot = _peek();
      if (tokenIndex + 1 >= _tokens.length ||
          _tokens[tokenIndex + 1].type != _TokenType.identifier) {
        throw GrammarFileParseError(
          'Expected member name after "."',
          line: dot.line,
          column: dot.column,
        );
      }
      _advance(); // consume .
      var member = _advance().value;
      expr = ExpressionMemberNode(expr, member);
    }
    return expr;
  }

  CallArgumentValueNode _parseExpressionPrimary() {
    var type = _peek().type;

    if (type == _TokenType.literal) {
      var literal = _advance().value;
      return GuardStringLiteralNode(literal);
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

      if (id == "true" || id == "false") {
        return GuardBoolLiteralNode(id == "true");
      }

      var number = num.tryParse(id);
      if (number != null) {
        return GuardNumberLiteralNode(number);
      }

      if (_peek().type == _TokenType.colon) {
        _advance(); // consume :
        var inner = _parseExpressionPrimary();
        if (inner is! PatternExpr) {
          throw GrammarFileParseError(
            "Expected pattern after label '$id'",
            line: _peek().line,
            column: _peek().column,
          );
        }
        return LabeledPattern(id, inner);
      }

      if (_peek().type == _TokenType.lparen) {
        var callStartIndex = tokenIndex;
        List<CallArgumentNode> arguments;
        try {
          arguments = _parseCallArgumentList();
        } on GrammarFileParseError {
          tokenIndex = callStartIndex;
          arguments = const [];
        }
        return RuleRefPattern(id, arguments: arguments);
      }

      return GuardNameNode(id);
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
      var pattern = _parseExpression();
      if (_peek().type != _TokenType.rparen) {
        throw GrammarFileParseError('Expected ")"', line: _peek().line, column: _peek().column);
      }
      _advance();
      return ExpressionGroupNode(pattern);
    }

    throw GrammarFileParseError(
      "Unexpected token in expression: ${_peek().value}",
      line: _peek().line,
      column: _peek().column,
    );
  }

  List<CallArgumentNode> _parseCallArgumentList() {
    _advance(); // consume (
    var arguments = <CallArgumentNode>[];

    if (_peek().type == _TokenType.rparen) {
      _advance();
      return arguments;
    }

    while (true) {
      String? name;
      if (_peek().type == _TokenType.identifier &&
          tokenIndex + 1 < _tokens.length &&
          _tokens[tokenIndex + 1].type == _TokenType.colon) {
        name = _advance().value;
        _advance(); // consume :
      }

      var value = _parseExpression();
      arguments.add(CallArgumentNode(value, name: name));

      if (_peek().type == _TokenType.comma) {
        _advance();
        if (_peek().type == _TokenType.rparen) {
          _advance();
          break;
        }
        continue;
      }

      if (_peek().type == _TokenType.rparen) {
        _advance();
        break;
      }

      throw GrammarFileParseError(
        'Expected "," or ")" after call argument',
        line: _peek().line,
        column: _peek().column,
      );
    }

    return arguments;
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

  /// Parse: expr && expr && expr
  PatternExpr _parseConjunction() {
    var parts = [_parsePrefix()];

    while (_peek().type == _TokenType.doubleAmpersand) {
      _advance(); // consume &&
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
    if (type case _TokenType.ampersand || _TokenType.bang) {
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
      if (_isRuleDeclarationAhead()) {
        return false;
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
      } else if (type == _TokenType.starBang) {
        _advance();
        pattern = StarBangPattern(pattern);
      } else if (type == _TokenType.plusBang) {
        _advance();
        pattern = PlusBangPattern(pattern);
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
      var token = _peek();
      var id = _advance().value;

      // Check for label: name:pattern
      if (_peek().type == _TokenType.colon) {
        _advance(); // consume :
        var inner = _parsePrimary();
        return LabeledPattern(id, inner);
      }

      var ruleName = id;
      var arguments = <CallArgumentNode>[];
      int? precedenceConstraint;

      if (_peek().type == _TokenType.lparen && _looksLikeCallInvocationAhead(idToken: token)) {
        var callStartIndex = tokenIndex;
        try {
          arguments = _parseCallArgumentList();
        } on GrammarFileParseError {
          tokenIndex = callStartIndex;
          arguments = const [];
        }
      }

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

      return RuleRefPattern(
        ruleName,
        arguments: arguments,
        precedenceConstraint: precedenceConstraint,
      );
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
      _advance(); // consume (

      // Check for inline guard syntax: (if (expr) pattern)
      if (_peek().type == _TokenType.identifier && _peek().value == "if") {
        if (tokenIndex + 1 < _tokens.length && _tokens[tokenIndex + 1].type == _TokenType.lparen) {
          _advance(); // consume if
          _advance(); // consume (
          var guard = _parseExpression();
          if (_peek().type != _TokenType.rparen) {
            throw GrammarFileParseError(
              'Expected ")" after inline guard condition',
              line: _peek().line,
              column: _peek().column,
            );
          }
          _advance(); // consume )

          // Parse the pattern that the guard protects
          var pattern = _parseSequence();

          if (_peek().type != _TokenType.rparen) {
            throw GrammarFileParseError(
              'Expected ")" to close inline guard pattern',
              line: _peek().line,
              column: _peek().column,
            );
          }
          _advance(); // consume final )

          return IfPattern(guard, pattern);
        }
      }

      // Regular grouped pattern: (pattern)
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

  bool _looksLikeCallInvocationAhead({required _Token idToken}) {
    if (_peek().type != _TokenType.lparen) {
      return false;
    }

    var lparen = _peek();
    if (lparen.line != idToken.line) {
      return false;
    }

    // Calls are written as `name(...)` without intervening whitespace.
    // Grouped patterns can still use whitespace, e.g. `name (pattern)`.
    return lparen.column == idToken.column + idToken.value.length;
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
    var bytes = utf8.encode(inner);
    var i = 0;

    int readCode() {
      if (i >= bytes.length) {
        throw GrammarFileParseError("Unterminated character range", line: line, column: column);
      }
      var byte = bytes[i];
      // Check for escape sequences (backslash is 0x5C = 92)
      if (byte == 92 && i + 1 < bytes.length) {
        i++; // consume backslash
        var escaped = bytes[i++];
        return switch (escaped) {
          110 => 10, // n -> newline
          114 => 13, // r -> carriage return
          116 => 9, // t -> tab
          48 => 0, // 0 -> null
          _ => escaped, // backslash escapes - use the byte itself
        };
      }
      i++;
      return byte;
    }

    while (i < bytes.length) {
      var startCode = readCode();
      if (i < bytes.length && bytes[i] == 45) {
        // dash (-) is 0x2D = 45
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

  bool _isRuleDeclarationAhead() {
    var nextIndex = tokenIndex + 1;
    if (nextIndex >= _tokens.length) {
      return false;
    }

    if (_tokens[nextIndex].type == _TokenType.equals) {
      return true;
    }

    if (_tokens[nextIndex].type != _TokenType.lparen) {
      return false;
    }

    var depth = 1;
    for (var i = nextIndex + 1; i < _tokens.length; i++) {
      switch (_tokens[i].type) {
        case _TokenType.lparen:
          depth++;
        case _TokenType.rparen:
          depth--;
          if (depth == 0) {
            var afterParen = i + 1;
            return afterParen < _tokens.length && _tokens[afterParen].type == _TokenType.equals;
          }
        case _:
          break;
      }
    }
    return false;
  }
}
