// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/features/wardrive/wardrive_screen.dart';

void main() {
  test('wardrive detections are plottable from the shared feed', () {
    // Regression: Engine.wardrive was excluded, so wardrive detections
    // arriving outside an active session were invisible on the map even with
    // a GPS fix — while still showing in the log. A user capture had all 30
    // detections as engine='wardrive', all with coordinates, and an empty map.
    expect(mapShowsEngine(Engine.wardrive), isTrue);
  });

  test('the other mappable engines still pass', () {
    for (final e in [
      Engine.skySpy,
      Engine.axon,
      Engine.flockWifi,
      Engine.detector,
    ]) {
      expect(mapShowsEngine(e), isTrue, reason: '$e must stay mappable');
    }
  });

  test('engines with no map representation stay excluded', () {
    // These produce no geo-locatable device point of their own.
    for (final e in [Engine.foxhunter, Engine.pcap, Engine.uniPwn]) {
      expect(mapShowsEngine(e), isFalse, reason: '$e should not be plotted');
    }
  });
}
