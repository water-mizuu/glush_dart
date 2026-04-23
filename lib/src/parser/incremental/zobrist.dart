import "dart:math" show Random;

import "package:meta/meta.dart";

/// Identifies a unique parser configuration at a given point in time.
/// Used by the ZobristHasher to assign a random bitstring to this configuration.
@immutable
class FrameSignature {
  const FrameSignature(this.stateId, this.callerTopologicalHash);
  final int stateId;
  final int callerTopologicalHash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FrameSignature &&
          stateId == other.stateId &&
          callerTopologicalHash == other.callerTopologicalHash;

  @override
  int get hashCode => stateId.hashCode ^ callerTopologicalHash.hashCode;
}

/// A rolling hasher that represents an unordered set of parser frames
/// as a single 64-bit integer using Zobrist hashing (XOR sums).
class ZobristHasher {
  static final Map<FrameSignature, int> _randomHashes = {};
  static final Random _random = Random();

  int currentHash = 0;

  /// Incorporates a frame into the running hash (or removes it, since XOR is its own inverse).
  void toggleFrame(FrameSignature sig) {
    var randomVal = _randomHashes.putIfAbsent(sig, () => _generateRandom64BitInt());
    currentHash ^= randomVal;
  }

  /// Replaces the current hash with a new one.
  void setHash(int newHash) {
    currentHash = newHash;
  }

  /// Clears the hash back to 0.
  void clear() {
    currentHash = 0;
  }

  static int _generateRandom64BitInt() {
    // Dart integers are 64-bit on native, 53-bit on JS.
    // We use 52 bits to be safe across both targets.
    var high = _random.nextInt(1 << 26);
    var low = _random.nextInt(1 << 26);
    return (high << 26) | low;
  }
}
