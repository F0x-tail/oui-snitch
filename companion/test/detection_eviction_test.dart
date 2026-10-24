import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';

Detection _d(Engine e, int i) => Detection(
      id: '$e-$i',
      sessionId: 's',
      nodeId: 'n',
      macAddress: 'de:ad:be:ef:00:${i.toRadixString(16).padLeft(2, '0')}',
      engine: e,
      method: 'x',
      rssi: -60,
      channel: 6,
      deviceTimestampMs: 0,
      appTimestamp: DateTime(2026),
    );

void main() {
  test('sacrifices the oldest wardrive row, not a classified hit', () {
    // Newest first. Wardrive bulk fills the newer half; the single detector
    // hit is the oldest entry. The old policy only scanned back to the
    // halfway mark, so it evicted the detector hit.
    final buf = <Detection>[
      for (var i = 0; i < 400; i++) _d(Engine.wardrive, i),
      _d(Engine.detector, 999),
    ];
    final idx = AppState.chooseEvictionIndex(buf);
    expect(buf[idx].engine, Engine.wardrive,
        reason: 'a classified detection must outlive wardrive bulk');
    expect(idx, 399, reason: 'oldest wardrive entry');
  });

  test('finds wardrive rows even when they are all in the front half', () {
    final buf = <Detection>[
      for (var i = 0; i < 10; i++) _d(Engine.wardrive, i),
      for (var i = 0; i < 100; i++) _d(Engine.detector, i),
    ];
    final idx = AppState.chooseEvictionIndex(buf);
    expect(buf[idx].engine, Engine.wardrive);
    expect(idx, 9);
  });

  test('falls back to the oldest entry when nothing is wardrive', () {
    final buf = <Detection>[
      for (var i = 0; i < 5; i++) _d(Engine.detector, i),
    ];
    expect(AppState.chooseEvictionIndex(buf), 4);
  });

  test('classified engines are never preferred over each other', () {
    final buf = <Detection>[
      _d(Engine.detector, 0),
      _d(Engine.flockWifi, 1),
      _d(Engine.skySpy, 2),
    ];
    // No wardrive present -> oldest wins, no engine favouritism.
    expect(AppState.chooseEvictionIndex(buf), 2);
  });
}
