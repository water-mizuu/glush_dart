import "dart:io";

const template = r"""
import "package:glush/glush.dart";
import "package:test/test.dart";

// Import all test files
:test_imports

void main() {
  GlushProfiler.enabled = true;

  group("Profiling runner", () {
    // Run all test main functions
:test_runs

    // Set up a tearDown to print the profiling summary after all tests
    tearDownAll(() {
      print("\n\n========== PROFILING SUMMARY ==========");
      print(GlushProfiler.snapshot().report());
    });
  });
}
""";

void main() {
  var parent = Directory("test");
  var files = parent
      .listSync(recursive: true)
      .where((v) => v is File && v.path.endsWith("test.dart"))
      .toList();

  var imports = <String>[];
  var runs = <String>[];

  for (var file in files) {
    var normalized = file.path.replaceAll(Platform.pathSeparator, "/");
    var prepended = "../$normalized";

    var fileName = normalized.split("/").last;
    var fileNameWithoutExtension = fileName.substring(0, fileName.length - 5);

    imports.add('import "$prepended" as $fileNameWithoutExtension;');
    runs.add("    $fileNameWithoutExtension.main();");
  }

  imports.sort((a, b) => a.compareTo(b));
  runs.sort((a, b) => a.compareTo(b));

  var filled = template
      .replaceAll(":test_imports", imports.join("\n"))
      .replaceAll(":test_runs", runs.join("\n"));

  File("tool/profile_toolkit.dart")
    ..createSync(recursive: true)
    ..writeAsStringSync(filled);
}
