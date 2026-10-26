// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/detector_signatures.dart';
import 'package:oui_spy/core/watchlist_state.dart';
import 'package:oui_spy/features/feed/detection_row.dart';
import 'package:oui_spy/core/engine_control.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/detections/detections_screen.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';

class DetectorScreen extends ConsumerWidget {
  const DetectorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);
    final detections = state.detectionsForEngine(Engine.detector);
    final sigMask = ref.watch(detectorSigMaskProvider);
    final targets = ref.watch(watchlistProvider).entries.length;
    final watching = [
      for (final s in detectorSignatures)
        if (sigMask & s.bit != 0) s.short.replaceAll('-\n', ''),
      if (targets > 0) '$targets watchlist target${targets == 1 ? '' : 's'}',
    ];

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: const Text('Detector'),
        actions: [
          Transform.scale(
            scale: 0.7,
            child: Switch(
              value: state.isEngineActive(Engine.detector),
              onChanged: (on) => setEngineEnabled(ref, Engine.detector, on),
              activeTrackColor: AppTheme.detector.withValues(alpha: 0.3),
              activeThumbColor: AppTheme.detector,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear detections',
            onPressed: () => ref.read(appStateProvider).clearDetectionsForEngine(Engine.detector),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.track_changes, color: AppTheme.detector),
            title: Text('Watching for',
                style: TextStyle(color: t.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
            subtitle: Text(
              watching.isEmpty ? 'Nothing selected · tap to choose' : watching.join(', '),
              style: TextStyle(color: t.textDim, fontSize: 12),
            ),
            trailing: Icon(Icons.chevron_right, color: t.textDim),
            onTap: () {
              ref.read(configSectionRequestProvider.notifier).state = 'DETECTION';
              // push, not go: this screen lives OUTSIDE the bottom-nav
              // ShellRoute, and go() replaces the whole stack — which destroyed
              // the back entry and made Back exit the app. The go('/config')
              // calls in home_screen are correct, because those run from inside
              // the shell where it is tab-switching.
              context.push('/config');
            },
          ),
          const Divider(height: 1),
          // A dedicated entry so the beeper can be exercised without waiting
          // for a tracker detection to appear. The per-detection "Make it beep"
          // action only shows on an actual tracker hit, which makes it
          // impossible to test — or to confirm nothing fires — on demand.
          ListTile(
            leading: const Icon(Icons.notifications_active,
                color: AppTheme.detector),
            title: Text('FindMy Beeper',
                style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            subtitle: Text(
              'Ring a tracker by MAC to locate it. Only works on a tracker '
              'separated from its owner, and in range.',
              style: TextStyle(color: t.textDim, fontSize: 12),
            ),
            trailing: Icon(Icons.chevron_right, color: t.textDim),
            onTap: () => _showBeeperSheet(context, ref),
          ),
          const Divider(height: 1),
          // Diagnostic: are detections actually carrying coordinates? An empty
          // map can mean "no fix yet" or "coords never stamped", and those look
          // identical from the map itself.
          Builder(builder: (_) {
            final withGps = detections.where((d) => d.latitude != null).length;
            final fix = ref.watch(gpsProvider).lastPosition;
            final ok = detections.isEmpty ? true : withGps == detections.length;
            return ListTile(
              dense: true,
              leading: Icon(
                fix == null ? Icons.gps_off : (ok ? Icons.gps_fixed : Icons.gps_not_fixed),
                color: fix == null || !ok ? AppTheme.warning : AppTheme.detector,
              ),
              title: Text('Map coverage',
                  style: TextStyle(color: t.textPrimary, fontSize: 13)),
              subtitle: Text(
                fix == null
                    ? 'No GPS fix yet — detections cannot be placed on the map'
                    : '$withGps of ${detections.length} have coordinates'
                      '${ok ? '' : ' · the rest arrived before the first fix'}',
                style: TextStyle(color: t.textDim, fontSize: 11),
              ),
            );
          }),
          const Divider(height: 1),
          if (detections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
              child: Text(
                state.isEngineActive(Engine.detector)
                    ? 'No hits yet. Hits show up here as the board finds them.'
                    : 'Turn the detector on to start watching.',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.textDim, fontSize: 13),
              ),
            )
          else
            for (final d in detections.take(50)) DetectionRow(detection: d),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.history, color: AppTheme.detector),
            title: Text('Detection',
                style: TextStyle(color: t.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${detections.length} this session · filters, map, export',
              style: TextStyle(color: t.textDim, fontSize: 12),
            ),
            trailing: Icon(Icons.chevron_right, color: t.textDim),
            onTap: () {
              ref.read(historyFilterRequestProvider.notifier).state = 'detector';
              ref.read(detectionsViewProvider.notifier).state = DetectionsView.detection;
              context.go('/detections');
            },
          ),
        ],
      ),
    );
  }
}

/// Ring a tracker by MAC, without needing a live detection to tap.
///
/// Pre-fills from the most recent tracker hit when there is one, so the common
/// case is one tap, but a MAC can be typed in to test on demand.
Future<void> _showBeeperSheet(BuildContext context, WidgetRef ref) async {
  final t = AppTheme.of(context);
  final recent = ref
      .read(appStateProvider)
      .recentDetections
      .where((d) => d.method == 'tracker')
      .toList();
  final ctrl = TextEditingController(
      text: recent.isNotEmpty ? recent.first.macAddress.toUpperCase() : '');

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.surface,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('FindMy Beeper',
              style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Connects to the tracker and plays its sound. It only works on a '
            'tracker that is away from its owner — which is the case for one '
            'that is following you. The board transmits to do this.',
            style: TextStyle(color: t.textDim, fontSize: 12),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: ctrl,
            autocorrect: false,
            style: TextStyle(color: t.textPrimary),
            decoration: InputDecoration(
              labelText: 'Tracker MAC',
              hintText: 'AA:BB:CC:DD:EE:FF',
              labelStyle: TextStyle(color: t.textDim),
              border: const OutlineInputBorder(),
            ),
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Recent trackers',
                style: TextStyle(color: t.textDim, fontSize: 11)),
            for (final d in recent.take(5))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.track_changes,
                    color: AppTheme.detector, size: 18),
                title: Text(d.macAddress.toUpperCase(),
                    style: TextStyle(color: t.textPrimary, fontSize: 13)),
                subtitle: Text('${d.rssi} dBm',
                    style: TextStyle(color: t.textDim, fontSize: 11)),
                onTap: () => ctrl.text = d.macAddress.toUpperCase(),
              ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.background),
            icon: const Icon(Icons.notifications_active),
            label: const Text('RING IT'),
            onPressed: () async {
              final mac = ctrl.text.trim();
              Navigator.pop(ctx);
              String msg;
              try {
                final ok =
                    await ref.read(bleManagerProvider).ringTracker(mac);
                msg = ok
                    ? 'Ringing $mac — listen for the sound'
                    : 'Not connected to a board';
              } catch (e) {
                msg = 'That does not look like a MAC address';
              }
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(msg)));
            },
          ),
        ],
      ),
    ),
  );
}
