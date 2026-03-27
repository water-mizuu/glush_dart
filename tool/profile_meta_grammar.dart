import "package:glush/glush.dart";

const metaGrammarString = r"""
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
        literal = ['] (!['] .)* ['] | ["] (![\"] .)* ["]
        charRange = '[' (!']' .)* ']'
        number = [0-9]+

        _ = $ws (plain_ws | comment | newline)* !plain_ws !comment !newline
        comment = '#' (!newline .)* (newline | eof)
        plain_ws = [ \t]+ ![ \t]
        newline = [\n\r]+ ![\n\r]
      """;

T measure<T>(String label, int n, T Function() fn) {
  T? last;
  var total = 0;
  for (var i = 0; i < n; i++) {
    var sw = Stopwatch()..start();
    last = fn();
    sw.stop();
    total += sw.elapsedMicroseconds;
  }
  print("$label avg_ms=${(total / n / 1000).toStringAsFixed(3)} n=$n");
  return last as T;
}

void main() {
  measure("GrammarFileParser.parse(meta)", 30, () => GrammarFileParser(metaGrammarString).parse());
  var ast = measure(
    "GrammarFileParser.parse(meta) once for compile",
    1,
    () => GrammarFileParser(metaGrammarString).parse(),
  );
  measure(
    "GrammarFileCompiler.compile(meta)",
    30,
    () => GrammarFileCompiler(ast).compile(startRuleName: "full"),
  );
  var grammar = measure("compile+SMParserMini ctor", 10, () {
    var g = GrammarFileCompiler(
      GrammarFileParser(metaGrammarString).parse(),
    ).compile(startRuleName: "full");
    return SMParserMini(g);
  });
  measure("metaParser.parse(simple)", 50, () => grammar.parse("rule = 'a'\n"));
  measure("metaParser.parse(self)", 5, () => print(grammar.parse(metaGrammarString)));
}
