// SPDX-License-Identifier: MIT
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:oui_spy/core/ble/ble_permissions.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:oui_spy/theme/app_theme.dart';

const kPermissionsOnboardedKey = 'permissions_onboarded';

/// Ids of the steps already shown, or found granted. A step is shown once.
const kPermissionsAskedKey = 'permissions_asked';

class PermissionStep {
  const PermissionStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.request,
    String? id,
    this.isGranted,
  }) : id = id ?? title;

  final String id;
  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function(WidgetRef ref) request;

  /// Whether the phone already allows it. Null: unknown, treated as not.
  final Future<bool> Function()? isGranted;
}

/// The steps to show at start-up.
///
/// The walkthrough is for a first install, not for every update: an upgrade
/// whose permissions are all in place goes straight to the app. A step is
/// shown when it was never shown before and the permission is missing, so
/// a version that adds a permission asks for that one only, and a permission
/// the user turned down is not asked for again at every launch (the feature
/// that needs it asks in context).
///
/// Installs from before steps were tracked one by one, recognisable by any
/// stored setting, count every current step as already shown.
Future<List<PermissionStep>> pendingPermissionSteps(SharedPreferences prefs,
    [List<PermissionStep>? all]) async {
  final steps = all ?? defaultPermissionSteps();
  final asked = (prefs.getStringList(kPermissionsAskedKey) ?? const <String>[]).toSet();
  if (!prefs.containsKey(kPermissionsAskedKey) && prefs.getKeys().isNotEmpty) {
    asked.addAll(steps.map((s) => s.id));
  }
  final pending = <PermissionStep>[];
  for (final s in steps) {
    if (asked.contains(s.id)) continue;
    var granted = false;
    try {
      granted = await s.isGranted?.call() ?? false;
    } catch (e) {
      DebugLog.log('PERM: could not check ${s.id}: $e');
    }
    if (granted) {
      asked.add(s.id);
    } else {
      pending.add(s);
    }
  }
  await prefs.setStringList(kPermissionsAskedKey, asked.toList());
  return pending;
}

/// Records [steps] as shown, once the user has been through them.
Future<void> markPermissionStepsAsked(SharedPreferences prefs, List<PermissionStep> steps) async {
  final asked = (prefs.getStringList(kPermissionsAskedKey) ?? const <String>[]).toSet()
    ..addAll(steps.map((s) => s.id));
  await prefs.setStringList(kPermissionsAskedKey, asked.toList());
}

Future<bool> _bluetoothGranted() async {
  if (!Platform.isAndroid) {
    final s = FlutterBluePlus.adapterStateNow;
    return s == BluetoothAdapterState.on || s == BluetoothAdapterState.off;
  }
  if (await BlePermissions.androidSdkInt() >= 31) {
    return await ph.Permission.bluetoothScan.isGranted &&
        await ph.Permission.bluetoothConnect.isGranted;
  }
  return ph.Permission.location.isGranted;
}

Future<bool> _locationGranted() async {
  final p = await Geolocator.checkPermission();
  return p == LocationPermission.whileInUse || p == LocationPermission.always;
}

Future<bool> _notificationsGranted() => ph.Permission.notification.isGranted;

Future<void> _requestBluetooth(WidgetRef ref) async {
  if (Platform.isAndroid) {
    await BlePermissions.ensureForScan();
    return;
  }
  // iOS has no request call: the prompt appears when the adapter is first
  // used, so wait for it to report a state and time out rather than hang.
  await FlutterBluePlus.adapterState
      .firstWhere((s) => s != BluetoothAdapterState.unknown)
      .timeout(const Duration(seconds: 60),
          onTimeout: () => BluetoothAdapterState.unknown);
}

Future<void> _requestLocation(WidgetRef ref) async {
  if (await Geolocator.checkPermission() == LocationPermission.denied) {
    await Geolocator.requestPermission();
  }
}

Future<void> _requestNotifications(WidgetRef ref) =>
    ref.read(notificationServiceProvider).init();

List<PermissionStep> defaultPermissionSteps() => [
      PermissionStep(
        id: 'bluetooth',
        isGranted: _bluetoothGranted,
        icon: Icons.bluetooth,
        title: 'Bluetooth',
        body: 'OUI-SNITCH uses Bluetooth to find your board and receive what it '
            'detects. Your phone can also scan for Bluetooth devices around you '
            'on its own.${Platform.isAndroid ? '\n\nOn Android 12 and newer this '
                'permission is called "Nearby devices".' : ''}',
        request: _requestBluetooth,
      ),
      const PermissionStep(
        id: 'location',
        isGranted: _locationGranted,
        icon: Icons.location_on_outlined,
        title: 'Location',
        body: 'Location puts each detection on the map and records where your '
            'wardrive sessions went. It also lets the app turn the radios off '
            'inside your exclusion zones.\n\nTo keep wardriving with the screen '
            'off, the app asks for "Always" access later, when you start a session.',
        request: _requestLocation,
      ),
      const PermissionStep(
        id: 'notifications',
        isGranted: _notificationsGranted,
        icon: Icons.notifications_outlined,
        title: 'Notifications',
        body: 'Notifications tell you when the app finds a tracker, a camera or '
            'something on your watchlist, even while the app is in the background.',
        request: _requestNotifications,
      ),
    ];

/// The walkthrough runs before the app proper, so it carries its own
/// MaterialApp — there is no router or shell around it yet.
class PermissionsOnboardingApp extends ConsumerWidget {
  const PermissionsOnboardingApp({super.key, required this.onDone, this.steps});

  final VoidCallback onDone;
  final List<PermissionStep>? steps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'OUI-SNITCH',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ref.watch(themeModeProvider),
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        AppTheme.syncBrightness(context);
        return child ?? const SizedBox.shrink();
      },
      home: PermissionsScreen(onDone: onDone, steps: steps),
    );
  }
}

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key, required this.onDone, this.steps});

  final VoidCallback onDone;
  final List<PermissionStep>? steps;

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  late final List<PermissionStep> _steps = widget.steps ?? defaultPermissionSteps();
  int _index = 0;
  bool _busy = false;

  Future<void> _continue() async {
    setState(() => _busy = true);
    final step = _steps[_index];
    try {
      await step.request(ref);
    } catch (e) {
      // A refused permission is a choice, not a failure: the walkthrough
      // carries on and the app degrades where that permission was needed.
      DebugLog.log('ONBOARD: ${step.title} request failed: $e');
    }
    if (!mounted) return;
    if (_index == _steps.length - 1) {
      widget.onDone();
      return;
    }
    setState(() {
      _index++;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final step = _steps[_index];
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'OUI-SNITCH needs ${_steps.length == 1 ? 'one permission' : '${_steps.length} permissions'} to work. '
                'Step ${_index + 1} of ${_steps.length}.',
                style: TextStyle(color: t.textDim, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < _steps.length; i++)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin:
                            EdgeInsets.only(right: i == _steps.length - 1 ? 0 : 6),
                        decoration: BoxDecoration(
                          color: i <= _index ? AppTheme.accent : t.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Icon(step.icon, size: 64, color: AppTheme.accent),
              const SizedBox(height: 20),
              Text(
                step.title,
                style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                step.body,
                style: TextStyle(color: t.textSecondary, fontSize: 16, height: 1.4),
              ),
              const Spacer(),
              Text(
                'Your phone asks you next. You can change this later in Settings.',
                style: TextStyle(color: t.textDim, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _busy ? null : _continue,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
