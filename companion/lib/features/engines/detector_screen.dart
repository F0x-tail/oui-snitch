import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/engine_control.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/detections/detections_screen.dart';
import 'package:oui_spy/features/engines/detection_rules.dart';
import 'package:oui_spy/theme/app_theme.dart';

class DetectorScreen extends ConsumerWidget {
  const DetectorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);
    final detections = state.detectionsForEngine(Engine.detector);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: const Text('DETECTOR'),
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
          const WatchlistPanel(),
          const Divider(height: 1),
          const SignaturesPanel(),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.history, color: AppTheme.detector),
            title: Text(
              'DETECTOR HISTORY',
              style: TextStyle(color: t.textPrimary, fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${detections.length} this session · filters, map, export',
              style: TextStyle(color: t.textDim, fontSize: 11),
            ),
            trailing: Icon(Icons.chevron_right, color: t.textDim),
            onTap: () {
              ref.read(historyFilterRequestProvider.notifier).state = 'detector';
              ref.read(detectionsViewProvider.notifier).state = DetectionsView.history;
              context.go('/detections');
            },
          ),
        ],
      ),
    );
  }
}
