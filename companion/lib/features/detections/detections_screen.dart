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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<DetectionsView>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: DetectionsView.live, label: Text('LIVE')),
                    ButtonSegment(value: DetectionsView.devices, label: Text('DEVICES')),
                    ButtonSegment(value: DetectionsView.history, label: Text('HISTORY')),
                  ],
                  selected: {view},
                  onSelectionChanged: (s) => ref.read(detectionsViewProvider.notifier).state = s.first,
                ),
              ),
            ),
            Expanded(
              child: switch (view) {
                DetectionsView.live => const FeedScreen(),
                DetectionsView.devices => const DevicesScreen(),
                DetectionsView.history => const DetectionHistoryView(),
              },
            ),
          ],
        ),
      ),
    );
  }
}
