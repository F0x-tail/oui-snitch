// SPDX-License-Identifier: MIT
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app ships the same LICENSE as the repository', () {
    // The copy under assets/ is what the app shows; the repository root is
    // what gets edited. They must not drift apart.
    expect(File('assets/licenses/LICENSE').readAsStringSync(),
        File('../LICENSE').readAsStringSync());
  });
}
