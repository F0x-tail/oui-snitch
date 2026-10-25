// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';

void main() {
  group('boot epoch decides re-assert vs adopt', () {
    test('a changed epoch means the board restarted', () {
      expect(boardRestartedFrom('B2C3D4E5', 'A1B2C3D4'), isTrue);
    });

    test('the same epoch means the link merely blipped', () {
      expect(boardRestartedFrom('A1B2C3D4', 'A1B2C3D4'), isFalse);
    });

    test('the first connection of a session has nothing to adopt', () {
      // No previously-seen epoch: re-pushing is the safe default.
      expect(boardRestartedFrom('A1B2C3D4', ''), isTrue);
    });

    test('firmware too old to report an epoch is treated as restarted', () {
      // Cannot prove it kept running. Re-asserting state the board already has
      // is harmless; adopting state it has lost is the bug this guards.
      expect(boardRestartedFrom('', 'A1B2C3D4'), isTrue);
      expect(boardRestartedFrom('', ''), isTrue);
    });
  });
}
