import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/watchlist_state.dart';
import 'package:oui_spy/features/engines/detection_rules.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/command_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {double width = 360}) => ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: Scaffold(body: SizedBox(width: width, child: child)),
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('CommandHeader stays one line with many chips at phone width', (tester) async {
    await tester.pumpWidget(_host(CommandHeader(
      title: 'DEVICES',
      count: '12/340',
      chips: [for (var i = 0; i < 8; i++) CommandActiveChip(label: 'FILTER $i', color: AppTheme.accent)],
    )));
    expect(tester.takeException(), isNull);
    final title = tester.getTopLeft(find.text('DEVICES')).dy;
    final count = tester.getTopLeft(find.text('12/340')).dy;
    expect((title - count).abs(), lessThan(4));
  });

  testWidgets('WatchlistPanel shows empty state, then entries; SignaturesPanel renders', (tester) async {
    await tester.pumpWidget(_host(const SingleChildScrollView(
      child: Column(children: [WatchlistPanel(), SignaturesPanel()]),
    )));
    await tester.pumpAndSettle();
    expect(find.text('No targets yet'), findsOneWidget);
    expect(find.text('THREAT SIGNATURES'), findsOneWidget);

    final container = ProviderScope.containerOf(tester.element(find.byType(WatchlistPanel)));
    await container.read(watchlistProvider).importText('40:48:6E,Nokia router\nAA:BB:CC:DD:EE:FF,My tag');
    await tester.pumpAndSettle();
    expect(find.text('Nokia router'), findsOneWidget);
    expect(find.text('OUI prefix · 40:48:6E'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Nokia router'));
    await tester.pumpAndSettle();
    expect(find.text('Edit target'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
  });
}
