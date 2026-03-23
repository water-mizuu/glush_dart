import 'package:glush/glush.dart';
import 'interpreter.dart';

void main() {
  final grammarString = r'''
    # ============================================
    # Program structure
    # ============================================
    program = (_ (function:def | statement:stmt) _)*

    # ============================================
    # Function definitions and blocks
    # ============================================
    def = 'fn' _ name:identifier _ "(" _ params:params _ ")" _ body:block;
    params = (name:identifier (_ "," _ name:identifier)*)?;
    block = "{" _ (stmts:stmt _)* "}";

    # ============================================
    # Statements
    # ============================================
    stmt = decl:declaration
         | assign:assignment
         | call:functionCall
         | ifStmt:ifStatement
         | whileStmt:whileLoop;

    declaration = "let" _ name:identifier _ "=" _ value:expression _ ";";
    assignment = name:identifier _ "=" _ value:expression _ ";";
    functionCall = name:identifier _ "(" _ arguments:args _ ")" _ ";";

    # ============================================
    # Control flow
    # ============================================
    ifStatement = "if" _ "(" _ cond:expression _ ")"
                  _ then:block (_ "else" _ else:block)?;
    whileLoop = "while" _ "(" _ cond:expression _ ")" _ body:block;

    # ============================================
    # Expressions and operators
    # ============================================
    expression = left:primary (_ op:operator _ right:primary)*;
    primary = val:number | ref:identifier | "(" _ expression _ ")";
    args = (head:expression (_ "," _ tail:expression)*)?;

    # ============================================
    # Terminals and whitespace
    # ============================================
    identifier = [a-zA-Z_][a-zA-Z0-9_]*
    number = [0-9]+
    operator = "==" | "!=" | "<" | ">" | "<=" | ">="
             | "+" | "-" | "*" | "/"
    _ = [ \n\r\t]*;
  ''';

  final parser = grammarString.toSMParser(captureTokensAsMarks: true);

  final input = r'''
fn main() {
  let counter = 1;
  while (counter <= 5) {
    if (counter == 3) {
      print(333);
    } else {
      print(counter);
    }
    counter = counter + 1;
  }
}
''';

  print("PARSING PROGRAM:\n$input");
  final outcome = parser.parse(input);

  if (outcome is ParseSuccess) {
    final result = outcome.result;
    final evaluator = StructuredEvaluator();
    final tree = evaluator.evaluate(result.rawMarks);

    print("\nSTRUCTURED TREE:");
    _printTree(tree, 0);

    print("\nEXECUTING PROGRAM:");
    final interpreter = Interpreter();
    interpreter.execute(tree);
  } else if (outcome is ParseError) {
    print("\nPARSE FAILED: Error at position ${outcome.position}");
    print(
      "Context: ${input.substring(outcome.position, (outcome.position + 20).clamp(0, input.length))}",
    );
  }
}

void _printTree(ParseResult node, int depth) {
  final indent = "  " * depth;
  for (final (label, node) in node.children) {
    final spanSnippet = node.span.replaceAll('\n', '\\n');
    final displaySpan = spanSnippet.length > 40
        ? "${spanSnippet.substring(0, 37)}..."
        : spanSnippet;
    print("${indent}LABEL: $label => '$displaySpan'");
    if (node is ParseResult) {
      _printTree(node, depth + 1);
    }
  }
}
