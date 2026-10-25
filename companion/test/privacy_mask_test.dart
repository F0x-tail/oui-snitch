// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/privacy.dart';

void main() {
  test('disabled is a pass-through', () {
    expect(maskMac('DE:AD:BE:EF:00:01', false), 'DE:AD:BE:EF:00:01');
    expect(maskId('MyNetwork', false), 'MyNetwork');
  });

  test('MAC keeps the first two bytes, masks the rest, preserves separators', () {
    expect(maskMac('DE:AD:BE:EF:00:01', true), 'DE:AD:XX:XX:XX:XX');
    expect(maskMac('de-ad-be-ef-00-01', true), 'DE-AD-XX-XX-XX-XX');
    expect(maskMac('deadbeef0001', true), 'DEADXXXXXXXX');
  });

  test('a malformed MAC masks fully rather than leaking', () {
    expect(maskMac('not-a-mac', true), 'XX:XX:XX:XX:XX:XX');
  });

  test('names keep the first three characters', () {
    expect(maskId('MyNetwork', true).startsWith('MyN'), isTrue);
    expect(maskId('MyNetwork', true).contains('Network'), isFalse);
  });

  test('short names are left alone (nothing to hide meaningfully)', () {
    expect(maskId('Hi', true), 'Hi');
    expect(maskId('', true), '');
  });

  test('masked output never contains the full original tail', () {
    expect(maskMac('AA:BB:CC:DD:EE:FF', true).contains('FF'), isFalse);
  });
}
