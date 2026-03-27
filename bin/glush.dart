// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:developer";
import "dart:io";
import "dart:math" show max;
import "package:glush/glush.dart";

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
                " ${(v.$1 + 1).toString().padLeft(longest)} | "
                "${v.$2}",
          )
          .join("\n"),
    );
    print("${" " * " ${''.padLeft(longest)} | ".length}${' ' * (column - 1)}^");
  }
}

extension on Pattern {
  Pattern operator /(Pattern other) => Alt(this, Seq(not(), other));
}

void mathSimple() {
  var parser =
      r"""
        expr =
              $add expr _ '+' _ expr
            | $num [0-9]+

        _ = [ \t\n\r]*
      """
          .toSMParser();

  const input = "1 + 2 + 3";
  var ambiguousResult = parser.parseAmbiguous(input);
  var evaluator = Evaluator<String>({
    "add": (ctx) => "(${ctx.next()} + ${ctx.next()})",
    "num": (ctx) => ctx.span.trim(),
  });
  if (ambiguousResult is ParseAmbiguousForestSuccess) {
    for (var result in ambiguousResult.forest.allPaths()) {
      var tree = result.evaluateStructure();
      print(evaluator.evaluate(tree));
    }
  }
}

void ambiguous() {
  var parser =
      r"""
        S = $TWO S S
          | $ONE s
        s = 's';
      """
          .toSMParser();

  var evaluator = Evaluator<String>({
    "TWO": (ctx) => "(${ctx.next()}${ctx.next()})",
    "ONE": (ctx) => "s",
  });

  for (int length = 1; length <= 5; ++length) {
    var input = "s" * length;
    var result = parser.parseAmbiguous(input);
    if (result is! ParseAmbiguousForestSuccess) {
      print("Failed to parse $input!");
      continue;
    }

    print(length);
    print("=" * 30);
    for (var markList in result.forest.allPaths()) {
      var tree = markList.evaluateStructure();
      var evaluated = evaluator.evaluate(tree);
      print(evaluated);
    }
    print("");
  }
}

void orderedChoice() {
  var grammar = Grammar(() {
    late Rule ab;
    late Rule c;
    c = Rule("c", () => ab() >> Token.char("c"));
    ab = Rule("ab", () => (Pattern.string("abc")) / (Pattern.string("ab")) / Token.char("a"));

    return c;
  });
  var parser = SMParserMini(grammar);
  var result = parser.parseAmbiguous("abc");
  print(result);
  if (result case ParseAmbiguousForestSuccess result) {
    print(result.forest.allPaths().toList());
  }
}

void meta() {
  var grammar = GrammarFileCompiler(
    GrammarFileParser(r"""
        # ==========================
        #   Full Meta Grammar
        # ==========================
        full = $full start _ file:file _ eof

        file = $rules left:file _ right:rule
             | rule

        # Allow trailing trivia after a rule body so line comments behave
        # like whitespace instead of becoming the next token stream.
        rule = $rule     name:ident                        _ '=' _ body:choice _ (';')?
             | $dataRule name:ident '(' params:params? ')' _ '=' _ body:choice _ (';')?

        choice = $rest left:choice _ (prec:number _)? '|' _ right:branch
               | $first ((prec:number _)? '|' _)? body:branch

        branch = $cond "if" _ "(" _ cond:argExpr _ ")"_ body:seq
               | $none body:seq

        seq = $seq left:seq _ &isContinuation right:conj
            | conj

        conj = $conj left:conj _ "&&" _ right:prefix
             | prefix

        prefix = $and '&' atom:rep
               | $not '!' atom:rep
               | rep

        rep = $rep atom:primary kind:repKind
            | primary

        repKind = $star '*'      | $plus '+'
                | $starBang "*!" | $plusBang "+!"
                | $question '?'

        primary = $group '(' _ inner:choice _ ')'
                | $label name:ident ':' atom:primary
                | $mark '$' name:ident
                | $start "start"
                | $end "eof"
                | $call name:ident ('(' _ args:args? _ ')')?
                | $lit literal
                | $range charRange
                | $any '.'

        # Helpers
        isContinuation = ident !(_ [=])
                       | literal | charRange
                       | '[' | '(' | '.' | '!' | '&'

        params = $params left:params _ ',' _ right:param
               | $param  right:param

        param = ident

        args = $args left:args _ ',' _ right:arg
             | $arg right:arg

        arg = $namedArg name:ident _ ':' _ expr:argExpr^0
            | $posArg expr:argExpr^0

        argExpr =
              # Logical Operations
              1 | $argOr   left:argExpr^1 _ '||' _ right:argExpr^2
              2 | $argAnd  left:argExpr^2 _ '&&' _ right:argExpr^3

              # Equality & Relational Operations
              3 | $argEq   left:argExpr^5 _ '==' _ right:argExpr^5
              3 | $argNeq  left:argExpr^5 _ '!=' _ right:argExpr^5
              4 | $argLt   left:argExpr^5 _ '<'  _ right:argExpr^5
              4 | $argLte  left:argExpr^5 _ '<=' _ right:argExpr^5
              4 | $argGt   left:argExpr^5 _ '>'  _ right:argExpr^5
              4 | $argGte  left:argExpr^5 _ '>=' _ right:argExpr^5

              # Arithmetic Operations
              6 | $argAdd  left:argExpr^6  _ '+' _ right:argExpr^7
              6 | $argSub  left:argExpr^6  _ '-' _ right:argExpr^7
              7 | $argMul  left:argExpr^7 _ '*' _ right:argExpr^8
              7 | $argDiv  left:argExpr^7 _ '/' _ right:argExpr^8
              7 | $argMod  left:argExpr^7 _ '%' _ right:argExpr^8

              # Unary Operations (Prefix)
             10 | $argNot  '!' _ right:argExpr^10
             10 | $argNeg  '-' _ right:argExpr^10
             10 | $argPos  '+' _ right:argExpr^10

              # Atomic Values
             20 | $argInt  number
             20 | $argStr  literal
             20 | $argIdent ident
             20 | $argGroup '(' _ expr:argExpr^0 _ ')'

        # Terminals
        ident = [A-Za-z$_] [A-Za-z$_0-9]*!
        literal = ['] ([\] . | !['] .)*! [']
                | ["] ([\] . | !["] .)*! ["]
        charRange = '[' (!']' .)*! ']'
        number = [0-9]+

        _ = $ws (plain_ws | comment | newline)*!
        comment = '#' (!newline .)* (newline | eof)
        plain_ws = [ \t]+!
        newline = [\n\r]+!
      """).parse(),
  ).compile(startRuleName: "full");

  var parser = SMParserMini(grammar);
  var evaluator = Evaluator({
    "full.full": (ctx) => ctx<Object>("file"),
    "file.rules": (ctx) => [ctx<Object>("left"), ctx<Object>("right")],
    "file.first": (ctx) => ctx<Object>("rule"),
    "rule.rule": (ctx) => [ctx<String>("name"), null, ctx<Object>("body")],
    "rule.dataRule": (ctx) => [
      ctx<String>("name"),
      ctx.optional<Object>("params"),
      ctx<Object>("body"),
    ],

    /// choice
    "choice.rest": (ctx) {
      var left = ctx<Object>("left");
      var right = ctx<Object>("right");
      if (ctx.optional<Object>("prec") case var prec?) {
        right = [prec, right];
      }
      return [left, right];
    },
    "choice.first": (ctx) {
      var body = ctx<Object>("body");
      if (ctx.optional<Object>("prec") case var prec?) {
        return [prec, body];
      } else {
        return body;
      }
    },

    "branch.cond": (ctx) => ["if", ctx<Object>("cond"), ctx<Object>("body")],
    "branch.none": (ctx) => ctx<Object>("body"),

    /// seq
    "seq.seq": (ctx) => ["seq", ctx<Object>("left"), ctx<Object>("right")],

    /// conj
    "conj.conj": (ctx) => ["&&", ctx<Object>("left"), ctx<Object>("right")],

    /// prefix
    "prefix.and": (ctx) => ["&", ctx<Object>("atom")],
    "prefix.not": (ctx) => ["!", ctx<Object>("atom")],

    /// rep
    "rep.rep": (ctx) => [ctx<String>("kind"), ctx<Object>("atom")],

    /// repKind
    "repKind.star": (ctx) => "*",
    "repKind.plus": (ctx) => "+",
    "repKind.starBang": (ctx) => "*!",
    "repKind.plusBang": (ctx) => "+!",
    "repKind.question": (ctx) => "?",

    /// primary
    "primary.group": (ctx) => ctx<Object>("inner"),
    "primary.label": (ctx) => (ctx<String>("name"), ctx<Object>("body")),
    "primary.mark": (ctx) => '\$${ctx<String>('name')}',
    "primary.start": (ctx) => ["start"],
    "primary.end": (ctx) => ["end"],
    "primary.call": (ctx) => ["ref", ctx<String>("name"), ctx.optional<Object>("args")],
    "primary.lit": (ctx) => ["lit", ctx.span],
    "primary.range": (ctx) => ["range", ctx.span],
    "primary.any": (ctx) => ".",
    "name": (ctx) => ["name", ctx.span],

    /// helpers
    "params.params": (ctx) => [...ctx<List>("left"), ctx<Object>("right")],
    "params.param": (ctx) => [ctx<Object>("right")],

    "args.args": (ctx) => [...ctx<List>("left"), ctx<Object>("right")],
    "args.arg": (ctx) => [ctx<Object>("right")],
    "arg.namedArg": (ctx) => [ctx<Object>("name"), ctx<Object>("expr")],
    "arg.posArg": (ctx) => ctx<Object>("expr"),

    /// argExpr
    // Logical Operators
    "argExpr.argOr": (ctx) => ["||", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argAnd": (ctx) => ["&&", ctx<Object>("left"), ctx<Object>("right")],

    // Relational Operators
    "argExpr.argEq": (ctx) => ["==", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argNeq": (ctx) => ["!=", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argLt": (ctx) => ["<", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argLte": (ctx) => ["<=", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argGt": (ctx) => [">", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argGte": (ctx) => [">=", ctx<Object>("left"), ctx<Object>("right")],

    // Arithmetic
    "argExpr.argAdd": (ctx) => ["+", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argSub": (ctx) => ["-", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argMul": (ctx) => ["*", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argDiv": (ctx) => ["/", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.argMod": (ctx) => ["%", ctx<Object>("left"), ctx<Object>("right")],

    // Unary
    "argExpr.argNot": (ctx) => ["!", ctx<Object>("right")],
    "argExpr.argNeg": (ctx) => ["-", ctx<Object>("right")],
    "argExpr.argPos": (ctx) => ["+", ctx<Object>("right")],
    "argExpr.argInt": (ctx) => ["int", ctx.span],
    "argExpr.argStr": (ctx) => ["str", ctx.span],
    "argExpr.argIdent": (ctx) => ["ident", ctx.span],
    "argExpr.argGroup": (ctx) => ctx<Object>("expr"),

    /// whitespace
    "ws": (ctx) => "WS: ${ctx.span}",
  });

  const input = r"""
    one(a, b) =
      5 | S 's' && 'b' "a\"b"
        | 's'*! # wat
    two = 's' one(5, 2 + 3 <= 4)""";

  var result = parser.parseAmbiguous(input.trim());
  print(result);

  switch (result) {
    case ParseAmbiguousForestSuccess result:
      print(result.forest.allPaths().length);
      var output = StringBuffer()..writeln("Evaluated Meta Grammar Paths:");
      for (var path in result.forest.allPaths()) {
        var tree = path.evaluateStructure();
        var evaluated = evaluator.evaluate(tree);
        output.writeln(evaluated);
        print((evaluated as List<Object?>?)?.join("\n"));
      }

      var outputFile = File("meta_out.txt");
      outputFile.writeAsStringSync(output.toString());
    case ParseError error:
      error.displayError(input);
    case _:
      throw Error();
  }
}

void dataDriven() {
  var parser =
      r"""
      start = element
      element = openTag body closeTag(tag)
      openTag = '<' tag:name '>'
      closeTag(tag) = '</' close:name '>' verify(tag, close)
      verify(open, close) = if (open == close) ''
      body = text
      text = [A-Za-z ]+
      name = [A-Za-z_] [A-Za-z0-9_]*

      """
          .toSMParser();

  for (var input in ["<book>Hello</book>", "<book>Hello</author></book>"]) {
    switch (parser.parseAmbiguous(input)) {
      case ParseAmbiguousForestSuccess result:
        print("$input -> dataDriven ok: ${result.forest.allPaths().length}");
      case ParseError error:
        error.displayError(input);
      case _:
        throw Error();
    }
  }
}

void dataDriven2() {
  var parser =
      r"""
      start = capture:"abc" check(capture)
      check(capture) = if (capture.length == 3) ''
      """
          .toSMParser();

  for (var input in ["ab", "abc"]) {
    Timeline.startSync("Parsing Phase $input");
    var result = parser.parseAmbiguous(input);
    print(result);
    if (result case ParseAmbiguousForestSuccess result) {
      print(result.forest.allPaths().map((v) => v.evaluateStructure()).toList());
    }
    Timeline.finishSync();
  }
  // print(
  //   (parser.parseWithForest("sss") as ParseAmbiguousForestSuccess).forest
  //       .allPaths()
  //       .map((v) => v.evaluateStructure())
  //       .toList(),
  // );
}

void main() async {
  mathSimple();
  ambiguous();
  orderedChoice();
  meta();
  dataDriven();
  dataDriven2();
}
