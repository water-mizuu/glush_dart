// ignore_for_file: avoid_multiple_declarations_per_line

import "package:glush/glush.dart";

/// Auto-generated grammar library from grammar
/// Generated: 2026-03-15 06:57:55.135837

GrammarInterface _createGrammarGrammar() {
  return Grammar(() {
    late Rule rule,
        pattern,
        sequence,
        item,
        term,
        identifier,
        equals,
        semicolon,
        pipe,
        star,
        plus,
        question,
        lparen,
        rparen;
    rule = Rule("rule", () => identifier() >> equals() >> pattern() >> semicolon());
    pattern = Rule("pattern", () => sequence() >> (pipe() >> sequence()).star());
    sequence = Rule("sequence", () => item.plus());
    item = Rule("item", () => term() >> (star() | plus() | question()).maybe());
    term = Rule("term", () => identifier() | (lparen() >> pattern() >> rparen()));
    identifier = Rule(
      "identifier",
      () =>
          Token(const RangeToken(97, 122)) |
          Token(const RangeToken(65, 90)) |
          Token(const ExactToken(95)) >> Token(const RangeToken(97, 122)) |
          Token(const RangeToken(65, 90)) |
          Token(const RangeToken(48, 57)) |
          Token(const ExactToken(95)).star(),
    );
    equals = Rule("equals", () => Token(const ExactToken(61)));
    semicolon = Rule("semicolon", () => Token(const ExactToken(59)));
    pipe = Rule("pipe", () => Token(const ExactToken(124)));
    star = Rule("star", () => Token(const ExactToken(42)));
    plus = Rule("plus", () => Token(const ExactToken(43)));
    question = Rule("question", () => Token(const ExactToken(63)));
    lparen = Rule("lparen", () => Token(const ExactToken(40)));
    rparen = Rule("rparen", () => Token(const ExactToken(41)));

    return rule;
  });
}

/// Lazy-initialized parser for grammar
final SMParser _grammarParser = SMParser(_createGrammarGrammar());

/// Parse input text using the grammar grammar
/// Returns the parse outcome containing the parse forest or error information
ParseOutcome parseGrammar(String input) {
  return _grammarParser.parse(input);
}
