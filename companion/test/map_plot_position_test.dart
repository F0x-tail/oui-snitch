// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/wardrive_state.dart';

void main() {
  group('plottableCoord', () {
    test('rejects what a device reports when it has no fix', () {
      expect(plottableCoord(null, null), isFalse);
      expect(plottableCoord(0.0, 0.0), isFalse, reason: 'null island');
      expect(plottableCoord(90.0, 10.0), isFalse, reason: 'pole-locked glitch');
      expect(plottableCoord(double.nan, 10.0), isFalse);
    });

    test('accepts an ordinary fix, including a real zero on one axis', () {
      expect(plottableCoord(49.26, -123.25), isTrue);
      expect(plottableCoord(0.0, -123.25), isTrue, reason: 'the equator exists');
    });
  });

  group('sightingWinsPlot', () {
    test('the loudest sighting places the marker', () {
      // RSSI falls off with distance, so the loudest sample was taken closest
      // to the transmitter.
      expect(
        sightingWinsPlot(49.3, -123.2, -40, 49.1, -123.1, -80),
        isTrue,
      );
      expect(
        sightingWinsPlot(49.3, -123.2, -80, 49.1, -123.1, -40),
        isFalse,
      );
    });

    test('a quieter repeat does not drag the marker along the road', () {
      // The live-path bug: every repeat sighting replaced the position, so a
      // device walked backwards behind the car as it faded.
      expect(sightingWinsPlot(49.4, -123.4, -91, 49.3, -123.2, -55), isFalse);
    });

    test('a sighting with no fix never wins, however loud', () {
      // Driving into a GPS shadow must not move the device to nowhere.
      expect(sightingWinsPlot(null, null, -20, 49.3, -123.2, -90), isFalse);
      expect(sightingWinsPlot(0.0, 0.0, -20, 49.3, -123.2, -90), isFalse);
    });

    test('any fix beats no fix, even a quiet one', () {
      expect(sightingWinsPlot(49.3, -123.2, -95, null, null, -20), isTrue);
    });

    test('ties keep what is already plotted, so the marker stops twitching', () {
      expect(sightingWinsPlot(49.4, -123.4, -70, 49.3, -123.2, -70), isFalse);
    });
  });
}
