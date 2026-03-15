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
    rule = Rule('rule', () => Call(identifier) >> Call(equals) >> Call(pattern) >> Call(semicolon));
    pattern = Rule('pattern', () => Call(sequence) >> (Call(pipe) >> Call(sequence)).star());
    sequence = Rule('sequence', () => Call(item).plus());
    item = Rule('item', () => Call(term) >> (Call(star) | Call(plus) | Call(question)).maybe());
    term = Rule('term', () => Call(identifier) | (Call(lparen) >> Call(pattern) >> Call(rparen)));
    identifier = Rule(
        'identifier',
        () =>
            Token(RangeToken(97, 122)) |
            Token(RangeToken(65, 90)) |
            Token(ExactToken(95)) >> Token(RangeToken(97, 122)) |
            Token(RangeToken(65, 90)) |
            Token(RangeToken(48, 57)) |
            Token(ExactToken(95)).star());
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
