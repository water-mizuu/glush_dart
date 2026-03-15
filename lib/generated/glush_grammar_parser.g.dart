import 'package:glush/glush.dart';

/// Auto-generated grammar library from grammar
/// Generated: 2026-03-15 06:57:55.135837

GrammarInterface _createGrammarGrammar() {
  return Grammar(() {
    late Rule grammar,
        rule,
        pattern,
        alternation,
        sequence,
        repetition,
        atom,
        group,
        charRange,
        literal,
        identifier;
    grammar = Rule('grammar', () => Call(rule).plus());
    rule = Rule(
        'rule',
        () =>
            Call(identifier) >>
            Token(ExactToken(61)) >>
            Call(pattern) >>
            (Token(ExactToken(59))).maybe());
    pattern = Rule('pattern', () => Call(alternation));
    alternation = Rule(
        'alternation', () => Call(sequence) >> (Token(ExactToken(124)) >> Call(sequence)).star());
    sequence = Rule('sequence', () => Call(repetition) >> (Call(repetition)).star());
    repetition = Rule(
        'repetition',
        () =>
            Call(atom) >>
            (Token(ExactToken(42)) | Token(ExactToken(43)) | Token(ExactToken(63))).maybe());
    atom = Rule('atom', () => Call(group) | Call(charRange) | Call(literal) | Call(identifier));
    group = Rule('group', () => Token(ExactToken(40)) >> Call(pattern) >> Token(ExactToken(41)));
    charRange = Rule(
        'charRange',
        () =>
            Token(ExactToken(91)) >> Token(RangeToken(97, 122)) |
            Token(RangeToken(65, 90)) |
            Token(RangeToken(48, 57)) |
            Token(ExactToken(92)) |
            Token(ExactToken(45)).plus() >> Token(ExactToken(93)));
    literal = Rule(
        'literal',
        () =>
            (Token(ExactToken(39)) >> Token(ExactToken(94)) |
                Token(ExactToken(92)) |
                Token(ExactToken(39)).star() >> Token(ExactToken(39))) |
            (Token(ExactToken(34)) >> Token(ExactToken(94)) |
                Token(ExactToken(92)) |
                Token(ExactToken(34)).star() >> Token(ExactToken(34))));
    identifier = Rule(
        'identifier',
        () =>
            Token(RangeToken(97, 122)) |
            Token(RangeToken(65, 90)) |
            Token(ExactToken(95)) >> Token(RangeToken(97, 122)) |
            Token(RangeToken(65, 90)) |
            Token(RangeToken(48, 57)) |
            Token(ExactToken(95)).star());

    return grammar;
  });
}

/// Lazy-initialized parser for grammar
late final SMParser _grammarParser = SMParser(_createGrammarGrammar());

/// Parse input text using the grammar grammar
/// Returns the parse outcome containing the parse forest or error information
ParseOutcome parseGrammar(String input) {
  return _grammarParser.parse(input);
}
