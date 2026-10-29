// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final _shellKey = GlobalKey<NavigatorState>();

GoRouter _router() => GoRouter(initialLocation: '/home', routes: [
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (c, s, child) => Scaffold(body: child),
        routes: [
          GoRoute(path: '/home', builder: (c, s) => const Text('HOME')),
          GoRoute(path: '/config', builder: (c, s) => const Text('CONFIG')),
        ],
      ),
      GoRoute(path: '/settings', builder: (c, s) => const Scaffold(body: Text('CONFIG'))),
      GoRoute(path: '/engine/detector', builder: (c, s) => const Scaffold(body: Text('DETECTOR'))),
    ]);

void main() {
  // Mirrors the app's route layout. The detector screen sits outside the
  // shell; it used to push the shell's '/config', which builds a second shell
  // with the same navigator key and leaves a blank page.
  testWidgets('settings opened from an engine screen render, and Back returns', (tester) async {
    final r = _router();
    await tester.pumpWidget(MaterialApp.router(routerConfig: r));
    r.push('/engine/detector');
    await tester.pumpAndSettle();
    r.push('/settings');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('CONFIG'), findsOneWidget);
    r.pop();
    await tester.pumpAndSettle();
    expect(find.text('DETECTOR'), findsOneWidget);
  });
}
