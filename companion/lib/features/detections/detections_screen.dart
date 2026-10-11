import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/config/device_config.dart' show DetectionHistoryView;
import 'package:oui_spy/features/devices/devices_screen.dart';
import 'package:oui_spy/features/feed/feed_screen.dart';
import 'package:oui_spy/theme/app_theme.dart';

enum DetectionsView { live, devices, history }

final detectionsViewProvider = StateProvider<DetectionsView>((ref) => DetectionsView.live);

class DetectionsScreen extends ConsumerWidget {
  const DetectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final view = ref.watch(detectionsViewProvider);
    ref.listen<String?>(historyFilterRequestProvider, (_, req) {
      if (req != null) ref.read(detectionsViewProvider.notifier).state = DetectionsView.history;
    });
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _SegmentBar(current: view),
            Expanded(
              child: switch (view) {
                DetectionsView.history => DetectionHistoryView(
                    onShowLive: () => ref.read(detectionsViewProvider.notifier).state = DetectionsView.live,
                  ),
                DetectionsView.devices => const DevicesScreen(embedded: true),
                DetectionsView.live => FeedScreen(
                    onShowHistory: () => ref.read(detectionsViewProvider.notifier).state = DetectionsView.history,
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentBar extends ConsumerWidget {
  const _SegmentBar({required this.current});
  final DetectionsView current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border, width: 0.5)),
      ),
      child: SegmentedButton<DetectionsView>(
        segments: const [
          ButtonSegment(value: DetectionsView.live, label: Text('LIVE')),
          ButtonSegment(value: DetectionsView.devices, label: Text('DEVICES')),
          ButtonSegment(value: DetectionsView.history, label: Text('HISTORY')),
        ],
        selected: {current},
        onSelectionChanged: (v) => ref.read(detectionsViewProvider.notifier).state = v.first,
        showSelectedIcon: false,
      ),
    );
  }
}
