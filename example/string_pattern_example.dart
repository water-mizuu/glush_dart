import 'package:glush/glush.dart';

enum TokenType { if_, then, else_, identifier, number }

enum Command { print_, if_, for_, end }

void main() {
  print('=== String Pattern Abstraction (Seq of Tokens + Action) ===\n');

  // Example 1: Basic string matching
  print('Example 1: Basic String Matching\n');

  final grammar1 = Grammar(() {
    late Rule greeting;
    greeting = Rule('greeting', () {
      return Pattern.string('hello') >> Token(ExactToken(32)) >> Pattern.string('world');
    });
    return greeting;
  });

  final parser1 = SMParser(grammar1);
  final result1 = parser1.parse('hello world');
  print('Parsing "hello world": ${result1 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 2: Keywords with semantic actions
  print('Example 2: Keywords with Type Tags\n');

  final grammar2 = Grammar(() {
    late Rule statement;
    statement = Rule('statement', () {
      final ifKeyword = Pattern.string('if').withAction<TokenType>((span, _) => TokenType.if_);
      return ifKeyword >> Token(ExactToken(32)) >> Token(ExactToken(120)); // space + 'x'
    });
    return statement;
  });

  final parser2 = SMParser(grammar2);
  final result2 = parser2.parse('if x');
  print('Parsing "if x": ${result2 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 3: Literal strings that capture text
  print('Example 3: Literal Capture\n');

  final grammar3 = Grammar(() {
    late Rule msg;
    msg = Rule('msg', () {
      final hello = Pattern.string('hello').withAction<String>((span, _) => span);
      final world = Pattern.string('world').withAction<String>((span, _) => span);
      return hello >> Token(ExactToken(32)) >> world;
    });
    return msg;
  });

  final parser3 = SMParser(grammar3);
  final result3 = parser3.parse('hello world');
  print('Parsing "hello world": ${result3 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 4: Conditional syntax with multiple strings
  print('Example 4: if-then-else Syntax\n');

  final grammar4 = Grammar(() {
    late Rule expr;
    expr = Rule('expr', () {
      return Pattern.string('if') >>
          Token(ExactToken(32)) >>
          Token(ExactToken(120)) >> // ' x'
          Token(ExactToken(32)) >>
          Pattern.string('then') >> // ' then'
          Token(ExactToken(32)) >>
          Token(ExactToken(121)) >> // ' y'
          Token(ExactToken(32)) >>
          Pattern.string('else') >> // ' else'
          Token(ExactToken(32)) >>
          Token(ExactToken(122)); // ' z'
    });
    return expr;
  });

  final parser4 = SMParser(grammar4);
  final result4 = parser4.parse('if x then y else z');
  print('Parsing "if x then y else z": ${result4 is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 5: Showing the abstraction in action
  print('Example 5: Pattern Transformation\n');

  // Manual token sequence (verbose)
  final manualSeq = Token(ExactToken(105)) >> // 'i'
      Token(ExactToken(102)); // 'f'

  // Using Pattern.string() helper (clean abstraction)
  final strSeq = Pattern.string('if');

  print('Manual token sequence for "if": $manualSeq');
  print('Using Pattern.string() for "if": $strSeq');
  print('Both are Seq patterns: ${manualSeq.runtimeType == strSeq.runtimeType}\n');

  // Example 6: Complex grammar with multiple string patterns
  print('Example 6: Language Commands\n');

  final grammar6 = Grammar(() {
    late Rule cmd;
    cmd = Rule('cmd', () {
      return Pattern.string('print') >>
              Token(ExactToken(32)) >>
              Token(ExactToken(120)) | // 'print x'
          Pattern.string('exit'); // or 'exit'
    });
    return cmd;
  });

  final parser6 = SMParser(grammar6);
  final result6a = parser6.parse('print x');
  final result6b = parser6.parse('exit');
  print('Parsing "print x": ${result6a is ParseSuccess ? "Success" : "Failed"}');
  print('Parsing "exit": ${result6b is ParseSuccess ? "Success" : "Failed"}\n');

  // Example 7: Semantic action with custom type
  print('Example 7: Custom Semantic Value\n');

  final grammar7 = Grammar(() {
    late Rule tagged;
    tagged = Rule('tagged', () {
      return Pattern.string('const').withAction<String>((span, _) => 'CONST_KEYWORD');
    });
    return tagged;
  });

  final parser7 = SMParser(grammar7);
  final result7 = parser7.parse('const');
  print('Parsing "const": ${result7 is ParseSuccess ? "Success" : "Failed"}\n');

  print('=== String Pattern Abstraction Summary ===');
  print('• String "abc" becomes: Token(c1) >> Token(c2) >> Token(c3)');
  print('• This is done via Pattern.string() or Grammar.str()');
  print(
      '• withAction<T>() wraps the sequence in semantic action: (Token >> Token).withAction(...)');
  print('• No separate StringPattern class needed');
  print('• Direct composition: (Token >> Token >> ...).withAction<T>(callback)');
}
