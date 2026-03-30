// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:convert";
import "dart:developer";
import "dart:io";
import "package:glush/glush.dart";

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
  if (ambiguousResult is ParseAmbiguousSuccess) {
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
    if (result is! ParseAmbiguousSuccess) {
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
  if (result case ParseAmbiguousSuccess result) {
    print(result.forest.allPaths().toList());
  }
}

void meta() {
  const grammarString = r"""
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
                | $call name:ident ('(' _ args:args? _ ')')? ( '^' prec:number )?
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
              1 | $or   left:argExpr^1 _ '||' _ right:argExpr^2
              2 | $and  left:argExpr^2 _ '&&' _ right:argExpr^3

              # Equality & Relational Operations
              3 | $eq   left:argExpr^5 _ '==' _ right:argExpr^5
              3 | $neq  left:argExpr^5 _ '!=' _ right:argExpr^5
              4 | $lt   left:argExpr^5 _ '<'  _ right:argExpr^5
              4 | $lte  left:argExpr^5 _ '<=' _ right:argExpr^5
              4 | $gt   left:argExpr^5 _ '>'  _ right:argExpr^5
              4 | $gte  left:argExpr^5 _ '>=' _ right:argExpr^5

              # Arithmetic Operations
              6 | $add  left:argExpr^6  _ '+' _ right:argExpr^7
              6 | $sub  left:argExpr^6  _ '-' _ right:argExpr^7
              7 | $mul  left:argExpr^7 _ '*' _ right:argExpr^8
              7 | $div  left:argExpr^7 _ '/' _ right:argExpr^8
              7 | $mod  left:argExpr^7 _ '%' _ right:argExpr^8

              # Unary Operations (Prefix)
             10 | $not  '!' _ right:argExpr^10
             10 | $neg  '-' _ right:argExpr^10
             10 | $pos  '+' _ right:argExpr^10

              # Atomic Values
             20 | $int  number
             20 | $str  literal
             20 | $ident ident
             20 | $group '(' _ expr:argExpr^0 _ ')'

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
      """;

  var grammar = GrammarFileCompiler(
    GrammarFileParser(grammarString).parse(),
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
    "primary.label": (ctx) => [ctx<String>("name"), ctx<Object>("atom")],
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
    "argExpr.or": (ctx) => ["||", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.and": (ctx) => ["&&", ctx<Object>("left"), ctx<Object>("right")],

    // Relational Operators
    "argExpr.eq": (ctx) => ["==", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.neq": (ctx) => ["!=", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.lt": (ctx) => ["<", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.lte": (ctx) => ["<=", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.gt": (ctx) => [">", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.gte": (ctx) => [">=", ctx<Object>("left"), ctx<Object>("right")],

    // Arithmetic
    "argExpr.add": (ctx) => ["+", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.sub": (ctx) => ["-", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.mul": (ctx) => ["*", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.div": (ctx) => ["/", ctx<Object>("left"), ctx<Object>("right")],
    "argExpr.mod": (ctx) => ["%", ctx<Object>("left"), ctx<Object>("right")],

    // Unary
    "argExpr.not": (ctx) => ["!", ctx<Object>("right")],
    "argExpr.neg": (ctx) => ["-", ctx<Object>("right")],
    "argExpr.pos": (ctx) => ["+", ctx<Object>("right")],
    "argExpr.int": (ctx) => ["int", ctx.span],
    "argExpr.str": (ctx) => ["str", ctx.span],
    "argExpr.ident": (ctx) => ["ident", ctx.span],
    "argExpr.group": (ctx) => ctx<Object>("expr"),

    /// whitespace
    "ws": (ctx) => "WS: ${ctx.span}",
  });

  // const input = r"""
  //   one(a, b) =
  //     5 | S 's' && 'b' "a\"b"
  //       | 's'*! # wat
  //   two = 's' one(5, 2 + 3 <= 4)""";

  var result = parser.parseAmbiguous(grammarString);
  print(result);

  switch (result) {
    case ParseAmbiguousSuccess result:
      var output = StringBuffer()..writeln("Evaluated Meta Grammar Paths:");
      for (var path in result.forest.allPaths().take(1)) {
        var tree = path.evaluateStructure();
        var evaluated = evaluator.evaluate(tree);
        output.writeln(evaluated);
        File("test.txt")
          ..createSync(recursive: true)
          ..writeAsStringSync(
            const JsonEncoder.withIndent("  ").convert(evaluated as List<Object?>?),
          );
      }

      var outputFile = File("meta_out.txt");
      outputFile.writeAsStringSync(output.toString());
    case ParseError error:
      error.displayError(grammarString);
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
      case ParseAmbiguousSuccess result:
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
    if (result case ParseAmbiguousSuccess result) {
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

void dataDriven3() {
  const grammarText = r"""
        start = t:repeat(3) check(t.length, t)
        repeat(n) = if (n > 1) repeat(n - 1) 's'
                  | if (n == 1) 's'
        check(length, t) = if (length == 3 && t.startPosition == 0) ''
      """;

  var parser = grammarText.toSMParser();

  for (var rule in parser.stateMachine.grammar.rules) {
    print((rule.name, rule.body()));
  }

  print(parser.recognize("sss"));
  print((parser.parse("sss") as ParseSuccess).result);
}

void dataDriven4() {
  const grammarText = r"""
    double = $A m:(v:.) cap(m)
    cap(m) = m
  """;

  var parser = grammarText.toSMParserMini();
  print(parser.parse("bb"));
}

void main() async {
  // mathSimple();
  // ambiguous();
  // orderedChoice();
  meta();
  // dataDriven();
  // dataDriven2();
  // dataDriven3();
  // dataDriven4();
}
