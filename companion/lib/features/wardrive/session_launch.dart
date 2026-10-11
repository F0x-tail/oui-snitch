import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/theme/app_theme.dart';

bool targetEngineRunning(AppState app, WardriveTarget m) {
  bool on(Engine e) => app.getEngineState(e) != EngineState.disabled;
  return switch (m) {
    WardriveTarget.flock => on(Engine.flockBle) || on(Engine.flockWifi),
    WardriveTarget.drone => on(Engine.skySpy),
    WardriveTarget.detector => on(Engine.detector),
    WardriveTarget.wigle => on(Engine.wardrive),
    WardriveTarget.wigleFlock => on(Engine.wardrive) || on(Engine.flockBle) || on(Engine.flockWifi),
  };
}

class SessionBar extends ConsumerWidget {
  const SessionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final wd = ref.watch(wardriveProvider);
    final app = ref.watch(appStateProvider);
    final live = {
      for (final x in WardriveController.selectableTargets)
        if (targetEngineRunning(app, x)) x,
    };
    final busy = wd.radioTransition != null;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: wd.isActive ? Engine.wardrive.color : t.border, width: wd.isActive ? 1 : 0.5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (final m in WardriveController.selectableTargets)
                Expanded(
                  child: Builder(builder: (context) {
                    final sel = live.contains(m) || (live.isEmpty && wd.isTargetSelected(m));
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => wd.onChipTap(m, live),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: sel ? m.color.withValues(alpha: 0.15) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: sel ? m.color.withValues(alpha: 0.5) : t.border, width: 0.5),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(m.icon, size: 16, color: sel ? m.color : t.textDim),
                            FittedBox(
                              child: Text(
                                m.label,
                                style: TextStyle(color: sel ? m.color : t.textDim, fontSize: 9, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
            ],
          ),
          if (!app.isManagerConnected && !wd.isActive)
            Row(
              children: [
                for (final r in WardriveRadio.values)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setWardriveRadio(ref, switch (r) {
                        WardriveRadio.wifi => 0x01,
                        WardriveRadio.ble => 0x02,
                        WardriveRadio.both => 0x03,
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              switch (r) {
                                WardriveRadio.wifi => Icons.wifi,
                                WardriveRadio.ble => Icons.bluetooth,
                                WardriveRadio.both => Icons.sensors,
                              },
                              size: 12,
                              color: r == wd.radio ? Engine.wardrive.color : t.textDim,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              r.label,
                              style: TextStyle(
                                color: r == wd.radio ? Engine.wardrive.color : t.textDim,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  busy
                      ? '${wd.radioTransition!.toUpperCase()}…'
                      : switch (wd.state) {
                          WardriveState.idle => 'SESSION IDLE',
                          WardriveState.running => 'RECORDING · ${wd.activeLabel} · ${wd.radio.label}',
                          WardriveState.paused => 'PAUSED',
                        },
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: wd.isActive ? Engine.wardrive.color : t.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (!wd.isActive)
                CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  onPressed: busy ? null : () => startWardriveSession(context, ref),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow, size: 18, color: CupertinoColors.white),
                      SizedBox(width: 4),
                      Text('Start', style: TextStyle(color: CupertinoColors.white, fontSize: 14)),
                    ],
                  ),
                )
              else ...[
                CupertinoButton(
                  padding: const EdgeInsets.all(8),
                  minimumSize: Size.zero,
                  onPressed: busy
                      ? null
                      : () => wd.state == WardriveState.paused ? wd.resumeSession() : wd.pauseSession(),
                  child: Icon(wd.state == WardriveState.paused ? Icons.play_arrow : Icons.pause, size: 22),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  color: AppTheme.error,
                  onPressed: busy ? null : wd.stopSession,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop, size: 18, color: CupertinoColors.white),
                      SizedBox(width: 4),
                      Text('Stop', style: TextStyle(color: CupertinoColors.white, fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

Future<bool> startWardriveSession(BuildContext context, WidgetRef ref, {bool requireLocation = true}) async {
  DebugLog.log('WARDRIVE: start requested');
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (ref.read(wardriveProvider).selectedTargets.isEmpty) {
    DebugLog.log('WARDRIVE: start aborted — no targets');
    messenger?.showSnackBar(const SnackBar(content: Text('Select at least one target to scan')));
    return false;
  }
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
  await ref.read(wardriveProvider).startSession();
  return true;
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
            'OUI-SPY needs location access to tag wardrive detections.\n\n'
            'Open Settings → OUI-SPY → Location and choose "While Using" or "Always".',
        action: 'OPEN SETTINGS',
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
            'Settings → OUI-SPY → Location → Always',
        action: 'OPEN SETTINGS',
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
              'Settings → Apps → OUI-SPY → Permissions → Location → Allow all the time',
          action: 'ALLOW ALL THE TIME',
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
  final result = await showCupertinoDialog<Map<String, int>>(
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
  return showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        ...leading,
        CupertinoDialogAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(action == null ? 'OK' : 'Later'),
        ),
        if (action != null)
          CupertinoDialogAction(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await onAction?.call();
            },
            child: Text(action),
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
  await _settingsDialog(
    context,
    title: 'Enable "Always" location',
    body: body,
    action: action,
    onAction: onAction,
    leading: [
      Builder(
        builder: (ctx) => CupertinoDialogAction(
          onPressed: () async {
            await p.setBool(prefKey, true);
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text("Don't ask again"),
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

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Node radios'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          const Text(
            'Assign each node WiFi, BLE, or Both for this wardrive. '
            'WiFi nodes split channels; BLE nodes cover BLE.',
          ),
          const SizedBox(height: 12),
          ...widget.nodes.map((id) {
            final mask = _roles[id] ?? 0x03;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.labelFor(id),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoSlidingSegmentedControl<int>(
                      groupValue: mask,
                      onValueChanged: (v) {
                        if (v != null) setState(() => _roles[id] = v);
                      },
                      children: const {
                        0x01: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Text('WiFi', style: TextStyle(fontSize: 12)),
                        ),
                        0x02: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Text('BLE', style: TextStyle(fontSize: 12)),
                        ),
                        0x03: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Text('Both', style: TextStyle(fontSize: 12)),
                        ),
                      },
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context, _roles),
          child: const Text('Start'),
        ),
      ],
    );
  }
}
