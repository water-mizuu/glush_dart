import 'package:glush/glush.dart';

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
    rule = Rule('rule', () => identifier() >> equals() >> pattern() >> semicolon());
    pattern = Rule('pattern', () => sequence() >> (pipe() >> sequence()).star());
    sequence = Rule('sequence', () => item.plus());
    item = Rule('item', () => term() >> (star() | plus() | question()).maybe());
    term = Rule('term', () => identifier() | (lparen() >> pattern() >> rparen()));
    identifier = Rule(
      'identifier',
      () =>
          Token(RangeToken(97, 122)) |
          Token(RangeToken(65, 90)) |
          Token(ExactToken(95)) >> Token(RangeToken(97, 122)) |
          Token(RangeToken(65, 90)) |
          Token(RangeToken(48, 57)) |
          Token(ExactToken(95)).star(),
    );
    equals = Rule('equals', () => Token(ExactToken(61)));
    semicolon = Rule('semicolon', () => Token(ExactToken(59)));
    pipe = Rule('pipe', () => Token(ExactToken(124)));
    star = Rule('star', () => Token(ExactToken(42)));
    plus = Rule('plus', () => Token(ExactToken(43)));
    question = Rule('question', () => Token(ExactToken(63)));
    lparen = Rule('lparen', () => Token(ExactToken(40)));
    rparen = Rule('rparen', () => Token(ExactToken(41)));

    return rule;
  });
}

/// Lazy-initialized parser for grammar
late final SMParser _grammarParser = SMParser(_createGrammarGrammar());

/// Parse input text using the grammar grammar
/// Returns the parse outcome containing the parse forest or error information
ParseOutcome parseGrammar(String input) {
  return _grammarParser.parse(input);
}
