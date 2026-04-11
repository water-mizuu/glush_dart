import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Multiple Predicates", () {
    test("Multiple distinct normal predicates at the same position", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        var x = Pattern.char("x");

        var predA = And(a);
        var predB = And(b);

        // (&a a x) | (&b b x)
        return Rule("Start", () => (predA >> a >> x) | (predB >> b >> x));
      });

      var parser = SMParser(grammar);
      
      var resultAX = parser.parse("ax");
      expect(resultAX.success(), isNotNull, reason: "ax should match (&a a x)");
      
      var resultBX = parser.parse("bx");
      expect(resultBX.success(), isNotNull, reason: "bx should match (&b b x)");
    });

    test("Overlapping different predicates at the same position", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        
        // At same pos, we check &a and &"ab"
        var ruleA = Rule("A", () => a);
        var ruleAB = Rule("AB", () => a >> b);
        
        // Both &ruleA and &ruleAB are evaluated at pos 0.
        return Rule("Start", () => And(ruleA.call()) >> And(ruleAB.call()) >> a >> b);
      });
      
      var parser = SMParser(grammar);
      var result = parser.parse("ab");
      expect(result.success(), isNotNull);
    });

    test("Nested predicates", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        
        // &(a &b) a b
        var inner = Rule("Inner", () => a >> And(b));
        return Rule("Start", () => And(inner.call()) >> a >> b);
      });
      
      var parser = SMParser(grammar);
      var result = parser.parse("ab");
      expect(result.success(), isNotNull);
    });

    group("Parameter Predicates", () {
      test("Two different parameter predicates at the same position (Collision Test)", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          
          // These use IfCond which get unique synthetic rules
          var pred1 = Rule("P1", () => a).guardedBy(GuardExpr.literal(true));
          var pred2 = Rule("P2", () => a).guardedBy(GuardExpr.literal(false));
          
          return Rule("Start", () => pred1.call() | pred2.call());
        });
        
        var parser = SMParser(grammar);
        var result = parser.parse("a");
        
        expect(result.success(), isNotNull, reason: "P1 is true, so it should match");
      });

      test("Parameter Ref Predicates (&param) collision test", () {
        // This targets the code path with symbol -1 in _spawnParameterPredicateSubparse
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          
          // Rule that takes a pattern parameter and uses it as a NOT predicate
          var checker = Rule("Checker", () => 
            (Not(ParameterRefPattern("p")) >> Pattern.char("a")) | 
            (Not(ParameterRefPattern("q")) >> Pattern.char("a"))
          );
          
          // p matches 'a', q matches 'b'.
          // Input is 'a'.
          // !p should FAIL (because p matches 'a')
          // !q should SUCCEED (because q does NOT match 'a')
          // If they share a tracker, !q might FAIL because !p marked the '-1' tracker as matched.
          return Rule("Start", () => 
            checker.call(arguments: {"p": CallArgumentValue.pattern(a), "q": CallArgumentValue.pattern(b)})
          );
        });
        
        var parser = SMParser(grammar);
        
        // Input 'a'. 
        // Expected: Matches via the second branch (!q).
        var result = parser.parse("a");
        expect(result.success(), isNotNull, reason: "!q should succeed since q='b' and input='a'");
      });

      test("Multiple parallel parameter predicates with different expressions", () {
         var grammar = Grammar(() {
          var a = Pattern.char("a");
          // Use complex expressions that might collide if symbols are shared
          var predA = Rule("IsA", () => a).guardedBy(GuardExpr.expression(CallArgumentValue.binary(
            CallArgumentValue.literal(1), 
            ExpressionBinaryOperator.equals, 
            CallArgumentValue.literal(1)
          )));
          var predB = Rule("IsB", () => a).guardedBy(GuardExpr.expression(CallArgumentValue.binary(
            CallArgumentValue.literal(1), 
            ExpressionBinaryOperator.equals, 
            CallArgumentValue.literal(2)
          )));
          
          return Rule("Start", () => (predA.call() >> Pattern.char("1")) | (predB.call() >> Pattern.char("2")));
        });
        
        var parser = SMParser(grammar);
        expect(parser.parse("a1").success(), isNotNull);
        expect(parser.parse("a2").success(), isNull, reason: "predB should fail");
      });
      test("Boolean Parameter Predicate collision test (-1 symbol collision)", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          
          // These use ParameterPredicateAction with symbol -1
          // &{true} a | &{false} a
          var checker = Rule("Checker", () => 
            (And(ParameterRefPattern("p")) >> a) | 
            (And(ParameterRefPattern("q")) >> a)
          );
          
          // p is true, q is false.
          return Rule("Start", () => 
            checker.call(arguments: {"p": CallArgumentValue.literal(true), "q": CallArgumentValue.literal(false)})
          );
        });
        
        var parser = SMParser(grammar);
        
        // If they share tracker (-1, 0), !q might incorrectly succeed because &p matched?
        // Wait, &p and &q are both AND. Both use -1.
        // If &p runs first, tracker(-1, 0) matched = true.
        // Then &q runs, sees matched=true, and incorrectly SUCCEEDS even though q is false!
        
        var result = parser.parseAmbiguous("a");
        expect(result, isA<ParseAmbiguousSuccess>());
        var success = result as ParseAmbiguousSuccess;
        
        // Should only have 1 path (via p). 
        // If it has 2 paths, then q incorrectly matched.
        expect(success.forest.allMarkPaths().length, equals(1), reason: "q is false, so only one path should succeed");
      });

      test("Mixed AND/NOT collision on the same rule", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var ruleA = Rule("A", () => a);
          
          // (&A a) | (!A a)
          // Both use ruleA's symbolId.
          return Rule("Start", () => (And(ruleA.call()) >> a) | (Not(ruleA.call()) >> a));
        });
        
        var parser = SMParser(grammar);
        // This MUST crash if it's a bug
        parser.parse("a");
      });
    });
  });
}
