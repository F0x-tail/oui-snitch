// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/wardrive_state.dart';

void main() {
  group('canAdoptSession', () {
    test('resumes a session that was running when the link dropped', () {
      expect(
        canAdoptSession(
          offlineScanEnabled: true,
          userStopped: false,
          sessionIntent: true,
        ),
        isTrue,
      );
    });

    test('does not promote a bare engine tile to a wardrive session', () {
      // The reported bug: detector switched on from HOME, walk out of range,
      // walk back. The board reports the detector bit, which is also the bit a
      // session with the detector target would set — so the mask cannot tell
      // these apart and the wardrive tile came on with nothing behind it.
      expect(
        canAdoptSession(
          offlineScanEnabled: true,
          userStopped: false,
          sessionIntent: false,
        ),
        isFalse,
      );
    });

    test('does not resurrect a session the user stopped', () {
      expect(
        canAdoptSession(
          offlineScanEnabled: true,
          userStopped: true,
          sessionIntent: true,
        ),
        isFalse,
      );
    });

    test('without keep-running there is nothing to adopt', () {
      // Whatever is still on the board is stale, not a session in progress.
      expect(
        canAdoptSession(
          offlineScanEnabled: false,
          userStopped: false,
          sessionIntent: true,
        ),
        isFalse,
      );
    });
  });
}
