import "package:glush/glush.dart";

void main() {
  print("--- Glush Data-Driven Parser Examples ---\n");

  _runExample("Dynamic Delimiters", _exampleDynamicDelimiters);
  _runExample("XML-Like Mark Bridge", _exampleXmlLikeMarkBridge);
  _runExample("Nested XML Forest", _exampleNestedXmlForest);
  _runExample("Guarded Variants", _exampleGuardedVariants);
  _runExample("Rule Object Pass-Through", _exampleRuleObjectPassThrough);
  _runExample("Rule Call Pattern Pass-Through", _exampleRuleCallPatternPassThrough);
  _runExample("Structured Higher-Order Grammar", _exampleStructuredHigherOrderGrammar);
  _runExample("Recursive Parameter Chain", _exampleRecursiveParameterChain);
  _runExample("Pattern Closure Pass-Through", _examplePatternClosurePassThrough);
  _runExample("Ambiguous Data-Driven Choice", _exampleAmbiguousDataDrivenChoice);
  _runExample("Framed Payload Dispatch", _exampleFramedPayloadDispatch);
  _runExample("Configurable Record Catalog", _exampleConfigurableRecordCatalog);
}

void _runExample(String name, void Function() example) {
  try {
    print("Running $name...");
    example();
    print("Completed $name.\n");
  } on Exception catch (e, stack) {
    print("Error in $name:");
    print(e);
    print(stack);
    print("\n");
  }
}

/// Example 1:
/// A single rule body can be reused with different string parameters.
/// The delimiter strings are treated as parser material, while the middle
/// piece is a parser rule.
void _exampleDynamicDelimiters() {
  print("Example 1: Dynamic Delimiters");
  print("Goal: Reuse one rule for different open/body/close pieces.");

  const grammarText = r"""
    start = array | block
    array = bracketed(open: "ab", body: 'x', close: "cd")
    block = bracketed(open: "xy", body: 'x', close: "zz")

    bracketed(open, body, close) = open body close
    chunk = 'x'
  """;

  var parser = grammarText.toSMParser();

  print('Input "abxcd": ${parser.recognize("abxcd") ? "MATCH" : "FAIL"}');
  print('Input "xyxzz": ${parser.recognize("xyxzz") ? "MATCH" : "FAIL"}');
  print('Input "abxzz": ${parser.recognize("abxzz") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Input "abyd":  ${parser.recognize("abyd") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 2:
/// This is the XML-like shape the data-driven mark bridge was added for.
/// The opening tag name is captured as `tag` and then validated again when the
/// closing tag is parsed.
void _exampleXmlLikeMarkBridge() {
  print("Example 2: XML-Like Mark Bridge");
  print("Goal: Capture the opening tag name and require the same closing tag.");

  const grammarText = r"""
    start = element
    element =
          openTag body closeTag(tag)

    openTag =
          '<' tag:name '>'

    closeTag(tag) =
          '</' close:name '>' verify(tag, close)

    verify(open, close) = if (open == close) ''

    body =
          text

    text =
          [A-Za-z ]+

    name = [A-Za-z_] [A-Za-z0-9_]*
  """;

  var parser = grammarText.toSMParser();

  print(
    'Input "<book>Hello</book>":       ${parser.recognize("<book>Hello</book>") ? "MATCH" : "FAIL"}',
  );
  print("This shape is also covered by test/features/xml_mark_bridge_test.dart.");
  print("");
}

/// Example 3:
/// The ambiguous XML-style grammar is safe to run with `parseAmbiguous(...)`.
void _exampleNestedXmlForest() {
  print("Example 3: Nested XML Forest");
  print("Goal: Show that the ambiguous nested XML shape stays tractable.");

  const grammarText = r"""
    start = document
    document = element+

    element =
          openTag content closeTag(tag)

    openTag =
          '<' tag:name '>'

    closeTag(tag) =
          '</' close:name '>' verify(tag, close)

    verify(open, close) = if (open == close) ''

    content =
          (element | text)*

    text =
          [A-Za-z ]+

    name = [A-Za-z_] [A-Za-z0-9_]*
  """;

  var parser = grammarText.toSMParser();
  var result = parser.parseAmbiguous("<book>Hello<author>Ada</author></book>");

  print("parseAmbiguous(...) returned: ${result.runtimeType}");
  print("");
}

/// Example 4:
/// A parameter can drive guard behavior. This is the current "if (...)" data
/// driven path, and it stays inside the parser state machine.
void _exampleGuardedVariants() {
  print("Example 4: Guarded Variants");
  print("Goal: Switch the rule body with a boolean guard.");

  const grammarText = r"""
    start = probe(mode: "enabled") | probe(mode: "disabled")
    probe(mode) =
          if (mode == "enabled") "on"
        | if (mode == "disabled") "off"
  """;

  var parser = grammarText.toSMParser();

  late Rule start;
  late Rule enabledProbe;
  late Rule disabledProbe;

  enabledProbe = Rule("enabledProbe", () => Pattern.string("on"));
  enabledProbe.guard = GuardValue.argument("mode").eq("enabled");

  disabledProbe = Rule("disabledProbe", () => Pattern.string("off"));
  disabledProbe.guard = GuardValue.argument("mode").eq("disabled");

  start = Rule(
    "start",
    () =>
        enabledProbe(arguments: {"mode": CallArgumentValue.literal("enabled")}) |
        disabledProbe(arguments: {"mode": CallArgumentValue.literal("disabled")}),
  );

  var fluentParser = SMParser(Grammar(() => start));

  print('Input "on":  ${parser.recognize("on") ? "MATCH" : "FAIL"}');
  print('Input "off": ${parser.recognize("off") ? "MATCH" : "FAIL"}');
  print('Fluent "on":  ${fluentParser.recognize("on") ? "MATCH" : "FAIL"}');
  print('Fluent "off": ${fluentParser.recognize("off") ? "MATCH" : "FAIL"}');
  print('Input "no":  ${parser.recognize("no") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 5:
/// Parser objects can pass through as parameters too. This one uses the Dart
/// API directly so the rule object is explicit.
void _exampleRuleObjectPassThrough() {
  print("Example 5: Rule Object Pass-Through");
  print("Goal: Pass a rule object as a parameter and call it twice.");

  const dslGrammarText = r"""
    start = wrapper(rule: letter) letter

    wrapper(rule) = rule rule
    letter = 'a'
  """;
  var dslParser = dslGrammarText.toSMParser();

  late Rule start;
  late Rule wrapper;
  late Rule letter;

  // This rule consumes the passed-in parser object twice, proving that the
  // call-site can carry a rule rather than flattening everything to strings.
  letter = Rule("letter", () => Token(const ExactToken(97)));
  wrapper = Rule("wrapper", () => ParameterRefPattern("rule") >> ParameterRefPattern("rule"));
  start = Rule(
    "start",
    () => wrapper(arguments: {"rule": CallArgumentValue.rule(letter)}) >> letter,
  );

  var parser = SMParser(Grammar(() => start));

  print('DSL "aaa": ${dslParser.recognize("aaa") ? "MATCH" : "FAIL"}');
  print('Input "aaa": ${parser.recognize("aaa") ? "MATCH" : "FAIL"}');
  print('DSL "aa":  ${dslParser.recognize("aa") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Input "aa":  ${parser.recognize("aa") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 6:
/// RuleCall objects can also travel through the data-driven path as pattern
/// parameters, then resolve back into parser behavior at runtime.
void _exampleRuleCallPatternPassThrough() {
  print("Example 6: Rule Call Pattern Pass-Through");
  print("Goal: Pass a RuleCall as a pattern parameter and reuse it inside another rule.");

  const dslGrammarText = r"""
    start = wrapper(content: pair(piece: atom)) atom

    wrapper(content) = '[' content ']'
    pair(piece) = piece piece
    atom = 'a' | 'b' | 'c'
  """;
  var dslParser = dslGrammarText.toSMParser();

  late Rule start;
  late Rule wrapper;
  late Rule pair;
  late Rule atom;

  atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));

  pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));

  wrapper = Rule(
    "wrapper",
    () => Pattern.char("[") >> ParameterRefPattern("content") >> Pattern.char("]"),
  );

  start = Rule(
    "start",
    () =>
        wrapper(
          arguments: {
            "content": CallArgumentValue.pattern(
              pair(arguments: {"piece": CallArgumentValue.pattern(atom())}),
            ),
          },
        ) >>
        atom(),
  );

  var parser = SMParser(Grammar(() => start));

  print('DSL "[aa]a": ${dslParser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('Input "[aa]a": ${parser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('DSL "[bb]b": ${dslParser.recognize("[bb]b") ? "MATCH" : "FAIL"}');
  print('Input "[bb]b": ${parser.recognize("[bb]b") ? "MATCH" : "FAIL"}');
  print('DSL "[ad]a": ${dslParser.recognize("[ad]a") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Input "[ad]a": ${parser.recognize("[ad]a") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 7:
/// A more realistic higher-order grammar can reuse the same wrapper rules with
/// different nested rule calls and structured call arguments.
void _exampleStructuredHigherOrderGrammar() {
  print("Example 7: Structured Higher-Order Grammar");
  print("Goal: Show the same higher-order grammar in DSL and fluent forms.");

  const dslGrammarText = r"""
    start = guarded(content: wrapper, policy: "strict")
    looseStart = guarded(content: wrapper, policy: "lenient")

    guarded(content, policy) = if (policy == "strict") content atom
                             | if (policy == "lenient") content
    wrapper = '[' pair(piece: atom) ']'
    pair(piece) = piece piece
    atom = 'a' | 'b' | 'c'
  """;
  var strictDslParser = dslGrammarText.toSMParser(startRuleName: "start");
  var looseDslParser = dslGrammarText.toSMParser(startRuleName: "looseStart");

  late Rule start;
  late Rule looseStart;
  late Rule strictGuarded;
  late Rule lenientGuarded;
  late Rule wrapper;
  late Rule pair;
  late Rule atom;

  atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));

  pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));

  wrapper = Rule(
    "wrapper",
    () =>
        Pattern.char("[") >>
        pair(arguments: {"piece": CallArgumentValue.rule(atom)}) >>
        Pattern.char("]"),
  );

  strictGuarded = Rule("guardedStrict", () => ParameterRefPattern("content") >> atom());
  strictGuarded.guard = GuardValue.argument("policy").eq("strict");

  lenientGuarded = Rule("guardedLenient", () => ParameterRefPattern("content"));
  lenientGuarded.guard = GuardValue.argument("policy").eq("lenient");

  start = Rule(
    "start",
    () => strictGuarded(
      arguments: {
        "content": CallArgumentValue.rule(wrapper),
        "policy": CallArgumentValue.literal("strict"),
      },
    ),
  );

  looseStart = Rule(
    "looseStart",
    () => lenientGuarded(
      arguments: {
        "content": CallArgumentValue.rule(wrapper),
        "policy": CallArgumentValue.literal("lenient"),
      },
    ),
  );

  var strictParser = SMParser(Grammar(() => start));
  var looseParser = SMParser(Grammar(() => looseStart));

  print('DSL strict on "[aa]a": ${strictDslParser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('DSL loose on "[aa]":  ${looseDslParser.recognize("[aa]") ? "MATCH" : "FAIL"}');
  print('Strict policy on "[aa]a": ${strictParser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('Loose policy on "[aa]":  ${looseParser.recognize("[aa]") ? "MATCH" : "FAIL"}');
  print(
    'DSL strict on "[ad]a": ${strictDslParser.recognize("[ad]a") ? "MATCH" : "FAIL"} (Expected FAIL)',
  );
  print("");
}

/// Example 8:
/// A parameter can call another parameterized rule, which can then call yet
/// another rule. This shows a small recursive chain in both DSL and fluent
/// forms.
void _exampleRecursiveParameterChain() {
  print("Example 8: Recursive Parameter Chain");
  print("Goal: Show a parameter invoking a parameterized rule, then another.");

  const dslGrammarText = r"""
    start = outer(handler: middle, item: atom)

    outer(handler, item) = handler(piece: item) item
    middle(piece) = inner(value: piece)
    inner(value) = '[' value value ']'

    atom = 'a' | 'b' | 'c'
  """;
  var dslParser = dslGrammarText.toSMParser();

  late Rule start;
  late Rule outer;
  late Rule middle;
  late Rule inner;
  late Rule atom;

  atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));

  inner = Rule(
    "inner",
    () =>
        Pattern.char("[") >>
        ParameterRefPattern("value") >>
        ParameterRefPattern("value") >>
        Pattern.char("]"),
  );

  middle = Rule("middle", () => inner(arguments: {"value": CallArgumentValue.reference("piece")}));

  outer = Rule(
    "outer",
    () =>
        ParameterCallPattern(
          "handler",
          arguments: {"piece": CallArgumentValue.reference("item")},
        ) >>
        ParameterRefPattern("item"),
  );

  start = Rule(
    "start",
    () => outer(
      arguments: {"handler": CallArgumentValue.rule(middle), "item": CallArgumentValue.rule(atom)},
    ),
  );

  var fluentParser = SMParser(Grammar(() => start));

  print('DSL on "[aa]a": ${dslParser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('Fluent on "[aa]a": ${fluentParser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('DSL on "[aa]": ${dslParser.recognize("[aa]") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Fluent on "[ad]a": ${fluentParser.recognize("[ad]a") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 9:
/// A complex pattern value can capture parameters from the surrounding scope,
/// then be passed into a wrapper and invoked later like a real higher-order
/// parser value.
void _examplePatternClosurePassThrough() {
  print("Example 9: Pattern Closure Pass-Through");
  print("Goal: Pass a pattern value that closes over outer parameters.");

  const dslGrammarText = r"""
    start = outer(piece: atom)

    outer(piece) = frame(content: pair(piece: piece)) piece
    frame(content) = '[' content ']'
    pair(piece) = piece piece

    atom = 'a' | 'b'
  """;
  var dslParser = dslGrammarText.toSMParser();

  late Rule start;
  late Rule outer;
  late Rule frame;
  late Rule atom;

  atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b"));

  frame = Rule(
    "frame",
    () => Pattern.char("[") >> ParameterRefPattern("content") >> Pattern.char("]"),
  );

  outer = Rule(
    "outer",
    () =>
        frame(
          arguments: {
            "content": CallArgumentValue.pattern(
              ParameterRefPattern("piece") >> ParameterRefPattern("piece"),
            ),
          },
        ) >>
        ParameterRefPattern("piece"),
  );

  start = Rule("start", () => outer(arguments: {"piece": CallArgumentValue.rule(atom)}));

  var parser = SMParser(Grammar(() => start));

  print('DSL "[aa]a": ${dslParser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('Input "[aa]a": ${parser.recognize("[aa]a") ? "MATCH" : "FAIL"}');
  print('DSL "[bb]b": ${dslParser.recognize("[bb]b") ? "MATCH" : "FAIL"}');
  print('Input "[bb]b": ${parser.recognize("[bb]b") ? "MATCH" : "FAIL"}');
  print('DSL "[ac]a": ${dslParser.recognize("[ac]a") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Input "[ac]a": ${parser.recognize("[ac]a") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 10:
/// Ambiguity driven by a data-passed rule choice.
///
/// This keeps the grammar data-driven while still producing two valid parse
/// paths for the same input. The ambiguity comes from choosing between two
/// rule arguments that both match the same text but attach different marks.
void _exampleAmbiguousDataDrivenChoice() {
  print("Example 10: Ambiguous Data-Driven Choice");
  print("Goal: Pass a rule as data and keep both branches ambiguous.");

  const grammarText = r"""
    start = leftStart | rightStart
    leftStart = branch(choice: left)
    rightStart = branch(choice: right)

    branch(choice) = choice
    left = leftMark:'a'
    right = rightMark:'a'
  """;

  var dslParser = grammarText.toSMParser();
  var dslOutcome = dslParser.parseAmbiguous("a", captureTokensAsMarks: true);
  print("DSL ambiguous outcome: ${dslOutcome.runtimeType}");
  if (dslOutcome case ParseAmbiguousSuccess(:var forest)) {
    print("DSL paths: ${forest.allPaths().length}");
    for (var tree in forest.allPaths().map((p) => const StructuredEvaluator().evaluate(p))) {
      print(tree);
    }
  }

  late Rule start;
  late Rule leftStart;
  late Rule rightStart;
  late Rule branch;
  late Rule left;
  late Rule right;

  left = Rule("left", () => Label("leftMark", Pattern.char("a")));
  right = Rule("right", () => Label("rightMark", Pattern.char("a")));
  branch = Rule("branch", () => ParameterRefPattern("choice"));
  leftStart = Rule("leftStart", () => branch(arguments: {"choice": CallArgumentValue.rule(left)}));
  rightStart = Rule(
    "rightStart",
    () => branch(arguments: {"choice": CallArgumentValue.rule(right)}),
  );
  start = Rule("start", () => leftStart() | rightStart());

  var fluentParser = SMParser(Grammar(() => start), captureTokensAsMarks: true);
  var fluentOutcome = fluentParser.parseAmbiguous("a", captureTokensAsMarks: true);
  print("Fluent ambiguous outcome: ${fluentOutcome.runtimeType}");
  if (fluentOutcome case ParseAmbiguousSuccess(:var forest)) {
    print("Fluent paths: ${forest.allPaths().length}");
    for (var tree in forest.allPaths().map((p) => const StructuredEvaluator().evaluate(p))) {
      print(tree);
    }
  }

  print("");
}

/// Example 11:
/// A rule call can be passed as a pattern parameter and invoked again by the
/// callee, which lets the outer rule describe the framing while the inner rule
/// describes the payload shape.
void _exampleFramedPayloadDispatch() {
  print("Example 11: Framed Payload Dispatch");
  print("Goal: Pass a nested rule call as a pattern and call it again later.");

  const dslGrammarText = r"""
    start = v1 | v2

    v1 =
          render(
            schema: framed(prefix: "<", suffix: ">"),
            payload: pair(piece: atom),
            trailer: bang
          )

    v2 =
          render(
            schema: framed(prefix: "{", suffix: "}"),
            payload: triplet(piece: atom),
            trailer: dot
          )

    render(schema, payload, trailer) = schema(body: payload) trailer
    framed(prefix, suffix, body) = prefix body suffix
    pair(piece) = piece piece
    triplet(piece) = piece piece piece
    bang = '!'
    dot = '.'
    atom = 'a' | 'b' | 'c'
  """;
  var dslParser = dslGrammarText.toSMParser();

  late Rule start;
  late Rule v1;
  late Rule v2;
  late Rule render;
  late Rule framed;
  late Rule pair;
  late Rule triplet;
  late Rule bang;
  late Rule dot;
  late Rule atom;

  atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));
  bang = Rule("bang", () => Pattern.char("!"));
  dot = Rule("dot", () => Pattern.char("."));

  pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));
  triplet = Rule(
    "triplet",
    () =>
        ParameterRefPattern("piece") >>
        ParameterRefPattern("piece") >>
        ParameterRefPattern("piece"),
  );

  framed = Rule(
    "framed",
    () =>
        ParameterRefPattern("prefix") >>
        ParameterRefPattern("body") >>
        ParameterRefPattern("suffix"),
  );

  render = Rule(
    "render",
    () =>
        ParameterCallPattern(
          "schema",
          arguments: {"body": CallArgumentValue.reference("payload")},
        ) >>
        ParameterRefPattern("trailer"),
  );

  v1 = Rule(
    "v1",
    () => render(
      arguments: {
        "schema": CallArgumentValue.pattern(
          framed(
            arguments: {
              "prefix": CallArgumentValue.literal("<"),
              "suffix": CallArgumentValue.literal(">"),
            },
          ),
        ),
        "payload": CallArgumentValue.pattern(
          pair(arguments: {"piece": CallArgumentValue.rule(atom)}),
        ),
        "trailer": CallArgumentValue.rule(bang),
      },
    ),
  );

  v2 = Rule(
    "v2",
    () => render(
      arguments: {
        "schema": CallArgumentValue.pattern(
          framed(
            arguments: {
              "prefix": CallArgumentValue.literal("{"),
              "suffix": CallArgumentValue.literal("}"),
            },
          ),
        ),
        "payload": CallArgumentValue.pattern(
          triplet(arguments: {"piece": CallArgumentValue.rule(atom)}),
        ),
        "trailer": CallArgumentValue.rule(dot),
      },
    ),
  );

  start = Rule("start", () => v1() | v2());

  var fluentParser = SMParser(Grammar(() => start));

  print('DSL "<aa>!":   ${dslParser.recognize("<aa>!") ? "MATCH" : "FAIL"}');
  print('Fluent "<aa>!": ${fluentParser.recognize("<aa>!") ? "MATCH" : "FAIL"}');
  print('DSL "{bbb}.":   ${dslParser.recognize("{bbb}.") ? "MATCH" : "FAIL"}');
  print('Fluent "{bbb}.": ${fluentParser.recognize("{bbb}.") ? "MATCH" : "FAIL"}');
  print('DSL "<a>!":    ${dslParser.recognize("<a>!") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Fluent "{bb}!": ${fluentParser.recognize("{bb}!") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}

/// Example 12:
/// A compact catalog-style example shows the same technique driving two
/// different record layouts from direct higher-order branches.
void _exampleConfigurableRecordCatalog() {
  print("Example 12: Configurable Record Catalog");
  print("Goal: Swap between record layouts with one nested payload rule call.");

  const dslGrammarText = r"""
    start = compact | verbose

    compact = short(prefix: "<", suffix: ">", body: atom)
    verbose = long(prefix: "{", suffix: "}", body: pair(piece: atom))

    short(prefix, suffix, body) = prefix body suffix
    long(prefix, suffix, body) = prefix body suffix
    pair(piece) = piece piece
    atom = 'x' | 'y'
  """;
  var dslParser = dslGrammarText.toSMParser();

  late Rule start;
  late Rule compact;
  late Rule verbose;
  late Rule short;
  late Rule long;
  late Rule pair;
  late Rule atom;

  atom = Rule("atom", () => Pattern.char("x") | Pattern.char("y"));
  pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));
  short = Rule(
    "short",
    () =>
        ParameterRefPattern("prefix") >>
        ParameterRefPattern("body") >>
        ParameterRefPattern("suffix"),
  );
  long = Rule(
    "long",
    () =>
        ParameterRefPattern("prefix") >>
        ParameterRefPattern("body") >>
        ParameterRefPattern("suffix"),
  );
  compact = Rule(
    "compact",
    () => short(
      arguments: {
        "prefix": CallArgumentValue.literal("<"),
        "suffix": CallArgumentValue.literal(">"),
        "body": CallArgumentValue.rule(atom),
      },
    ),
  );
  verbose = Rule(
    "verbose",
    () => long(
      arguments: {
        "prefix": CallArgumentValue.literal("{"),
        "suffix": CallArgumentValue.literal("}"),
        "body": CallArgumentValue.pattern(pair(arguments: {"piece": CallArgumentValue.rule(atom)})),
      },
    ),
  );

  start = Rule("start", () => compact() | verbose());

  var parser = SMParser(Grammar(() => start));

  print('DSL "<x>":   ${dslParser.recognize("<x>") ? "MATCH" : "FAIL"}');
  print('Fluent "<x>": ${parser.recognize("<x>") ? "MATCH" : "FAIL"}');
  print('DSL "{yy}":   ${dslParser.recognize("{yy}") ? "MATCH" : "FAIL"}');
  print('Fluent "{yy}": ${parser.recognize("{yy}") ? "MATCH" : "FAIL"}');
  print('DSL "{y}":    ${dslParser.recognize("{y}") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print('Fluent "<z>":  ${parser.recognize("<z>") ? "MATCH" : "FAIL"} (Expected FAIL)');
  print("");
}
