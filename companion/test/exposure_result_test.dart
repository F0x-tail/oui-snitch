import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/exposure/exposure_result.dart';

void main() {
  test('phases decode, other opcodes are not ours', () {
    expect(ExposureUpdate.decode([0x11, 1])!.phase, ExposurePhase.baseline);
    expect(ExposureUpdate.decode([0x11, 2])!.phase, ExposurePhase.watch);
    expect(ExposureUpdate.decode([0x08, 2, 0, 0, 0]), isNull);
    expect(ExposureUpdate.decode([0x11, 9]), isNull);
  });

  test('result carries the names the phone called out', () {
    // Layout written by the firmware's expoEncode.
    final u = ExposureUpdate.decode([
      0x11, 3, //
      1, 300 & 0xFF, 300 >> 8, 0x02, 2, //
      4, 0x68, 0x6f, 0x6d, 0x65, // "home"
      2, 0xff, 0x41, // malformed UTF-8 still shown
    ])!;
    expect(u.phase, ExposurePhase.done);
    final r = u.result!;
    expect(r.found, isTrue);
    expect(r.probes, 300);
    expect(r.factoryAddress, isTrue);
    expect(r.randomAddress, isFalse);
    expect(r.networks.first, 'home');
    expect(r.networks.length, 2);
  });

  test('a result cut short keeps what arrived', () {
    final r = ExposureUpdate.decode([0x11, 3, 1, 5, 0, 0x01, 2, 4, 0x61])!.result!;
    expect(r.networks, isEmpty);
    expect(r.randomAddress, isTrue);
  });
}
