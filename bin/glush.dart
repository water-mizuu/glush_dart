import 'dart:io';
import 'dart:math' show max;
import 'package:glush/glush.dart';

extension ShowErrors on ParseError {
  void displayError(String input) {
    List<String> inputRows = input.replaceAll("\r", "").split("\n");

    /// Surely the string we're trying to parse is not empty.
    if (inputRows.isEmpty) {
      throw StateError("Huh?");
    }

    int row = input.substring(0, position).split("\n").length;
    int column =
        input //
            .substring(0, position)
            .split("\n")
            .last
            .codeUnits
            .length +
        1;
    List<(int, String)> displayedRows = inputRows.indexed.toList().sublist(max(row - 3, 0), row);

    int longest = displayedRows.map((e) => e.$1.toString().length).reduce(max);

    print("Parse error at: ($row:$column)");
    print(
      displayedRows
          .map(
            (v) =>
                " ${(v.$1 + 1).toString().padLeft(longest, ' ')} | "
                "${v.$2}",
          )
          .join("\n"),
    );
    print("${" " * " ${''.padLeft(longest, ' ')} | ".length}${' ' * (column - 1)}^");
  }
}

extension on Pattern {
  Pattern operator /(Pattern other) => Alt(this, Seq(not(), other));
}

void mathSimple() {
  final parser =
      r"""
        expr =
              $add expr _ '+' _ expr
            | $num [0-9]+

        _ = [ \t\n\r]*
      """
          .toSMParser();

  final input = '1 + 2 + 3';
  final ambiguousResult = parser.parseAmbiguous(input);
  final evaluator = Evaluator<String>({
    'add': (ctx) => "(${ctx.next()} + ${ctx.next()})",
    'num': (ctx) => ctx.span.trim(),
  });
  if (ambiguousResult is ParseAmbiguousForestSuccess) {
    for (var result in ambiguousResult.forest.allPaths()) {
      final tree = StructuredEvaluator().evaluate(result);
      print(evaluator.evaluate(tree));
    }
  }
}

void ambiguous() {
  final parser =
      r"""
        S = $TWO S S
          | $ONE s
        s = 's';
      """
          .toSMParser();

  final evaluator = Evaluator<String>({
    r'TWO': (ctx) => "(${ctx.next()}${ctx.next()})",
    r'ONE': (ctx) => 's',
  });

  for (int length = 1; length <= 5; ++length) {
    final input = 's' * length;
    final result = parser.parseAmbiguous(input);
    if (result is! ParseAmbiguousForestSuccess) {
      print("Failed to parse $input!");
      continue;
    }

    print(length);
    print("=" * 30);
    for (final markList in result.forest.allPaths()) {
      final tree = StructuredEvaluator().evaluate(markList);
      final evaluated = evaluator.evaluate(tree);
      print(evaluated);
    }
    print("");
  }
}

void orderedChoice() {
  var grammar = Grammar(() {
    late Rule ab, c;
    c = Rule('c', () => ab() >> Token.char('c'));
    ab = Rule('ab', () => (Pattern.string('abc')) / (Pattern.string('ab')) / Token.char('a'));

    return c;
  });
  var parser = SMParserMini(grammar);
  var result = parser.parseAmbiguous('abc');
  print(result);
  if (result case ParseAmbiguousForestSuccess result) {
    print(result.forest.allPaths().toList());
  }
}

void meta() {
  final parser =
      r"""
        # ==========================
        #   Full Meta Grammar
        # ==========================
        full = $full _ file:file _

        file = $rules left:file _ right:rule
            | $first rule:rule

        rule = $rule name:ident _ '=' _ body:choice ( _ ';' )?

        choice = $choice left:choice _ '|' _ right:seq
              | seq

        seq = $seq left:seq _ (&isContinuation) right:prefix
            | prefix

        prefix = $and '&' atom:rep
              | $not '!' atom:rep
              | rep

        rep = $rep atom:primary kind:repKind
            | primary

        repKind = $star '*' | $plus '+' | $question '?'

        primary = $group '(' _ inner:choice _ ')'
                | $label name:ident ':' atom:primary
                | $mark '$' name:ident
                | $ref name:ident
                | $lit literal
                | $range charRange
                | $any '.'

        isContinuation = &(ident !(_ [=]))
                      | &literal
                      | &charRange
                      | &'['
                      | &'('
                      | &'.'
                      | &'$'
                      | &'!'
                      | &'&'

        # Terminals
        ident = [A-Za-z$_] [A-Za-z$_0-9]*
        literal = ['] (!['] .)* ['] | ["] (!["] .)* ["]
        charRange = '[' (!']' .)* ']'

        _ = $ws (plain_ws | comment | newline)*
        comment = '#' (!newline .)*
        plain_ws = [ \t]+
        newline = [\n\r]+
      """
          .toSMParser(startRuleName: 'full');

  for (Rule rule in parser.grammar.rules) {
    print((rule.name, rule.body()));
  }
  final evaluator = Evaluator<Object?>({
    "full": (ctx) => ctx<Object?>('file'),
    "rules": (ctx) {
      final left = ctx<List>('left');
      final right = ctx<Object?>('right');
      return [...left, right];
    },
    "first": (ctx) => [ctx<Object?>('rule')],
    "rule": (ctx) => (ctx<String>('name'), ctx<Object?>('body')),
    "choice": (ctx) => ['|', ctx<Object?>('left'), ctx<Object?>('right')],
    "seq": (ctx) {
      final children = ctx.it.takeAll();
      print("SEQ count: ${children.length}");
      return ['seq', ctx<Object?>('left'), ctx<Object?>('right')];
    },
    "conj": (ctx) => ['&', ctx<Object?>('left'), ctx<Object?>('right')],
    "and": (ctx) => ['&', ctx<Object?>('atom')],
    "not": (ctx) => ['!', ctx<Object?>('atom')],
    "rep": (ctx) => [ctx<String>('kind'), ctx<Object?>('atom')],
    "star": (ctx) => '*',
    "plus": (ctx) => '+',
    "question": (ctx) => '?',
    "group": (ctx) => ctx<Object?>('inner'),
    "label": (ctx) => (ctx<String>('name'), ctx<Object?>('atom')),
    "mark": (ctx) => '\$${ctx<String>('name')}',
    "ref": (ctx) => ctx<String>('name'),
    "lit": (ctx) => ctx.span,
    "range": (ctx) => ctx.span,
    "any": (ctx) => '.',
    "name": (ctx) => ctx.span,
    "ws": (ctx) => ctx.span,
  });

  final input = r"""
abc = c | &d !e* # complex
xyz = 'foo' [a-z] $mark
""";

  switch (parser.parseAmbiguous(input.trim(), captureTokensAsMarks: true)) {
    case ParseAmbiguousForestSuccess result:
      var output = "Evaluated Meta Grammar Paths:\n";
      for (final treePath in result.forest.allPaths()) {
        final tree = StructuredEvaluator().evaluate(treePath);
        final evaluated = evaluator.evaluate(tree);
        output += "$evaluated\n";
      }
      File('meta_out.txt').writeAsStringSync(output);
      print("Output written to meta_out.txt");
      break;
    case ParseError(:var position):
      List<String> inputRows = input.replaceAll("\r", "").split("\n");

      /// Surely the string we're trying to parse is not empty.
      if (inputRows.isEmpty) {
        throw StateError("Huh?");
      }

      int row = input.substring(0, position).split("\n").length;
      int column =
          input //
              .substring(0, position)
              .split("\n")
              .last
              .codeUnits
              .length +
          1;
      List<(int, String)> displayedRows = inputRows.indexed.toList().sublist(max(row - 3, 0), row);

      int longest = displayedRows.map((e) => e.$1.toString().length).reduce(max);

      print("Parse error at: ($row:$column)");
      print(
        displayedRows
            .map(
              (v) =>
                  " ${(v.$1 + 1).toString().padLeft(longest, ' ')} | "
                  "${v.$2}",
            )
            .join("\n"),
      );
      print("${" " * " ${''.padLeft(longest, ' ')} | ".length}${' ' * (column - 1)}^");
      break;
    case _:
      throw Error();
  }
}

void main() async {
  // mathSimple();
  // ambiguous();
  // orderedChoice();
  // meta();
  var smol =
      r"""
        file = leading_ws comments trailing_ws

        comments = acc:comments (newline curr:commentLine)
                 | commentLine
        commentLine = $comment '#' (!newline .)*

        leading_ws = $ws plain_ws*
        trailing_ws = $ws (plain_ws | newline)*

        plain_ws = [ \t]+
        newline = [\n\r]+
      """
          .toSMParser();

  const input = """
# abc
# deadf
""";

  switch (smol.parseAmbiguous(input, captureTokensAsMarks: true)) {
    case ParseError error:
      error.displayError(input);
    case ParseAmbiguousForestSuccess(:var forest):
      print(forest.allPaths().length);
      print(forest.allPaths().join("\n"));
    case _:
      break;
  }
}
