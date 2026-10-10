import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/config/device_config.dart' show DetectionHistoryView;
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
        child: switch (view) {
          DetectionsView.history => DetectionHistoryView(
              onShowLive: () => ref.read(detectionsViewProvider.notifier).state = DetectionsView.live,
            ),
          _ => FeedScreen(
              onShowHistory: () => ref.read(detectionsViewProvider.notifier).state = DetectionsView.history,
            ),
        },
      ),
    );
  }
}
