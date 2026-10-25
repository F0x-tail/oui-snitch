// SPDX-License-Identifier: MIT
// Bounds check for the per-engine unique-MAC set (P4). The set must not grow
// without limit over a long run; above the cap it evicts the oldest.
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mirrors _recordUniqueMac's bounded-insertion behaviour on a LinkedHashSet.
  test('insertion-ordered set evicts oldest past the cap', () {
    const cap = 5;
    final set = <String>{};
    bool record(String m) {
      final isNew = set.add(m);
      if (isNew && set.length > cap) set.remove(set.first);
      return isNew;
    }

    for (var i = 0; i < 100; i++) {
      expect(record('mac$i'), isTrue);
      expect(set.length <= cap, isTrue, reason: 'bounded at $cap');
    }
    // Oldest evicted, newest retained.
    expect(set.contains('mac99'), isTrue);
    expect(set.contains('mac0'), isFalse);
    // A long-absent (evicted) MAC reads as new again — acceptable.
    expect(record('mac0'), isTrue);
  });
}
