import "package:glush/glush.dart";

void main() {
  print("=== String Pattern Abstraction (Seq of Tokens + Action) ===\n");

  // Example 1: Basic string matching
  print("Example 1: Basic String Matching\n");

  var grammar1 = Grammar(() {
    late Rule greeting;
    greeting = Rule("greeting", () {
      return Pattern.string("hello") >> Token(const ExactToken(32)) >> Pattern.string("world");
    });
    return greeting;
  });

  var parser1 = SMParser(grammar1);
  var result1 = parser1.parse("hello world");
  print('Parsing "hello world": ${result1 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 2: Keywords with semantic actions
  print("Example 2: Keywords with Type Tags\n");

  var grammar2 = Grammar(() {
    late Rule statement;
    statement = Rule("statement", () {
      var ifKeyword = Pattern.string("if");
      return ifKeyword >>
          Token(const ExactToken(32)) >>
          Token(const ExactToken(120)); // space + 'x'
    });
    return statement;
  });

  var parser2 = SMParser(grammar2);
  var result2 = parser2.parse("if x");
  print('Parsing "if x": ${result2 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 3: Literal strings that capture text
  print("Example 3: Literal Capture\n");

  var grammar3 = Grammar(() {
    late Rule msg;
    msg = Rule("msg", () {
      var hello = Pattern.string("hello");
      var world = Pattern.string("world");
      return hello >> Token(const ExactToken(32)) >> world;
    });
    return msg;
  });

  var parser3 = SMParser(grammar3);
  var result3 = parser3.parse("hello world");
  print('Parsing "hello world": ${result3 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 4: Conditional syntax with multiple strings
  print("Example 4: if-then-else Syntax\n");

  var grammar4 = Grammar(() {
    late Rule expr;
    expr = Rule("expr", () {
      return Pattern.string("if") >>
          Token(const ExactToken(32)) >>
          Token(const ExactToken(120)) >> // ' x'
          Token(const ExactToken(32)) >>
          Pattern.string("then") >> // ' then'
          Token(const ExactToken(32)) >>
          Token(const ExactToken(121)) >> // ' y'
          Token(const ExactToken(32)) >>
          Pattern.string("else") >> // ' else'
          Token(const ExactToken(32)) >>
          Token(const ExactToken(122)); // ' z'
    });
    return expr;
  });

  var parser4 = SMParser(grammar4);
  var result4 = parser4.parse("if x then y else z");
  print('Parsing "if x then y else z": ${result4 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 5: Showing the abstraction in action
  print("Example 5: Pattern Transformation\n");

  // Manual token sequence (verbose)
  var manualSeq =
      Token(const ExactToken(105)) >> // 'i'
      Token(const ExactToken(102)); // 'f'

  // Using Pattern.string() helper (clean abstraction)
  var strSeq = Pattern.string("if");

  print('Manual token sequence for "if": $manualSeq');
  print('Using Pattern.string() for "if": $strSeq');
  print("Both are Seq patterns: ${manualSeq.runtimeType == strSeq.runtimeType}\n");

  // Example 6: Complex grammar with multiple string patterns
  print("Example 6: Language Commands\n");

  var grammar6 = Grammar(() {
    late Rule cmd;
    cmd = Rule("cmd", () {
      return Pattern.string("print") >>
              Token(const ExactToken(32)) >>
              Token(const ExactToken(120)) | // 'print x'
          Pattern.string("exit"); // or 'exit'
    });
    return cmd;
  });

  var parser6 = SMParser(grammar6);
  var result6a = parser6.parse("print x");
  var result6b = parser6.parse("exit");
  print('Parsing "print x": ${result6a is ParseSuccess ? "Success" : "Failed"}');
  print('Parsing "exit": ${result6b is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 7: Semantic action with custom type
  print("Example 7: Custom Semantic Value\n");

  var grammar7 = Grammar(() {
    late Rule tagged;
    tagged = Rule("tagged", () {
      return Pattern.string("const");
    });
    return tagged;
  });

  var parser7 = SMParser(grammar7);
  var result7 = parser7.parse("const");
  print('Parsing "const": ${result7 is ParseSuccess ? "Success" : "Failed"}\n');

  print("=== String Pattern Abstraction Summary ===");
  print('• String "abc" becomes: Token(c1) >> Token(c2) >> Token(c3)');
  print("• This is done via Pattern.string() or Grammar.str()");
  print(
    "• withAction<T>() wraps the sequence in semantic action: (Token >> Token).withAction(...)",
  );
  print("• No separate StringPattern class needed");
  print("• Direct composition: (Token >> Token >> ...).withAction<T>(callback)");
}
