import "package:glush/glush.dart";
import "package:test/test.dart";

// Import all test files
import "../test/core/backslash_literal_test.dart" as backslash_literal_test;
import "../test/core/glush_list_test.dart" as glush_list_test;
import "../test/core/glush_test.dart" as glush_test;
import "../test/core/stress_test.dart" as stress_test;
import "../test/diagnostic/execution_trace_test.dart" as execution_trace_test;
import "../test/export_import_test.dart" as export_import_test;
import "../test/features/ambiguous_marks_test.dart" as ambiguous_marks_test;
import "../test/features/associativity_test.dart" as associativity_test;
import "../test/features/debug_predicate_test.dart" as debug_predicate_test;
import "../test/features/grammarfile_precedence_test.dart" as grammarfile_precedence_test;
import "../test/features/greedy_star_plus_test.dart" as greedy_star_plus_test;
import "../test/features/marks_regression_test.dart" as marks_regression_test;
import "../test/features/marks_test.dart" as marks_test;
import "../test/features/optional_unambiguous_test.dart" as optional_unambiguous_test;
import "../test/features/precedence_test.dart" as precedence_test;
import "../test/features/pred_amb_test.dart" as pred_amb_test;
import "../test/features/predicate_nesting_test.dart" as predicate_nesting_test;
import "../test/features/predicates_test.dart" as predicates_test;
import "../test/features/recursive_test.dart" as recursive_test;
import "../test/features/scc_counting_test.dart" as scc_counting_test;
import "../test/features/sm_features_test.dart" as sm_features_test;
import "../test/features/star_plus_unambiguous_test.dart" as star_plus_unambiguous_test;
import "../test/features/tail_call_optimization_test.dart" as tail_call_optimization_test;
import "../test/parser/cache_determinism_test.dart" as cache_determinism_test;
import "../test/parser/consistency_test.dart" as consistency_test;
import "../test/parser/debug_not_sequence_test.dart" as debug_not_sequence_test;
import "../test/parser/edge_cases_test.dart" as edge_cases_test;
import "../test/parser/epsilon_cycle_test.dart" as epsilon_cycle_test;
import "../test/parser/gamma_three_test.dart" as gamma_three_test;
import "../test/parser/predicate_ambiguity_test.dart" as predicate_ambiguity_test;
import "../test/parser/predicate_regression_test.dart" as predicate_regression_test;
import "../test/parser/shared_predicate_test.dart" as shared_predicate_test;
import "../test/parser/sm_integration_test.dart" as sm_integration_test;
import "../test/parser/state_machine_dot_escape_test.dart" as state_machine_dot_escape_test;
import "../test/regression/cyclic_unary_ambiguity_test.dart" as cyclic_unary_ambiguity_test;
import "../test/regression/gamma_bug_test.dart" as gamma_bug_test;
import "../test/regression/meta_grammar_test.dart" as meta_grammar_test;
import "../test/retreat_test.dart" as retreat_test;

void main() {
  GlushProfiler.enabled = true;

  group("Profiling runner", () {
    // Run all test main functions
    ambiguous_marks_test.main();
    associativity_test.main();
    backslash_literal_test.main();
    cache_determinism_test.main();
    consistency_test.main();
    cyclic_unary_ambiguity_test.main();
    debug_not_sequence_test.main();
    debug_predicate_test.main();
    edge_cases_test.main();
    epsilon_cycle_test.main();
    execution_trace_test.main();
    export_import_test.main();
    gamma_bug_test.main();
    gamma_three_test.main();
    glush_list_test.main();
    glush_test.main();
    grammarfile_precedence_test.main();
    greedy_star_plus_test.main();
    marks_regression_test.main();
    marks_test.main();
    meta_grammar_test.main();
    optional_unambiguous_test.main();
    precedence_test.main();
    pred_amb_test.main();
    predicate_ambiguity_test.main();
    predicate_nesting_test.main();
    predicate_regression_test.main();
    predicates_test.main();
    recursive_test.main();
    retreat_test.main();
    scc_counting_test.main();
    shared_predicate_test.main();
    sm_features_test.main();
    sm_integration_test.main();
    star_plus_unambiguous_test.main();
    state_machine_dot_escape_test.main();
    stress_test.main();
    tail_call_optimization_test.main();

    // Set up a tearDown to print the profiling summary after all tests
    tearDownAll(() {
      print("\n\n========== PROFILING SUMMARY ==========");
      print(GlushProfiler.snapshot().report());
    });
  });
}
