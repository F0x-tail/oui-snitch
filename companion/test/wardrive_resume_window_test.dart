// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/wardrive_state.dart';

void main() {
  group('resumeWindowExpired', () {
    test('a brief blip is not the end of a session', () {
      expect(resumeWindowExpired(const Duration(seconds: 2)), isFalse);
      expect(resumeWindowExpired(const Duration(minutes: 4, seconds: 59)),
          isFalse);
    });

    test('the window is inclusive at its edge', () {
      expect(resumeWindowExpired(kWardriveResumeWindow), isTrue);
    });

    test('a board that never came back ends the session', () {
      expect(resumeWindowExpired(const Duration(minutes: 30)), isTrue);
    });

    test('a clock that went backwards does not end a live session', () {
      // Timezone or NTP correction between losing the link and checking: a
      // negative age is nonsense, and guessing "expired" would throw away a
      // session that is fine.
      expect(resumeWindowExpired(const Duration(minutes: -10)), isFalse);
    });

    test('the window is caller-overridable without touching the rule', () {
      const short = Duration(seconds: 30);
      expect(resumeWindowExpired(const Duration(seconds: 31), window: short),
          isTrue);
      expect(resumeWindowExpired(const Duration(seconds: 29), window: short),
          isFalse);
    });
  });
}
