// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/gps/gps_types.dart';
import 'package:oui_spy/core/wardrive_state.dart';

GpsPosition _fix({required double accuracy, required DateTime at}) =>
    GpsPosition(
      latitude: 49.26,
      longitude: -123.25,
      altitude: 70,
      speed: 0,
      heading: 0,
      accuracy: accuracy,
      satelliteCount: 9,
      timestamp: at,
    );

void main() {
  final now = DateTime(2026, 10, 25, 12, 0, 0);

  group('a last-known fix may only stand in for a missing one when it is', () {
    test('recent and accurate', () {
      expect(
        fixUsableAsFallback(
            _fix(accuracy: 8, at: now.subtract(const Duration(seconds: 30))), now),
        isTrue,
      );
    });

    test('not stale — minutes are kilometres in a car', () {
      expect(
        fixUsableAsFallback(
            _fix(accuracy: 8, at: now.subtract(const Duration(minutes: 20))), now),
        isFalse,
        reason: 'a 20-minute-old position is fiction, and WiGLE cannot '
            'withdraw a confidently wrong coordinate once uploaded',
      );
    });

    test('not merely poor — 200m accuracy is not a wardrive observation', () {
      expect(
        fixUsableAsFallback(
            _fix(accuracy: 200, at: now.subtract(const Duration(seconds: 5))), now),
        isFalse,
      );
    });

    test('not an unfixed reading, however fresh', () {
      expect(fixUsableAsFallback(_fix(accuracy: 0, at: now), now), isFalse);
    });
  });

  test('the boundary is inclusive, and clock skew does not open a hole', () {
    expect(
      fixUsableAsFallback(_fix(accuracy: 8, at: now.subtract(kStaleFixAfter)), now),
      isTrue,
    );
    expect(
      fixUsableAsFallback(
          _fix(accuracy: 8, at: now.subtract(kStaleFixAfter + const Duration(seconds: 1))),
          now),
      isFalse,
    );
    // A fix stamped in the future means the clock moved, not that the position
    // is fresh; borrowing it would be guessing.
    expect(
      fixUsableAsFallback(
          _fix(accuracy: 8, at: now.add(const Duration(minutes: 5))), now),
      isFalse,
    );
  });
}
