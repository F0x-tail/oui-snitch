// SPDX-License-Identifier: MIT
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/theme/app_theme.dart';

bool targetEngineRunning(AppState app, WardriveTarget m) {
  bool on(Engine e) => app.getEngineState(e) != EngineState.disabled;
  return switch (m) {
    WardriveTarget.flock => on(Engine.flockWifi),
    WardriveTarget.drone => on(Engine.skySpy),
    WardriveTarget.detector => on(Engine.detector),
    WardriveTarget.wigle => on(Engine.wardrive),
    WardriveTarget.wigleFlock => on(Engine.wardrive) || on(Engine.flockWifi),
  };
}

/// Start a wardrive session. **The only way one starts.**
///
/// Every caller — the HOME tile, the map's START, anything added later —
/// arrives here, so the permission prime, the radio-role confirmation and the
/// offline-scan warning cannot be skipped by reaching past it. [origin] is
/// recorded so a session's provenance is in the log when something goes wrong.
///
/// [requireLocation] is the one deliberate difference between callers: the map
/// prompts for location because that is where the track is about to be drawn,
/// while the HOME tile starts without interrupting and records ungeotagged
/// rows if there is no fix.
Future<bool> startWardriveSession(BuildContext context, WidgetRef ref,
    {bool requireLocation = true, String origin = 'unknown'}) async {
  DebugLog.log('WARDRIVE: start requested from $origin');
  final messenger = ScaffoldMessenger.maybeOf(context);
  ref.read(gpsProvider).onMessage = (msg) => messenger?.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.accent, duration: const Duration(seconds: 4)),
      );
  if (requireLocation && !await primeLocationPermission(context)) {
    DebugLog.log('WARDRIVE: start aborted — location permission/services');
    return false;
  }
  if (!context.mounted) {
    DebugLog.log('WARDRIVE: start aborted — screen gone');
    return false;
  }
  if (!await confirmRadioRoles(context, ref)) {
    DebugLog.log('WARDRIVE: start aborted — radio roles canceled');
    return false;
  }
  // Wardrive can't be captured offline on this board: it is not spoolable (no
  // SD card — the firmware only spools to the small internal flash, and
  // deliberately excludes wardrive from it). So while "Keep scanning while
  // disconnected" is on, a wardrive runs live only — it records nothing once
  // the phone is out of range, and the experimental mode's spool-flush is
  // skipped so it does not swallow the live feed. Warn, but still start.
  if (ref.read(bleManagerProvider).offlineScanEnabled) {
    DebugLog.log('WARDRIVE: offline-scan on — wardrive is live-only (no SD capture)');
    messenger?.showSnackBar(const SnackBar(
      content: Text(
          'Keep-scanning is on: wardrive runs live only and is NOT captured '
          'while disconnected (needs an SD card). Turn it off for offline runs.'),
      duration: Duration(seconds: 6),
    ));
  }
  await ref.read(wardriveProvider).startSession();
  return true;
}

/// Stop a wardrive session. **The only way one stops by request.**
///
/// A thin hop, deliberately: teardown itself belongs to the controller, which
/// is the only thing that knows which engines the session borrowed rather than
/// owns. What this adds is a single named door, so a stop is attributable to
/// the screen that asked for it and any future guard lands once instead of at
/// every button.
Future<void> stopWardriveSession(WidgetRef ref, {String origin = 'unknown'}) {
  DebugLog.log('WARDRIVE: stop requested from $origin');
  return ref.read(wardriveProvider).stopSession();
}

Future<bool>? _priming;

Future<bool> primeLocationPermission(BuildContext context) => _priming ??=
    _primeLocationPermission(context).whenComplete(() => _priming = null);

Future<bool> _primeLocationPermission(BuildContext context) async {
  if (!context.mounted) return false;
  {
    var status = await Geolocator.checkPermission();
    if (status == LocationPermission.denied) {
      status = await Geolocator.requestPermission();
    }
    if (!context.mounted) return false;
    if (status == LocationPermission.denied ||
        status == LocationPermission.deniedForever) {
      await _settingsDialog(
        context,
        title: 'Location Permission Required',
        body:
            'OUI-SNITCH needs location access to tag wardrive detections.\n\n'
            'Open Settings → OUI-SNITCH → Location and choose "While Using" or "Always".',
        action: 'Open settings',
        onAction: Geolocator.openAppSettings,
      );
      return false;
    }
    final servicesOn = await Geolocator.isLocationServiceEnabled();
    if (!context.mounted) return false;
    if (!servicesOn) {
      await _settingsDialog(
        context,
        title: 'Location Services Off',
        body:
            'Enable Settings → Privacy & Security → Location Services to wardrive.',
      );
      return false;
    }
    if (Platform.isIOS && status == LocationPermission.whileInUse) {
      await _alwaysUpgradeDialog(
        context,
        prefKey: 'ios_always_upgrade_dismissed',
        body:
            'iOS only shows "While Using" in the first prompt. For wardriving with screen off, set:\n\n'
            'Settings → OUI-SNITCH → Location → Always',
        action: 'Open settings',
        onAction: Geolocator.openAppSettings,
      );
    } else if (Platform.isAndroid) {
      final always = await ph.Permission.locationAlways.status;
      if (!always.isGranted && context.mounted) {
        await _alwaysUpgradeDialog(
          context,
          prefKey: 'android_always_upgrade_dismissed',
          body:
              'For background tracking, Android requires "Allow all the time".\n\n'
              'Settings → Apps → OUI-SNITCH → Permissions → Location → Allow all the time',
          action: 'Allow all the time',
          onAction: () async {
            if (!(await ph.Permission.locationAlways.request()).isGranted) {
              await ph.openAppSettings();
            }
          },
        );
      }
    }
    return true;
  }
}

Future<bool> confirmRadioRoles(BuildContext context, WidgetRef ref) async {
  final app = ref.read(appStateProvider);
  if (!app.isManagerConnected) return true;
  final mgrId = AppState.canonicalNodeId(app.nodeId);
  final nodes = app.liveKnownNodes.where((id) => id != mgrId).toList()..sort();
  if (nodes.isEmpty) return true;
  final result = await showDialog<Map<String, int>>(
    context: context,
    builder: (_) => RadioRolePopup(
      nodes: nodes,
      labelFor: app.labelForNode,
      initial: {for (final n in nodes) n: app.wardriveRadioForNode(n)},
    ),
  );
  if (result == null) return false;
  await app.applyNodeRadioRoles(result);
  if (!app.isManagerConnected && result.length == 1) {
    setWardriveRadio(ref, result.values.first);
  }
  return true;
}

void setWardriveRadio(WidgetRef ref, int mask) {
  final wd = ref.read(wardriveProvider);
  final app = ref.read(appStateProvider);
  wd.setRadio(WardriveController.radioFromMask(mask));
  app.setEngineRadio(Engine.wardrive, mask);
  for (final t in wd.selectedTargets) {
    final e = t.radioMaskEngine;
    if (e != null && e != Engine.wardrive) app.setEngineRadio(e, mask);
  }
}

Future<void> _settingsDialog(
  BuildContext context, {
  required String title,
  required String body,
  String? action,
  Future<void> Function()? onAction,
  List<Widget> leading = const [],
}) {
  final t = AppTheme.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(
        title,
        style: TextStyle(
          color: t.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        body,
        style: TextStyle(color: t.textSecondary, fontSize: 13),
      ),
      actions: [
        ...leading,
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(
            action == null ? 'OK' : 'Later',
            style: TextStyle(
              color: action == null ? AppTheme.accent : t.textDim,
            ),
          ),
        ),
        if (action != null)
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await onAction?.call();
            },
            child: Text(action, style: TextStyle(color: AppTheme.accent)),
          ),
      ],
    ),
  );
}

Future<void> _alwaysUpgradeDialog(
  BuildContext context, {
  required String prefKey,
  required String body,
  required String action,
  required Future<void> Function() onAction,
}) async {
  final p = await SharedPreferences.getInstance();
  if (p.getBool(prefKey) == true || !context.mounted) return;
  final t = AppTheme.of(context);
  await _settingsDialog(
    context,
    title: 'Enable "Always" Location',
    body: body,
    action: action,
    onAction: onAction,
    leading: [
      Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            await p.setBool(prefKey, true);
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: Text("Don't ask again", style: TextStyle(color: t.textDim)),
        ),
      ),
    ],
  );
}

class RadioRolePopup extends StatefulWidget {
  const RadioRolePopup({
    super.key,
    required this.nodes,
    required this.labelFor,
    required this.initial,
  });

  final List<String> nodes;
  final String Function(String) labelFor;
  final Map<String, int> initial;

  @override
  State<RadioRolePopup> createState() => _RadioRolePopupState();
}

class _RadioRolePopupState extends State<RadioRolePopup> {
  late final Map<String, int> _roles = {
    for (final n in widget.nodes) n: widget.initial[n] ?? 0x03,
  };

  // One tint; the Wi-Fi, Bluetooth and both icons tell the roles apart.
  static Color get _wifiColor => AppTheme.accent;
  static Color get _bleColor => AppTheme.accent;
  static Color get _bothColor => AppTheme.accent;

  static Color _radioColor(int mask) => switch (mask & 0x03) {
    0x01 => _wifiColor,
    0x02 => _bleColor,
    _ => _bothColor,
  };

  static String _maskLabel(int mask) => switch (mask & 0x03) {
    0x01 => 'Wi-Fi',
    0x02 => 'BLE',
    _ => 'Both',
  };

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return AlertDialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(
        children: [
          Icon(
            Icons.settings_input_antenna,
            color: AppTheme.accent,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            'Node radios',
            style: TextStyle(
              color: t.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Assign each node WiFi, BLE, or Both for this wardrive. '
                'WiFi nodes split channels; BLE nodes cover BLE.',
                style: TextStyle(fontSize: 12, color: t.textSecondary),
              ),
            ),
            ...widget.nodes.map((id) {
              final mask = _roles[id] ?? 0x03;
              final selColor = _radioColor(mask);
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: t.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selColor.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: selColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            widget.labelFor(id),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        Text(
                          _maskLabel(mask),
                          style: TextStyle(
                            color: selColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: WidgetStateProperty.all(
                            const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          backgroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.selected)
                                ? selColor.withValues(alpha: 0.22)
                                : Colors.transparent,
                          ),
                          side: WidgetStateProperty.all(
                            BorderSide(color: selColor.withValues(alpha: 0.45)),
                          ),
                        ),
                        segments: [
                          ButtonSegment(
                            value: 0x01,
                            icon: Icon(Icons.wifi, size: 15, color: _wifiColor),
                            label: Text('WiFi'),
                          ),
                          ButtonSegment(
                            value: 0x02,
                            icon: Icon(
                              Icons.bluetooth,
                              size: 15,
                              color: _bleColor,
                            ),
                            label: Text('BLE'),
                          ),
                          ButtonSegment(
                            value: 0x03,
                            icon: Icon(
                              Icons.sensors,
                              size: 15,
                              color: _bothColor,
                            ),
                            label: Text('Both'),
                          ),
                        ],
                        selected: {mask},
                        onSelectionChanged: (s) =>
                            setState(() => _roles[id] = s.first),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: t.textDim)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accent,
            foregroundColor: AppTheme.background,
          ),
          onPressed: () => Navigator.pop(context, _roles),
          child: const Text('Start'),
        ),
      ],
    );
  }
}
