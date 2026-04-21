/// Parses a grammar definition string into an executable Grammar object
library glush.grammar_parser;

import "package:glush/glush.dart" show SMParser;
import "package:glush/src/compiler/compiler.dart";
import "package:glush/src/compiler/format.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";
import "package:glush/src/core/grammar.dart";
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
