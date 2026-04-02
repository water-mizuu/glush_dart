import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("Predicates do not multiply branches for ambiguous sub-patterns", () {
    var grammar = Grammar(() {
      var a = Token(const ExactToken(97));
      // Ambiguous sub-pattern inside predicate
      var amb = a | a;
      return Rule("test", () => amb.and() >> a);
    });

    var parser = SMParserMini(grammar);
    // Use parseAmbiguous to see if we get multiple mark streams
    var outcome = parser.parseAmbiguous("a", captureTokensAsMarks: true);

    expect(outcome, isA<ParseAmbiguousSuccess>());
    var success = outcome as ParseAmbiguousSuccess;

    // We expect only ONE result, because the predicate ambiguity should be collapsed.
    // If we get TWO results, it means the predicate leaked its ambiguity.
    expect(success.forest.allPaths().length, equals(1));
  });

  test("Negative predicates do not multiply branches", () {
    var grammar = Grammar(() {
      var a = Token(const ExactToken(97));
      var b = Token(const ExactToken(98));
      var amb = a | a;
      return Rule("test", () => amb.not() >> b);
    });

    var parser = SMParserMini(grammar);
    var outcome = parser.parseAmbiguous("b", captureTokensAsMarks: true);

    expect(outcome, isA<ParseAmbiguousSuccess>());
    var success = outcome as ParseAmbiguousSuccess;

    expect(success.forest.allPaths().length, equals(1));
  });

  test("", () {
    var unambiguous = r"""
          # ==========================
          #   Full Meta Grammar
          # ==========================
          full = $full start _ file:file _ eof

          file = $rules left:file _ right:rule
              | $first rule:rule

          # Allow trailing trivia after a rule body so line comments behave
          # like whitespace instead of becoming the next token stream.
          rule = $rule name:ident _ '=' _ body:choice _ ( ';' )?

          choice = $choice     left:choice _               '|' _  right:seq
                | $precChoice left:choice _ prec:number _ '|' _  right:seq
                | $firstChoice          ((prec:number _)? '|' _)? body:seq

          seq = $seq left:seq _ &isContinuation right:prefix
              | prefix

          prefix = $and '&' atom:rep
                | $not '!' atom:rep
                | rep

          rep = $rep atom:primary kind:repKind
              | primary

          repKind = $star '*'      | $plus '+'
                  | $starBang "*!" | $plusBang "+!"
                  | $question '?'

          primary =
              $group '(' _ inner:choice _ ')'
            | $label name:ident ':' atom:primary
            | $mark '$' name:ident
            | start
            | eof
            | $ref name:ident
            | $lit literal
            | $range charRange
            | $any '.'

          isContinuation = ident !(_ [=])
                        | literal
                        | charRange
                        | '['
                        | '('
                        | '.'
                        | '!'
                        | '&'

          # Terminals
          ident = [A-Za-z$_] [A-Za-z$_0-9]*
          literal = ['] (!['] .)* ['] | ["] (!["] .)* ["]
          charRange = '[' (!']' .)* ']'
          number = [0-9]+

          _ = $ws (plain_ws | comment | newline)* !plain_ws !comment !newline
          comment = '#' (!newline .)* (newline | eof)
          plain_ws = [ \t]+ ![ \t]
          newline = [\n\r]+ ![\n\r]
        """;
    var unambiguousParser = unambiguous.toSMParser();

    var ambiguous = r"""
          # ==========================
          #   Full Meta Grammar
          # ==========================
          full = $full start _ file:file _ eof

          file = $rules left:file _ right:rule
              | $first rule:rule

          # Allow trailing trivia after a rule body so line comments behave
          # like whitespace instead of becoming the next token stream.
          rule = $rule name:ident _ '=' _ body:choice _ ( ';' )?

          choice = $choice     left:choice _               '|' _  right:seq
                | $precChoice left:choice _ prec:number _ '|' _  right:seq
                | $firstChoice          ((prec:number _)? '|' _)? body:seq

          seq = $seq left:seq _ &isContinuation right:prefix
              | prefix

          prefix = $and '&' atom:rep
                | $not '!' atom:rep
                | rep

          rep = $rep atom:primary kind:repKind
              | primary

          repKind = $star '*'      | $plus '+'
                  | $starBang "*!" | $plusBang "+!"
                  | $question '?'

          primary =
              $group '(' _ inner:choice _ ')'
            | $label name:ident ':' atom:primary
            | $mark '$' name:ident
            | start
            | eof
            | $ref name:ident
            | $lit literal
            | $range charRange
            | $any '.'

          isContinuation = ident !(_ [=])
                        | literal
                        | charRange
                        | '['
                        | '('
                        | '.'
                        | '!'
                        | '&'

          # Terminals
          ident = [A-Za-z$_] [A-Za-z$_0-9]*
          literal = ['] (!['] .)* ['] | ["] (!["] .)* ["]
          charRange = '[' (!']' .)* ']'
          number = [0-9]+

          _ = $ws (plain_ws | comment | newline)* !(plain_ws | comment | newline)
          comment = '#' (!newline .)* (newline | eof)
          plain_ws = [ \t]+ ![ \t]
          newline = [\n\r]+ ![\n\r]
        """;
    var ambiguousParser = ambiguous.toSMParser();

    const input = r"""
one = 5 | S 's' | 's'*! # wat
      """;

    switch (ambiguousParser.parseAmbiguous("${input.trim()}\n")) {
      case ParseAmbiguousSuccess result:
        expect(result.forest.allPaths().length, equals(3));
      case ParseError error:
        error.displayError(input);
      case _:
        throw Error();
    }
    switch (unambiguousParser.parseAmbiguous("${input.trim()}\n")) {
      case ParseAmbiguousSuccess result:
        expect(result.forest.allPaths().length, equals(1));
      case ParseError error:
        error.displayError(input);
      case _:
        throw Error();
    }
  });
}
