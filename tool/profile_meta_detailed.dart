import "package:glush/glush.dart";

const metaGrammarString = r"""
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
        | $call name:ident ('(' _ args:args? _ ')')? ('^' prec:number)?
        | $lit literal
        | $range charRange
        | $any '.'

# Helpers
isContinuation = ident !(_ [=]) !isRuleDeclarationAhead
                | literal | charRange
                | '[' | '(' | '.' | '!' | '&'

isRuleDeclarationAhead = !$ balancedParenthesis? _ "="
balancedParenthesis = "(" balancedParenthesis ")"
                    | !")" .

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
plain_ws() = [ \t]+!
newline = [\n\r]+!
      """;

void main() {
  print("Compiling meta-grammar...");
  var grammar = GrammarFileCompiler(
    GrammarFileParser(metaGrammarString).parse(),
  ).compile(startRuleName: "full");

  print("Creating SMParser...");
  var parser = SMParser(grammar);

  print("\nParsing simple input (warm-up)...");
  GlushProfiler.enabled = true;
  GlushProfiler.reset();
  var result1 = parser.parse("rule = 'a'\n");
  print("Result: ${result1.runtimeType}");
  print(GlushProfiler.snapshot().report());

  print("\n=== Parsing meta-grammar (MAIN BENCHMARK) ===");
  GlushProfiler.enabled = true;
  GlushProfiler.reset();
  var sw = Stopwatch()..start();
  var result2 = parser.parse(metaGrammarString);
  sw.stop();
  print("Parse result: ${result2.runtimeType}");
  print("Time: ${sw.elapsedMilliseconds} ms");
  print(GlushProfiler.snapshot().report());
}
