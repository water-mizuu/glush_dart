import "package:glush/glush.dart";

/// Auto-generated grammar library from grammar
/// Generated: 2026-03-15 06:57:55.135837

Grammar _createGrammarGrammar() {
  return Grammar(() {
    late Rule grammar;
    late Rule rule;
    late Rule pattern;
    late Rule alternation;
    late Rule sequence;
    late Rule repetition;
    late Rule atom;
    late Rule group;
    late Rule charRange;
    late Rule literal;
    late Rule identifier;
    grammar = Rule("grammar", () => rule().plus());
    rule = Rule(
      "rule",
      () =>
          identifier() >>
          Token(const ExactToken(61)) >>
          pattern() >>
          Token(const ExactToken(59)).maybe(),
    );
    pattern = Rule("pattern", () => alternation());
    alternation = Rule(
      "alternation",
      () => sequence() >> (Token(const ExactToken(124)) >> sequence()).star(),
    );
    sequence = Rule("sequence", () => repetition() >> repetition().star());
    repetition = Rule(
      "repetition",
      () =>
          atom() >>
          (Token(const ExactToken(42)) | Token(const ExactToken(43)) | Token(const ExactToken(63)))
              .maybe(),
    );
    atom = Rule("atom", () => group() | charRange() | literal() | identifier());
    group = Rule(
      "group",
      () => Token(const ExactToken(40)) >> pattern >> Token(const ExactToken(41)),
    );
    charRange = Rule(
      "charRange",
      () =>
          Token(const ExactToken(91)) >> Token(const RangeToken(97, 122)) |
          Token(const RangeToken(65, 90)) |
          Token(const RangeToken(48, 57)) |
          Token(const ExactToken(92)) |
          Token(const ExactToken(45)).plus() >> Token(const ExactToken(93)),
    );
    literal = Rule(
      "literal",
      () =>
          (Token(const ExactToken(39)) >> Token(const ExactToken(94)) |
              Token(const ExactToken(92)) |
              Token(const ExactToken(39)).star() >> Token(const ExactToken(39))) |
          (Token(const ExactToken(34)) >> Token(const ExactToken(94)) |
              Token(const ExactToken(92)) |
              Token(const ExactToken(34)).star() >> Token(const ExactToken(34))),
    );
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

    return grammar;
  });
}

/// Lazy-initialized parser for grammar
final SMParser _grammarParser = SMParser(_createGrammarGrammar());

/// Parse input text using the grammar grammar
/// Returns the parse outcome containing the parse forest or error information
ParseOutcome parseGrammar(String input) {
  return _grammarParser.parse(input);
}
