import 'dart:math' show max;

import 'package:glush/glush.dart';

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
  final evaluator = Evaluator(
    ($) => {
      'add': () => "(${$<String>()} + ${$<String>()})", //
      'num': () => $<String>().trim(),
    },
  );
  if (ambiguousResult is ParseAmbiguousForestSuccess) {
    for (var result in ambiguousResult.forest.allPaths()) {
      print(evaluator.evaluate(result.toShortMarks()));
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

  final evaluator = Evaluator(
    ($) => {
      r'TWO': () => "(${$<String>()}${$<String>()})", //
      r'ONE': () => 's',
    },
  );

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
      final rawMarks = markList.toStringList();
      final evaluated = evaluator.evaluate(rawMarks);
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
#   Top level structure
# ==========================
full = $full _ $file file _

file = $rules $left file _ $right rule
     | rule

rule = $rule $name ident _ $eq '=' _ $body pattern

pattern = ident
ident = [A-Za-z$_] [A-Za-z$_0-9]*

_ = $ws (plain_ws | comment | newline)*
comment = '#' (!newline .)*
plain_ws = [ \t]+
newline = [\n\r]+
      """
          .toSMParser(startRuleName: 'full');

  final evaluator = Evaluator(($) {
    return {
      "full": () {
        $<String>(); // Whitespace
        final body = $<Object>();
        $<String>(); // Whitespace

        return body;
      },

      "rules": () {
        final existing = $<List<Object>>();
        $<String>(); // Whitespace
        final newRule = $<Object>();

        return [...existing, newRule];
      },
      "rule": () {
        final name = $<String>();
        $<String>(); // Whitespace
        $<String>(); // '='
        $<String>(); // Whitespace
        final body = $<Object>();

        return (name, body);
      },
    };
  });
  for (final rule in parser.stateMachine.grammar.rules) {
    print((rule.name, rule.body()));
  }

  final input =
      """
abc = c #has=b
"""
          .trimLeft();

  switch (parser.parseAmbiguous(input, captureTokensAsMarks: true)) {
    case ParseAmbiguousForestSuccess result:
      for (final tree in result.forest.allPaths()) {
        final marks = tree.toShortMarks();
        print(marks);

        final result = evaluator.evaluate(marks);
        print(result);
      }
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
    case _:
      throw Error();
  }
}

void main() async {
  // mathSimple();
  // ambiguous();
  // orderedChoice();
  meta();
  print('a="a"*a'.toSMParser().parse('aaaa'));
}
