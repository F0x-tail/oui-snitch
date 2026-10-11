import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/features/config/widgets/config_nav.dart';

final _hostKey = GlobalKey<_HostState>();

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TabController controller =
      TabController(length: kConfigSections.length, vsync: this);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('HOST')));
}

Widget _app() => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: _Host(key: _hostKey),
    );

/// Always a live context — a stale Element cannot reach the Navigator.
BuildContext get _ctx => _hostKey.currentContext!;
TabController get _controller => _hostKey.currentState!.controller;

void main() {
  testWidgets('toggle opens the section sheet, then closes it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(configSectionSheetOpen(_ctx), isFalse);

    toggleConfigSectionSheet(_ctx, _controller);
    await tester.pumpAndSettle();
    expect(find.text('SECTION'), findsOneWidget);
    expect(configSectionSheetOpen(_ctx), isTrue);

    toggleConfigSectionSheet(_ctx, _controller);
    await tester.pumpAndSettle();
    expect(find.text('SECTION'), findsNothing);
    expect(configSectionSheetOpen(_ctx), isFalse);
  });

  testWidgets('a second open request never stacks two sheets', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    showConfigSectionSheet(_ctx, _controller);
    await tester.pumpAndSettle();
    showConfigSectionSheet(_ctx, _controller);
    await tester.pumpAndSettle();

    expect(find.text('SECTION'), findsOneWidget);
    Navigator.of(_ctx).pop();
    await tester.pumpAndSettle();
    expect(find.text('SECTION'), findsNothing);
  });

  testWidgets('reopens after every close — no sticky open state', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      showConfigSectionSheet(_ctx, _controller);
      await tester.pumpAndSettle();
      expect(find.text('SECTION'), findsOneWidget, reason: 'open #$i');

      Navigator.of(_ctx).pop();
      await tester.pumpAndSettle();
      expect(find.text('SECTION'), findsNothing, reason: 'close #$i');
    }
  });

  testWidgets('picking a section closes the sheet and switches tab',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    showConfigSectionSheet(_ctx, _controller);
    await tester.pumpAndSettle();

    await tester.tap(find.text('DATA').last);
    await tester.pumpAndSettle();

    expect(find.text('SECTION'), findsNothing);
    expect(_controller.index, kConfigSections.length - 1);
    expect(configSectionSheetOpen(_ctx), isFalse);
  });
}
