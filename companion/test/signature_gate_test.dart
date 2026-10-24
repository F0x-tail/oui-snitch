import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/classify/signature_engine.dart';
import 'package:oui_spy/core/detector_signatures.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';

void main() {
  test('tracker alerts are governed by the Trackers signature bit', () {
    expect(NotificationService.signatureBitFor(SignatureClass.finder), sigTracker);
  });

  test('every mapped class is suppressed when its bit is clear', () {
    const mask = sigAll & ~sigTracker & ~sigCamera;
    for (final c in [SignatureClass.finder, SignatureClass.camera, SignatureClass.surveillance]) {
      final bit = NotificationService.signatureBitFor(c)!;
      expect(mask & bit, 0, reason: '$c must be off when its signature is off');
    }
    // Untouched signatures stay on.
    final glasses = NotificationService.signatureBitFor(SignatureClass.glasses)!;
    expect(mask & glasses, isNot(0));
  });

  test('classes with no signature equivalent are not accidentally gated', () {
    // These have no Detections > Signature switch, so classAlerts alone
    // decides. Returning a bit here would silently disable them.
    for (final c in [
      SignatureClass.beacon,
      SignatureClass.phone,
      SignatureClass.home,
      SignatureClass.vehicle,
      SignatureClass.drone,
    ]) {
      expect(NotificationService.signatureBitFor(c), isNull, reason: '$c');
    }
  });

  test('law enforcement and body-worn share the Axon bit', () {
    expect(NotificationService.signatureBitFor(SignatureClass.lawEnforcement), sigAxon);
    expect(NotificationService.signatureBitFor(SignatureClass.bodyworn), sigAxon);
  });
}
