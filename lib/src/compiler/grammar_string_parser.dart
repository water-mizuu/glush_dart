/// Parses a grammar definition string into an executable Grammar object
library glush.grammar_parser;

import "package:glush/glush.dart" show SMParser;
import "package:glush/src/compiler/compiler.dart";
import "package:glush/src/compiler/format.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/sm_parser.dart" show SMParser;
import "package:glush/src/representation/evaluator.dart";

/// Parses a [input] string containing a Glush grammar definition into a [GrammarFile] AST.
///
/// This function bootstraps the parsing process by using a hardcoded
/// "metagrammar" (a grammar that describes the grammar file format itself).
/// It follows these steps:
/// 1. Compiles the metagrammar string into a state machine.
/// 2. Parses the [input] using the metagrammar state machine to produce a parse forest.
/// 3. Extracts the first valid derivation from the forest.
/// 4. Applies the [createMetagrammarEvaluator] to transform the raw parse tree into
///    a structured [GrammarFile] object.
GrammarFile parseGrammarToFile(String input) {
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
            | $neq  left:argExpr^5 _ '!=' _ right:argExpr^5
          4 | $lt   left:argExpr^5 _ '<'  _ right:argExpr^5
            | $lte  left:argExpr^5 _ '<=' _ right:argExpr^5
            | $gt   left:argExpr^5 _ '>'  _ right:argExpr^5
            | $gte  left:argExpr^5 _ '>=' _ right:argExpr^5

          # Arithmetic Operations
          6 | $add  left:argExpr^6  _ '+' _ right:argExpr^7
            | $sub  left:argExpr^6  _ '-' _ right:argExpr^7
          7 | $mul  left:argExpr^7 _ '*' _ right:argExpr^8
            | $div  left:argExpr^7 _ '/' _ right:argExpr^8
            | $mod  left:argExpr^7 _ '%' _ right:argExpr^8

          # Unary Operations (Prefix)
          10 | $not  '!' _ right:argExpr^10
             | $neg  '-' _ right:argExpr^10
             | $pos  '+' _ right:argExpr^10

          # Atomic Values
          20 | $int  number
             | $str  literal
             | $ident ident
             | $group '(' _ expr:argExpr^0 _ ')'

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

  // Create parser for the metagrammar
  var metaGrammarParser = metaGrammarString.toSMParser();

  // Parse the input grammar definition
  var parseResult = metaGrammarParser.parseAmbiguous(input, captureTokensAsMarks: true);

  if (parseResult case ParseAmbiguousSuccess(:var forest)) {
    // Get the first derivation
    var parseTree = forest.allMarkPaths().first;

    // Create and apply the evaluator to transform parse tree into GrammarFile
    var evaluator = createMetagrammarEvaluator();
    var grammarFileObj = evaluator.evaluate(parseTree.evaluateStructure(input));

    if (grammarFileObj is GrammarFile) {
      return grammarFileObj;
    } else {
      throw StateError("Expected GrammarFile from evaluator, got ${grammarFileObj.runtimeType}");
    }
  } else {
    throw StateError("Failed to parse grammar definition: $parseResult");
  }
}

/// Parses a [input] string containing a Glush grammar definition and compiles it.
///
/// This is the primary entry point for using string-based grammars. It performs
/// the same bootstrapping as [parseGrammarToFile] but then continues to the
/// [GrammarFileCompiler] to produce an executable [Grammar] ready for use with
/// [SMParser].
Grammar parseGrammar(String input) {
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
    ident = [A-Za-z$_] [A-Za-z$_0-9]*
    literal = ['] ([\] . | !['] .)*! [']
            | ["] ([\] . | !["] .)*! ["]
    charRange = '[' (!']' .)*! ']'
    number = [0-9]+

    _ = $ws (plain_ws | comment | newline)*!
    comment = '#' (!newline .)* (newline | eof)
    plain_ws() = [ \t]+!
    newline = [\n\r]+!
    """;

  // Create parser for the metagrammar
  var metaGrammarParser = metaGrammarString.toSMParser();

  // Parse the input grammar definition
  var parseResult = metaGrammarParser.parseAmbiguous(input, captureTokensAsMarks: true);

  if (parseResult case ParseAmbiguousSuccess(:var forest)) {
    // Get the first derivation
    var parseTree = forest.allMarkPaths().first;

    // Create and apply the evaluator to transform parse tree into GrammarFile
    var evaluator = createMetagrammarEvaluator();
    var grammarFileObj = evaluator.evaluate(parseTree.evaluateStructure(input));

    if (grammarFileObj is GrammarFile) {
      // Compile the grammar file into an executable Grammar
      var compiler = GrammarFileCompiler(grammarFileObj);
      return compiler.compile();
    } else {
      throw StateError("Expected GrammarFile from evaluator, got ${grammarFileObj.runtimeType}");
    }
  } else {
    throw StateError("Failed to parse grammar definition: $parseResult");
  }
}
