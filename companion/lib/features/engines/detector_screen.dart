import 'package:flutter/cupertino.dart';
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
import 'package:oui_spy/widgets/ios.dart';

class DetectorScreen extends ConsumerWidget {
  const DetectorScreen({super.key});

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Clear detector results?'),
        content: const Text('Removes this session\'s detector results from the live list. Saved history is kept.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) ref.read(appStateProvider).clearDetectionsForEngine(Engine.detector);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final state = ref.watch(appStateProvider);
    final detections = state.detectionsForEngine(Engine.detector);
    final watchlistHits = detections
        .where((d) => d.method == 'ble_watchlist' || d.method == 'wifi_watchlist' || d.method == 'name_match')
        .length;
    final active = state.isEngineActive(Engine.detector);

    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: 'Detector',
        leading: CupertinoNavigationBarBackButton(color: AppTheme.accent, onPressed: () => context.canPop() ? context.pop() : context.go('/home')),
        actions: [
          IosNavButton(icon: CupertinoIcons.trash, tooltip: 'Clear detections', onPressed: detections.isEmpty ? null : () => _confirmClear(context, ref)),
        ],
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(
              footer: 'Matches nearby devices against your watchlist and the built-in signatures.',
              children: [
                IosRow(
                  leading: const IosIcon(CupertinoIcons.scope, AppTheme.detector),
                  title: 'Detector',
                  subtitle: Text(active ? 'Scanning' : 'Off'),
                  trailing: CupertinoSwitch(
                    value: active,
                    activeTrackColor: AppTheme.detector,
                    onChanged: (on) => setEngineEnabled(ref, Engine.detector, on),
                  ),
                ),
                IosRow(
                  leading: const IosIcon(CupertinoIcons.clock_fill, AppTheme.accent),
                  title: 'Detector history',
                  subtitle: Text('$watchlistHits watchlist, ${detections.length - watchlistHits} signature this session'),
                  chevron: true,
                  onTap: () {
                    ref.read(historyFilterRequestProvider.notifier).state = 'detector';
                    ref.read(detectionsViewProvider.notifier).state = DetectionsView.history;
                    context.go('/detections');
                  },
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: WatchlistPanel()),
          const SliverToBoxAdapter(child: SignaturesPanel()),
        ],
      ),
    );
  }
}
