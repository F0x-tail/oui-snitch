import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/features/config/widgets/config_nav.dart';

void expectNotTruncated(WidgetTester tester, String label) {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) return;
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final natural = paragraph.getMaxIntrinsicWidth(double.infinity);
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(natural - 0.5),
    reason: '"$label" is clipped: '
        '${paragraph.size.width} < $natural',
  );
}

void _noop() {}

class _Host extends StatefulWidget {
  const _Host({required this.actions});
  final List<CommandBarAction> actions;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TabController controller = TabController(
    length: kConfigSections.length,
    vsync: this,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConfigNav(
      controller: controller,
      child: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: controller,
              children: [
                for (final s in kConfigSections)
                  Center(child: Text('${s.label} BODY')),
              ],
            ),
          ),
          ConfigBottomBar(actions: widget.actions),
        ],
      ),
    );
  }
}

Widget _app({
  Size size = const Size(390, 844),
  double textScale = 1.0,
  List<CommandBarAction> actions = const [],
}) {
  return MediaQuery(
    data: MediaQueryData(
      size: size,
      textScaler: TextScaler.linear(textScale),
      padding: const EdgeInsets.only(bottom: 34),
    ),
    child: MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: _Host(actions: actions)),
    ),
  );
}

void main() {
  const sizes = <String, Size>{
    'iphone-se': Size(320, 568),
    'iphone-13': Size(390, 844),
    'iphone-max': Size(430, 932),
    'ipad': Size(834, 1194),
  };

  group('ConfigBottomBar lays out without overflow', () {
    for (final entry in sizes.entries) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        testWidgets('${entry.key} @ ${scale}x text', (tester) async {
          tester.view.physicalSize = entry.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(_app(
            size: entry.value,
            textScale: scale,
            actions: const [
              CommandBarAction(
                icon: Icons.filter_alt,
                label: 'FILTER',
                active: true,
                onTap: _noop,
              ),
              CommandBarAction(
                icon: Icons.arrow_downward,
                label: 'TIME',
                active: true,
                onTap: _noop,
              ),
              CommandBarAction(
                icon: Icons.more_horiz,
                label: 'MORE',
                onTap: _noop,
              ),
            ],
          ));
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.text('APP BODY'), findsOneWidget);
          expect(find.byType(CommandBarTap), findsNWidgets(4));

          for (final label in ['APP', 'FILTER', 'TIME', 'MORE']) {
            expectNotTruncated(tester, label);
          }
        });
      }
    }
  });

  testWidgets('action labels stay visible on a normal phone', (tester) async {
    await tester.pumpWidget(_app(actions: const [
      CommandBarAction(icon: Icons.filter_alt, label: 'FILTER', onTap: _noop),
      CommandBarAction(icon: Icons.arrow_downward, label: 'TIME', onTap: _noop),
      CommandBarAction(icon: Icons.more_horiz, label: 'MORE', onTap: _noop),
    ]));
    await tester.pumpAndSettle();

    for (final label in ['FILTER', 'TIME', 'MORE']) {
      expect(find.text(label), findsOneWidget);
      expectNotTruncated(tester, label);
    }
  });

  testWidgets('longest section label is never clipped', (tester) async {
    for (final entry in sizes.entries) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        await tester.pumpWidget(_app(
          size: entry.value,
          textScale: scale,
          actions: const [
            CommandBarAction(
                icon: Icons.filter_alt, label: 'FILTER', onTap: _noop),
            CommandBarAction(
                icon: Icons.arrow_downward, label: 'TIME', onTap: _noop),
            CommandBarAction(
                icon: Icons.more_horiz, label: 'MORE', onTap: _noop),
          ],
        ));
        await tester.pumpAndSettle();

        final longest = kConfigSections
            .map((s) => s.label)
            .reduce((a, b) => a.length >= b.length ? a : b);
        final index =
            kConfigSections.indexWhere((s) => s.label == longest);
        tester.state<_HostState>(find.byType(_Host)).controller.animateTo(index);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull,
            reason: '${entry.key} @ ${scale}x');
        expectNotTruncated(tester, longest);
      }
    }
  });

  testWidgets('bar tap targets meet the minimum interactive dimension',
      (tester) async {
    await tester.pumpWidget(_app(actions: const [
      CommandBarAction(
        icon: Icons.filter_alt,
        label: 'FILTER',
        onTap: _noop,
      ),
    ]));
    await tester.pumpAndSettle();

    for (final finder in [
      find.byType(CommandBarTap).first,
      find.byType(CommandBarTap).last,
    ]) {
      expect(tester.getSize(finder).height,
          greaterThanOrEqualTo(kMinInteractiveDimension));
    }
  });

  testWidgets('section sheet exposes every section and switches tab',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('APP BODY'), findsOneWidget);

    await tester.tap(find.byType(CommandBarTap));
    await tester.pumpAndSettle();

    for (final s in kConfigSections) {
      expect(find.text(s.label), findsWidgets, reason: 'missing ${s.label}');
    }

    await tester.tap(find.text('DATA').last);
    await tester.pumpAndSettle();

    expect(find.text('DATA BODY'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CommandBar without a leading button fits and keeps labels',
      (tester) async {
    for (final entry in sizes.entries) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MediaQuery(
          data: MediaQueryData(
            size: entry.value,
            textScaler: TextScaler.linear(scale),
          ),
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            home: const Scaffold(
              body: Column(
                children: [
                  Expanded(child: SizedBox()),
                  CommandBar(actions: [
                    CommandBarAction(
                        icon: Icons.filter_alt,
                        label: 'FILTER',
                        onTap: _noop),
                    CommandBarAction(
                        icon: Icons.arrow_downward,
                        label: 'TIME',
                        onTap: _noop),
                    CommandBarAction(
                        icon: Icons.more_horiz, label: 'MORE', onTap: _noop),
                  ]),
                ],
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull,
            reason: '${entry.key} @ ${scale}x');
        for (final label in ['FILTER', 'TIME', 'MORE']) {
          if (scale == 1.0) {
            expect(find.text(label), findsOneWidget,
                reason: '$label missing at ${entry.key} @ ${scale}x');
          }
          expectNotTruncated(tester, label);
        }
      }
    }
  });

  testWidgets('section grid centers a partial trailing row', (tester) async {
    tester.view.physicalSize = const Size(834, 1194);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(size: const Size(834, 1194)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CommandBarTap));
    await tester.pumpAndSettle();

    final tiles = [
      for (final s in kConfigSections)
        tester.getRect(find
            .ancestor(
              of: find.text(s.label).last,
              matching: find.byType(SizedBox),
            )
            .first),
    ];
    final rows = <double, List<Rect>>{};
    for (final r in tiles) {
      rows.putIfAbsent(r.top, () => []).add(r);
    }
    expect(rows.length, greaterThan(1), reason: 'expected a wrapped grid');
    expect(rows.values.map((r) => r.length).toSet().length, greaterThan(1),
        reason: 'expected a partial trailing row');

    final centers = rows.values.map((row) {
      final left = row.map((r) => r.left).reduce((a, b) => a < b ? a : b);
      final right = row.map((r) => r.right).reduce((a, b) => a > b ? a : b);
      return (left + right) / 2;
    }).toList();
    for (final c in centers) {
      expect((c - centers.first).abs(), lessThan(1.0),
          reason: 'rows are not centered on the same axis: $centers');
    }
  });

  testWidgets('section sheet grid reflows on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(size: const Size(320, 568), textScale: 2.0));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CommandBarTap));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('NODE'), findsWidgets);
  });
}
