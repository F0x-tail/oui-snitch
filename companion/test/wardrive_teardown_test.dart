// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wardrive_state.dart';

void main() {
  test('a mask resolves to exactly the engines it names', () {
    expect(enginesFromMask(0), isEmpty);
    expect(enginesFromMask(-1), isEmpty, reason: 'unreadable, not "none"');
    expect(enginesFromMask(Engine.detector.bitmask | Engine.wardrive.bitmask),
        {Engine.detector, Engine.wardrive});
  });

  group('stopping a wardrive leaves engines it did not start', () {
    test('the detector survives a wardrive that was layered on top of it', () {
      // Regression: teardown disabled a fixed list of six engines, so turning
      // a wardrive off also turned off a detector the user had running first.
      final preserved = {Engine.detector};
      expect(teardownComplete(Engine.detector.bitmask, preserved), isTrue,
          reason: 'the detector was running before the session and must not '
              'count as a failed teardown');
    });

    test('a wardrive engine still running is a failed teardown', () {
      expect(
        teardownComplete(
            Engine.detector.bitmask | Engine.wardrive.bitmask, {Engine.detector}),
        isFalse,
      );
    });

    test('with nothing preserved, anything left running is a failure', () {
      expect(teardownComplete(0, {}), isTrue);
      expect(teardownComplete(Engine.wardrive.bitmask, {}), isFalse);
    });

    test('an unreadable mask is never success', () {
      expect(teardownComplete(-1, {}), isFalse);
      expect(teardownComplete(-1, {Engine.detector}), isFalse);
    });
  });
}
