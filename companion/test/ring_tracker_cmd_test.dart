import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';

void main() {
  test('encodes opcode + 6 MAC bytes + hint', () {
    final cmd = BleProtocol.ringTrackerCmd('DE:AD:BE:EF:00:01');
    expect(cmd, [0x0D, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x00]);
  });

  test('accepts any separator or none', () {
    const want = [0x0D, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x00];
    expect(BleProtocol.ringTrackerCmd('de-ad-be-ef-00-01'), want);
    expect(BleProtocol.ringTrackerCmd('deadbeef0001'), want);
    expect(BleProtocol.ringTrackerCmd('DEADBEEF0001'), want);
  });

  test('carries the protocol hint', () {
    expect(BleProtocol.ringTrackerCmd('deadbeef0001', hint: 2).last, 2);
  });

  test('rejects a malformed MAC rather than sending garbage', () {
    // Too short -> our own length guard.
    expect(() => BleProtocol.ringTrackerCmd('deadbeef'), throwsArgumentError);
    // Non-hex characters are stripped, so a MAC full of junk collapses to the
    // wrong length and is rejected rather than silently sending zeros.
    expect(() => BleProtocol.ringTrackerCmd('zz:zz:zz:zz:zz:zz'),
        throwsArgumentError);
    // A genuine non-hex digit in an otherwise full-length string.
    expect(() => BleProtocol.ringTrackerCmd('g0:ad:be:ef:00:01'),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())));
  });
}
