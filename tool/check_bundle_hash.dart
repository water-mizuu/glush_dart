import "dart:convert";
import "dart:io";
import "package:crypto/crypto.dart";

/// Computes SHA256 hash of all source files in lib/src/ directory
/// (excluding the generated runtime_bundle.dart itself)
String computeSrcHash() {
  var srcDir = Directory("lib/src");
  if (!srcDir.existsSync()) {
    throw Exception("lib/src directory not found");
  }

  var files = srcDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith(".dart") && !f.path.endsWith("runtime_bundle.dart"))
      .map((f) => f.path)
      .toList();

  files.sort();

  var buffer = StringBuffer();
  for (var filepath in files) {
    var file = File(filepath);
    var content = file.readAsStringSync();
    buffer.write(content);
  }

  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

/// Gets the stored hash from tool/bundle_hash.txt, or null if file doesn't exist
String? getStoredHash() {
  var hashFile = File("tool/bundle_hash.txt");
  if (!hashFile.existsSync()) {
    return null;
  }
  return hashFile.readAsStringSync().trim();
}

/// Saves the hash to tool/bundle_hash.txt
void saveHash(String hash) {
  var hashFile = File("tool/bundle_hash.txt");
  hashFile.writeAsStringSync("$hash\n");
}

/// Runs the bundle_runtime.dart script
void runBundler() {
  print("lib/src/ has changed. Regenerating runtime bundle...");
  var result = Process.runSync("dart", ["run", "tool/bundle_runtime.dart"]);

  if (result.exitCode != 0) {
    print("ERROR: Failed to run bundler");
    print(result.stderr);
    exit(1);
  }

  print(result.stdout);
}

/// Checks if runtime bundle needs to be regenerated
/// Returns true if regeneration was performed, false otherwise
bool ensureBundleUpToDate() {
  var currentHash = computeSrcHash();
  var storedHash = getStoredHash();

  if (storedHash == currentHash) {
    return false;
  }

  runBundler();
  saveHash(currentHash);
  return true;
}

void main() {
  if (ensureBundleUpToDate()) {
    print("Runtime bundle regenerated and hash updated.");
  } else {
    print("Runtime bundle is up to date.");
  }
}
