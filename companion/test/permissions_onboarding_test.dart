// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:oui_spy/features/onboarding/permissions_screen.dart';
import 'package:oui_spy/theme/app_theme.dart';

void main() {
  PermissionStep perm(String id, bool granted) => PermissionStep(
        id: id,
        icon: Icons.check,
        title: id,
        body: '',
        request: (_) async {},
        isGranted: () async => granted,
      );

  test('a fresh install sees every permission it does not have yet', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final steps = await pendingPermissionSteps(prefs, [perm('bt', false), perm('loc', false)]);
    expect(steps.map((s) => s.id), ['bt', 'loc']);
  });

  test('an update with its permissions in place goes straight to the app', () async {
    // Even with nothing stored: granted permissions are not asked for again.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(await pendingPermissionSteps(prefs, [perm('bt', true), perm('loc', true)]), isEmpty);
  });

  test('an install from before per-step tracking is never walked through again', () async {
    SharedPreferences.setMockInitialValues({kPermissionsOnboardedKey: true});
    final prefs = await SharedPreferences.getInstance();
    expect(await pendingPermissionSteps(prefs, [perm('bt', false), perm('loc', false)]), isEmpty);
  });

  test('a new permission is asked for once, a refused one not again', () async {
    SharedPreferences.setMockInitialValues({kPermissionsAskedKey: ['bt', 'loc']});
    final prefs = await SharedPreferences.getInstance();
    final all = [perm('bt', true), perm('loc', false), perm('nfc', false)];
    final first = await pendingPermissionSteps(prefs, all);
    expect(first.map((s) => s.id), ['nfc']);              // loc was refused before
    await markPermissionStepsAsked(prefs, first);
    expect(await pendingPermissionSteps(prefs, all), isEmpty);
  });

  testWidgets('each Continue asks for one permission, in order, then finishes', (tester) async {
    final asked = <String>[];
    var done = false;
    PermissionStep step(String name) => PermissionStep(
          icon: Icons.check,
          title: name,
          body: '$name body',
          request: (_) async => asked.add(name),
        );

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: PermissionsScreen(
          onDone: () => done = true,
          steps: [step('Bluetooth'), step('Location'), step('Notifications')],
        ),
      ),
    ));

    for (final (i, name) in ['Bluetooth', 'Location', 'Notifications'].indexed) {
      expect(find.text(name), findsOneWidget);
      expect(find.textContaining('Step ${i + 1} of 3'), findsOneWidget);
      expect(asked.length, i);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump();
    }
    expect(asked, ['Bluetooth', 'Location', 'Notifications']);
    expect(done, isTrue);
  });
}
