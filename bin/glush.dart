// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart" show FileTracer;

const grammar = r"""
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
""";

final parser = grammar.toSMParser();

void main() {
  // Default behavior: parse and output
  const input = "sss";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  File("state-machine.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  var paths = state.forest;
  if (!state.accept || paths == null) {
    print("DEBUG: paths is null, returning");
    return;
  }
  print(paths.countDerivations());

  var evaluator = Evaluator<String>({"S.2": (ctx) => "(${ctx()}${ctx()})", "S.1": (ctx) => "s"});

  for (var (i, path) in paths.allMarkPaths().indexed) {
    var tree = path.evaluateStructure();
    var evaluated = evaluator.evaluate(tree);

    print("$i: $evaluated");
  }

  File("another.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(paths.toDot());

  return;
}
