// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/features/home/engine_card.dart';
import 'package:oui_spy/theme/app_theme.dart';

// The home screen's Tracking row: two medium cards, at least 170 px tall and
// otherwise as tall as their content. A fixed height let a large system font
// push the detection count out of the tile.
// One container for the whole file: disposing the app's providers between
// tests closes streams the BLE layer still writes to.
final _container = ProviderContainer();

Widget _row(double textScale) => UncontrolledProviderScope(
      container: _container,
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: MediaQuery(
          data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 170),
                child: const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: EngineCard(engine: Engine.detector, detectionCount: 1234, size: CardSize.medium)),
                      SizedBox(width: 8),
                      Expanded(child: EngineCard(engine: Engine.skySpy, detectionCount: 56, size: CardSize.medium)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('tracking tiles hold their count at text scale $scale', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_row(scale));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byType(EngineCard).first);
      final count = tester.getRect(find.text('1234'));
      expect(card.contains(count.bottomRight - const Offset(1, 1)), isTrue,
          reason: 'count $count outside card $card');
    });
  }
}
