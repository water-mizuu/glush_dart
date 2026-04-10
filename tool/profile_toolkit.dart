import "package:glush/glush.dart";

const _metaGrammarString = r"""
        # ==========================
        #   Full Meta Grammar
        # ==========================
        full = $full start _ file:file _ eof

        file = $rules left:file _ right:rule
            | $first rule:rule

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

        ident = [A-Za-z$_] [A-Za-z$_0-9]*
        literal = ['] (!['] .)* ['] | ["] (![\"] .)* ["]
        charRange = '[' (!']' .)* ']'
        number = [0-9]+

        _ = $ws (plain_ws | comment | newline)* !plain_ws !comment !newline
        comment = '#' (!newline .)* (newline | eof)
        plain_ws = [ \t]+ ![ \t]
        newline = [\n\r]+ ![\n\r]
      """;

const _forestGrammarString = r"""
start = item ':' item
item = name:word
word = [a-z]+
""";

const _dataDrivenGrammarString = r"""
start = capture:times(3, 's') check(capture, 3) '!'

times(n, char) = _times(n, char)
_times(n, char) = if (n > 1) cdr:_times(n - 1, char) car:char
               | if (n == 1) char
               | if (n <= 0) ''

check(value, n) = if (value.length == n) ''
""";

void _runProfile(String label, void Function() action) {
  GlushProfiler.reset();
  GlushProfiler.enabled = true;
  var watch = Stopwatch()..start();
  try {
    action();
  } finally {
    watch.stop();
    GlushProfiler.enabled = false;
  }

  print("== $label ==");
  print("wall_ms=${(watch.elapsedMicroseconds / 1000).toStringAsFixed(3)}");
  print(GlushProfiler.snapshot().report());
  print("");
}

void _profileMeta() {
  var ast = GrammarFileParser(_metaGrammarString).parse();
  var grammar = GrammarFileCompiler(ast).compile(startRuleName: "full");
  var parser = SMParserMini(grammar);

  _runProfile("meta-self-parse", () {
    parser.parse(_metaGrammarString);
  });
}

void _profileDataDriven() {
  var grammar = GrammarFileCompiler(
    GrammarFileParser(_dataDrivenGrammarString).parse(),
  ).compile(startRuleName: "start");
  var parser = SMParserMini(grammar);

  _runProfile("data-driven-parse", () {
    var outcome = parser.parse("sss!");
    if (outcome case ParseSuccess(:var result)) {
      const StructuredEvaluator().evaluate(result.rawMarks);
    }
  });
}

void _profileForest() {
  var grammar = GrammarFileCompiler(
    GrammarFileParser(_forestGrammarString).parse(),
  ).compile(startRuleName: "start");
  var parser = SMParser(grammar);

  _runProfile("parse-ambiguous", () {
    var outcome = parser.parseAmbiguous("alpha:beta", captureTokensAsMarks: true);
    if (outcome case ParseAmbiguousSuccess(:var forest)) {
      const StructuredEvaluator().evaluate(forest.allMarkPaths().single);
    }
  });
}

void main() {
  _runProfile("compiler-only", () {
    var ast = GrammarFileParser(_metaGrammarString).parse();
    GrammarFileCompiler(ast).compile(startRuleName: "full");
  });
  _profileMeta();
  _profileDataDriven();
  _profileForest();
}
