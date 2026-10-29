// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/config/device_config.dart';
import 'package:oui_spy/features/detections/detections_screen.dart';
import 'package:oui_spy/features/engines/detector_screen.dart';
import 'package:oui_spy/features/engines/foxhunter_screen.dart';
import 'package:oui_spy/features/engines/skyspy_screen.dart';
import 'package:oui_spy/features/engines/unipwn_screen.dart';
import 'package:oui_spy/features/analysis/analysis_screen.dart';
import 'package:oui_spy/features/export/export_screen.dart';
import 'package:oui_spy/features/home/home_screen.dart';
import 'package:oui_spy/features/onboarding/scan_screen.dart';
import 'package:oui_spy/features/pcap/pcap_screen.dart';
import 'package:oui_spy/features/pcap/pcap_library_screen.dart';
import 'package:oui_spy/features/wardrive/wardrive_screen.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/core/notifications/live_activity_service.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:oui_spy/core/app_time.dart';
import 'package:oui_spy/theme/app_theme.dart';

final _shellNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/detections',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: DetectionsScreen(),
            ),
          ),
          GoRoute(
            path: '/wardrive',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: WardriveScreen(),
            ),
          ),
          GoRoute(
            path: '/config',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: DeviceConfigScreen(),
            ),
          ),
        ],
      ),
      // Settings opened from a screen outside the shell. Pushing '/config'
      // from there builds a second shell with the same navigator key, which
      // fails an assertion and leaves a blank screen.
      GoRoute(
        path: '/settings',
        builder: (context, state) => const DeviceConfigScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const ScanScreen(),
      ),
      GoRoute(
        path: '/engine/detector',
        builder: (context, state) => const DetectorScreen(),
      ),
      GoRoute(
        path: '/engine/foxhunter',
        builder: (context, state) => const FoxhunterScreen(),
      ),
      GoRoute(
        path: '/engine/skyspy',
        builder: (context, state) => const SkySpyScreen(),
      ),
      GoRoute(
        path: '/engine/unipwn',
        builder: (context, state) => const UnipwnScreen(),
      ),
      GoRoute(
        path: '/export',
        builder: (context, state) => const ExportScreen(),
      ),
      GoRoute(
        path: '/analysis',
        builder: (context, state) => const AnalysisScreen(),
      ),
      GoRoute(
        path: '/engine/pcap',
        builder: (context, state) => const PcapScreen(),
      ),
      GoRoute(
        path: '/pcap/library',
        builder: (context, state) => const PcapLibraryScreen(),
      ),
    ],
  );
});

class OuiSpyApp extends ConsumerStatefulWidget {
  const OuiSpyApp({super.key});

  @override
  ConsumerState<OuiSpyApp> createState() => _OuiSpyAppState();
}

class _OuiSpyAppState extends ConsumerState<OuiSpyApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.read(configMenuWantedProvider.notifier).state = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      ref.read(wardriveProvider).finalizeForShutdown();
      ref.read(bleManagerProvider).disconnectQuiet();
      ref.read(liveActivityServiceProvider).endAll();
      ref.read(notificationServiceProvider).cancelAll();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(bleManagerProvider).resyncOnResume();
      ref.read(notificationServiceProvider).refreshPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    ref.watch(use24HourTimeProvider); // loads AppTime.use24Hour at startup
    return MaterialApp.router(
      title: 'OUI-SNITCH',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        AppTheme.syncBrightness(context);
        return _GlobalPcapBannerOverlay(child: child ?? const SizedBox.shrink());
      },
    );
  }
}

class _GlobalPcapBannerOverlay extends ConsumerWidget {
  const _GlobalPcapBannerOverlay({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ble = ref.watch(bleManagerProvider);
    return StreamBuilder(
      stream: ble.pcapStats,
      initialData: ble.latestPcapStats,
      builder: (context, snap) {
        final s = snap.data;
        final showing = s != null && s.state == 1;
        return Stack(
          children: [
            Positioned.fill(child: child),
            if (showing)
              Positioned(
                left: 12, right: 12, bottom: kBottomNavigationBarHeight + 8,
                child: SafeArea(
                  top: false,
                  child: Material(
                    color: AppTheme.of(context).surfaceLight,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => ref.read(routerProvider).push('/engine/pcap'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.fiber_manual_record, color: AppTheme.error, size: 12),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                () {
                                  final nodeTag = s.sourceNodeId.isNotEmpty
                                      ? ' @${s.sourceNodeId}'
                                      : '';
                                  if (s.isAutoTriggered) {
                                    return 'AUTO-PCAP$nodeTag ${s.mode == 1 ? "BLE" : "WiFi"} · ${s.autoTriggerEngineName} ${s.autoTriggerMacStr} — ${(s.autoRemainingMs / 1000).ceil()}s left, ${_humanBytes(s.bytesWritten)}';
                                  }
                                  if (s.autoRemainingMs > 0) {
                                    return 'AUTO-PCAP$nodeTag ${s.mode == 1 ? "BLE" : "WiFi"} — ${(s.autoRemainingMs / 1000).ceil()}s left, ${_humanBytes(s.bytesWritten)}';
                                  }
                                  return 'PCAP ${s.mode == 1 ? "BLE" : "WiFi"} — ${s.uptimeMs ~/ 1000}s, ${_humanBytes(s.bytesWritten)}';
                                }(),
                                style: TextStyle(
                                  color: AppTheme.of(context).textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(Icons.open_in_new, color: AppTheme.of(context).textSecondary, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _humanBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)}MB';
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _routes = ['/home', '/detections', '/wardrive', '/config'];
  static const _configIndex = 3;

  void _onNavTap(int i) {
    final alreadyHere = _routes[i] == GoRouterState.of(context).uri.path;
    if (i == _configIndex && alreadyHere) {
      ref.read(configMenuWantedProvider.notifier).state = true;
    }
    if (!alreadyHere) {
      context.go(_routes[i]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final index = _routes.indexOf(location);
    return PopScope(
      // The shell routes are the back-stack root, so a system back here would
      // otherwise drop straight out of the app with no warning — easy to do by
      // accident mid-session and lose a running scan. Intercept it and confirm.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmExit(context);
        if (leave) await SystemNavigator.pop();
      },
      child: Scaffold(
      body: widget.child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.of(context).border, width: 0.5)),
        ),
        child: BottomNavigationBar(
        currentIndex: index < 0 ? 0 : index,
        onTap: _onNavTap,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt_outlined),
            activeIcon: Icon(Icons.list_alt),
            label: 'Log',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      )),
    ),
    );
  }

  Future<bool> _confirmExit(BuildContext context) async {
    final t = AppTheme.of(context);
    final wd = ref.read(wardriveProvider);
    // The board keeps scanning on its own; what closing the app actually costs
    // is the phone-side link. A running wardrive session is the case worth a
    // sharper warning, because its GPS track comes from the phone.
    final body = wd.isActive
        ? 'A wardrive session is running. Closing the app ends its GPS track '
          'and stops recording to it. The board keeps scanning on its own.'
        : 'The board keeps scanning on its own, but closing the app stops live '
          'alerts and the live view on your phone.';
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Leave OUI-SNITCH?',
            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w700)),
        content: Text(
          body,
          style: TextStyle(color: t.textDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Stay', style: TextStyle(color: t.textDim)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }
}
