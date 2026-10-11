import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/prefs.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/ble/gatt_uuids.dart';
import 'package:oui_spy/core/db/app_database.dart' hide Detection;
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/ota/ota_service.dart';
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/core/ignore_list_state.dart';
import 'package:oui_spy/features/config/widgets/config_widgets.dart';
import 'package:oui_spy/features/config/config_menu_state.dart';
import 'package:oui_spy/features/config/ota_progress_stepper.dart';
import 'package:oui_spy/features/config/alert_sounds_screen.dart';
import 'package:oui_spy/features/engines/detection_rules.dart';
import 'package:oui_spy/features/export/export_screen.dart';
import 'package:oui_spy/features/pcap/pcap_library_screen.dart';
import 'package:oui_spy/features/notifications/notification_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/core/wigle/wigle_api.dart';
import 'package:oui_spy/core/wigle/wigle_provider.dart';
import 'package:oui_spy/core/wdgwars/wdgwars_provider.dart';
import 'package:oui_spy/core/app_time.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/theme/app_theme.dart';

part 'config_wardrive_settings.dart';
part 'config_wardrive_tab.dart';
part 'config_ignore_tab.dart';
part 'config_ota.dart';
part 'config_misc.dart';

String boardDisplayName(String? board) => switch (board) {
      'xiao_s3' => 'XIAO ESP32-S3',
      's3_devkitc' => 'ESP32-S3 DevKitC',
      'xiao_c5' => 'XIAO ESP32-C5 (2.4+5GHz)',
      'tdongle_s3' => 'LilyGO T-Dongle-S3',
      'tdongle_c5' => 'LilyGO T-Dongle-C5 (2.4+5GHz)',
      'stickc' => 'M5StickC',
      'stickc_plus' => 'M5StickC PLUS',
      'stickc_plus2' => 'M5StickC PLUS2',
      'xiao_c3' => 'XIAO ESP32-C3',
      'wroom' => 'ESP32 WROOM',
      null || '' => '—',
      final b => b,
    };

class DeviceConfigScreen extends ConsumerStatefulWidget {
  const DeviceConfigScreen({super.key});

  @override
  ConsumerState<DeviceConfigScreen> createState() => _DeviceConfigScreenState();
}

enum _Page {
  app('App', CupertinoIcons.slider_horizontal_3, AppTheme.accent, 'Appearance, units, connection'),
  scanning('Scanning', CupertinoIcons.dot_radiowaves_left_right, AppTheme.wardrive, 'Channels, dwell, re-log thresholds'),
  watchlist('Watchlist', CupertinoIcons.eye_fill, AppTheme.detector, 'MACs, OUIs and UUIDs to alert on'),
  signatures('Threat signatures', CupertinoIcons.shield_lefthalf_fill, AppTheme.detector, 'Trackers, Flipper, deauth, Axon and more'),
  ignore('Ignore list', CupertinoIcons.nosign, AppTheme.gpsNone, 'Never log or alert on these'),
  alerts('Notifications', CupertinoIcons.bell_fill, AppTheme.error, 'What alerts you and how'),
  hardware('Hardware', CupertinoIcons.memories, AppTheme.warning, 'Buzzer, LED, GPS, offline scanning'),
  mesh('Mesh', CupertinoIcons.circle_grid_hex_fill, AppTheme.flockBle, 'Multi-node coordination'),
  firmware('Firmware', CupertinoIcons.arrow_down_circle_fill, AppTheme.success, 'Version and over-the-air updates'),
  accounts('Wardrive accounts', CupertinoIcons.globe, AppTheme.wigle, 'WiGLE and WDGWars'),
  pcaps('Packet captures', CupertinoIcons.doc_on_doc_fill, AppTheme.skySpy, 'Saved PCAP files'),
  export('Export and backup', CupertinoIcons.square_arrow_up_fill, AppTheme.accent, 'CSV, KML, database backup');

  const _Page(this.title, this.icon, this.color, this.summary);
  final String title;
  final IconData icon;
  final Color color;
  final String summary;
}

const _groups = <(String, List<_Page>)>[
  ('App', [_Page.app]),
  ('Detection', [_Page.scanning, _Page.watchlist, _Page.signatures, _Page.ignore, _Page.alerts]),
  ('Node', [_Page.hardware, _Page.mesh, _Page.firmware]),
  ('Data', [_Page.accounts, _Page.pcaps, _Page.export]),
];

class _DeviceConfigScreenState extends ConsumerState<DeviceConfigScreen> {
  _Page? _page;

  bool _flockExtendedOui = false;
  bool _flockAllowOuiOnly = false;
  bool _offlineScanEnabled = false;
  bool _offlineGpsTag = false;
  bool _buzzerEnabled = true;
  int _buzzerVolume = 100;
  bool _ledEnabled = true;
  int _neopixelBrightness = 50;
  int _cooldownMs = 5000;
  int _heartbeatMs = 30000;
  int _rediscoverMs = 30000;
  int _hbActiveMs = 3000;
  bool _loading = true;

  // Device info
  String _fwVersion = '--';
  String _nodeId = '--';
  String _heapFree = '--';

  StreamSubscription<NodeConnectionState>? _connStateSub;
  StreamSubscription<HwGpsState>? _hwGpsSub;
  HwGpsState _hwGps = const HwGpsState(
      active: false, satellites: 0, source: GpsSource.phone, inUse: false);

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(sharedPreferencesProvider);
    _page = _pageForRequest(ref.read(configSectionRequestProvider));
    if (_page != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(configSectionRequestProvider.notifier).state = null);
    }
    _offlineGpsTag = prefs.getBool('offlineGpsTagEnabled') ?? false;
    _neopixelBrightness = prefs.getInt('neopixelBrightness') ?? _neopixelBrightness;
    _readDeviceConfig();
    final ble = ref.read(bleManagerProvider);
    _connStateSub = ble.connectionState.listen((s) {
      if (s == NodeConnectionState.ready) {
        DebugLog.log('CONFIG: reconnect detected, re-reading device info');
        _readDeviceConfig();
      }
    });
    final gps = ref.read(gpsProvider);
    _hwGps = gps.hwGps;
    _hwGpsSub = gps.hwGpsStream.listen((s) {
      if (mounted) setState(() => _hwGps = s);
    });
    gps.refreshHwGps();
  }

  static _Page? _pageForRequest(String? r) => switch (r) {
        'NODE' => _Page.mesh,
        'DATA' => _Page.accounts,
        null => null,
        _ => _Page.values.where((p) => p.name.toUpperCase() == r).firstOrNull,
      };

  @override
  void dispose() {
    _connStateSub?.cancel();
    _hwGpsSub?.cancel();
    _ssidController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _readDeviceConfig() async {
    final ble = ref.read(bleManagerProvider);
    if (!ble.isConnected) {
      setState(() => _loading = false);
      return;
    }

    try {
      // Read hardware config
      final hwChar = ble.getCharacteristic(GattUuids.hardwareConfig);
      if (hwChar != null) {
        final hw = await hwChar.read();
        if (!mounted) return;
        if (hw.length >= 3) {
          setState(() {
            _buzzerEnabled = hw[0] != 0;
            _ledEnabled = hw[1] != 0;
            _neopixelBrightness = hw[2];
            ref.read(sharedPreferencesProvider)
                .setInt('neopixelBrightness', hw[2]);
            _buzzerVolume = hw.length >= 4 ? hw[3] : 100;
            _flockExtendedOui = hw.length >= 5 && hw[4] != 0;
            _flockAllowOuiOnly = hw.length >= 7 && hw[6] != 0;
            _offlineScanEnabled = hw.length > 5 && hw[5] != 0;
          });
          ref.read(sharedPreferencesProvider)
              .setBool('offlineScanEnabled', _offlineScanEnabled);
          DebugLog.log('CONFIG: hw read: buzzer=$_buzzerEnabled vol=$_buzzerVolume led=$_ledEnabled neo=$_neopixelBrightness');
        }
      }

      // Read alert config
      final alertChar = ble.getCharacteristic(GattUuids.alertConfig);
      if (alertChar != null) {
        final al = await alertChar.read();
        if (!mounted) return;
        if (al.length >= 8) {
          setState(() {
            _cooldownMs = al[0] | (al[1] << 8);
            _heartbeatMs = al[2] | (al[3] << 8);
            _rediscoverMs = al[4] | (al[5] << 8);
            _hbActiveMs = al[6] | (al[7] << 8);
          });
          DebugLog.log('CONFIG: alert read: cool=$_cooldownMs hb=$_heartbeatMs');
        }
      }

      // Read device info
      final infoChar = ble.getCharacteristic(GattUuids.deviceInfo);
      if (infoChar != null) {
        final info = await infoChar.read();
        if (!mounted) return;
        if (info.isNotEmpty) {
          final nullIdx = info.indexOf(0);
          _fwVersion = String.fromCharCodes(
              nullIdx >= 0 ? info.sublist(0, nullIdx) : info.take(16).toList());
          if (nullIdx >= 0 && nullIdx + 1 < info.length) {
            final rest = info.sublist(nullIdx + 1);
            final nullIdx2 = rest.indexOf(0);
            _nodeId = String.fromCharCodes(
                nullIdx2 >= 0 ? rest.sublist(0, nullIdx2) : rest.take(16).toList());
          }
          final segs = <List<int>>[];
          int segStart = 0;
          for (int i = 0; i < info.length; i++) {
            if (info[i] == 0) { segs.add(info.sublist(segStart, i)); segStart = i + 1; }
          }
          if (segStart < info.length) segs.add(info.sublist(segStart));
          if (segs.length >= 5) {
            final bytes = int.tryParse(String.fromCharCodes(segs[4]).trim());
            if (bytes != null) _heapFree = '${(bytes / 1024).round()} KB';
          }
          DebugLog.log('CONFIG: fw=$_fwVersion node=$_nodeId heap=$_heapFree');
        }
      }
    } catch (e) {
      DebugLog.log('CONFIG: read error: $e');
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Widget _pageBody(_Page p) => switch (p) {
        _Page.app => _buildAppTab(),
        _Page.scanning => _buildScanTab(),
        _Page.watchlist => const SingleChildScrollView(child: WatchlistPanel()),
        _Page.signatures => const SingleChildScrollView(child: SignaturesPanel()),
        _Page.ignore => const _IgnoreListTab(),
        _Page.alerts => _buildAlertsTab(),
        _Page.hardware => _buildHardwareTab(),
        _Page.mesh => _buildMeshTab(),
        _Page.firmware => _buildFirmwareTab(),
        _Page.accounts => const _WardriveConfigTab(),
        _Page.pcaps => const PcapLibraryScreen(embedded: true),
        _Page.export => _buildExportTab(),
      };

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    ref.listen<String?>(configSectionRequestProvider, (_, r) {
      final p = _pageForRequest(r);
      if (p == null) return;
      setState(() => _page = p);
      ref.read(configSectionRequestProvider.notifier).state = null;
    });
    final page = _page;
    if (page == null) {
      final connected = ref.watch(appStateProvider).isConnected;
      return IosPage(
        title: 'Settings',
        actions: [if (_loading && connected) const Padding(padding: EdgeInsets.only(right: 12), child: CupertinoActivityIndicator())],
        slivers: [
          for (final (name, pages) in _groups)
            SliverToBoxAdapter(
              child: IosSection(
                header: name,
                footer: name == 'Node' && !connected ? 'Connect a node to change its settings.' : null,
                children: [
                  for (final p in pages)
                    IosRow(
                      leading: IosIcon(p.icon, p.color),
                      title: p.title,
                      subtitle: Text(p.summary),
                      chevron: true,
                      onTap: () => setState(() => _page = p),
                    ),
                ],
              ),
            ),
        ],
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _page = null);
      },
      child: Scaffold(
        backgroundColor: t.background,
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Column(
            children: [
              CupertinoNavigationBar(
                backgroundColor: t.background.withValues(alpha: 0.92),
                border: Border(bottom: BorderSide(color: t.border, width: 0.5)),
                transitionBetweenRoutes: false,
                automaticallyImplyLeading: false,
                leading: CupertinoNavigationBarBackButton(
                  color: AppTheme.accent,
                  onPressed: () => setState(() => _page = null),
                ),
                middle: Text(page.title, style: TextStyle(color: t.textPrimary)),
              ),
              Expanded(child: _pageBody(page)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppTab() {
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;
    final unitSystem = ref.watch(unitSystemProvider);
    final isImperial = unitSystem == UnitSystem.imperial;
    final use24Hour = ref.watch(use24HourTimeProvider);
    final t = AppTheme.of(context);

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        IosSection(header: 'Appearance', children: [
          ConfigToggleRow(
            icon: isDark ? Icons.dark_mode : Icons.light_mode,
            label: 'Dark mode',
            color: AppTheme.accent,
            value: isDark,
            onChanged: (v) => ref.read(themeModeProvider.notifier).setMode(v ? ThemeMode.dark : ThemeMode.light),
          ),
        ]),
        IosSection(header: 'Units', children: [
          ConfigToggleRow(
            icon: isImperial ? Icons.straighten : Icons.square_foot,
            label: 'Imperial units',
            subtitle: isImperial ? 'Miles, mph, feet' : 'Kilometers, km/h, meters',
            color: AppTheme.accent,
            value: isImperial,
            onChanged: (v) => ref.read(unitSystemProvider.notifier).setSystem(v ? UnitSystem.imperial : UnitSystem.metric),
          ),
          ConfigToggleRow(
            icon: Icons.schedule,
            label: '24-hour time',
            subtitle: use24Hour ? 'Shown as 20:13' : 'Shown as 8:13 PM',
            color: AppTheme.accent,
            value: use24Hour,
            onChanged: (v) => ref.read(use24HourTimeProvider.notifier).set(v),
          ),
        ]),
        const IosSection(header: 'Connection', children: [_AutoConnectToggle()]),
        IosSection(header: 'About', children: [
          const _VersionRow(),
          ConfigActionRow(
            icon: Icons.code,
            label: 'Source code',
            subtitle: 'github.com/lukeswitz/oui-spy-unified-blue',
            onTap: () => _launchUrl('https://github.com/lukeswitz/oui-spy-unified-blue'),
            trailing: Icon(CupertinoIcons.doc_on_clipboard, size: 18, color: t.textDim),
          ),
        ]),
      ],
    );
  }

  Widget _buildScanTab() {
    final isC5 = ref.watch(bleManagerProvider).isC5;
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        const IosSection(
          header: 'Re-log after signal changes by',
          footer: 'Smaller numbers log more rows during a wardrive.',
          children: [_WardriveRssiRow(isBle: false), _WardriveRssiRow(isBle: true)],
        ),
        const _ScanTimingSliders(),
        if (isC5)
          const IosSection(
            header: 'Wi-Fi band',
            footer: '5 GHz sweeps UNII-1 and UNII-3. Applies to every Wi-Fi engine.',
            children: [Padding(padding: EdgeInsets.all(12), child: _WifiBandSelector())],
          ),
        const _ChannelRangeSlider(),
      ],
    );
  }

  Widget _buildExportTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: const [ExportSections(), _OuiDatabaseSection()],
    );
  }

  Future<void> _launchUrl(String url) async {
    // url_launcher not added — just copy to clipboard as fallback
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied to clipboard')),
      );
    }
  }

  Widget _buildDisconnectedPlaceholder() {
    final t = AppTheme.of(context);
    final ota = ref.read(otaServiceProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: ota.otaActive,
      builder: (context, otaActive, _) {
        if (otaActive) return _buildOtaReconnecting(t);
        return SingleChildScrollView(
          child: IosEmpty(
            icon: CupertinoIcons.bluetooth,
            title: 'No node connected',
            message: 'These settings live on the node. Connect one to change them.',
            action: CupertinoButton.filled(onPressed: () => context.push('/onboarding'), child: const Text('Connect')),
          ),
        );
      },
    );
  }

  Widget _buildOtaReconnecting(ResolvedTheme t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.system_update_alt,
                  size: 30, color: AppTheme.accent),
            ),
            const SizedBox(height: 14),
            Text('UPDATING FIRMWARE',
                style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2)),
            const SizedBox(height: 6),
            Text(
              'Device is applying the update and rebooting. It reconnects on '
              'its own — keep it powered.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textDim, fontSize: 11),
            ),
            const SizedBox(height: 18),
            const OtaProgressStepper(
              model: OtaStepperModel(
                  activeIndex: 4, detail: 'Rebooting + reconnecting…'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gpsSourceRow(
      GpsSource source, IconData icon, String label, String subtitle) {
    final selected = _hwGps.source == source;
    return ConfigActionRow(
      icon: icon,
      label: label,
      subtitle: subtitle,
      color: selected ? AppTheme.accent : AppTheme.textDim,
      onTap: () => ref.read(gpsProvider).setSource(source),
      trailing: selected ? const Icon(CupertinoIcons.check_mark, size: 20, color: AppTheme.accent) : const SizedBox(width: 20),
    );
  }

  Widget _buildHardwareTab() {
    final appState = ref.watch(appStateProvider);
    if (!appState.isConnected) return _buildDisconnectedPlaceholder();
    final hasBuzzer = !const {'tdongle_s3', 'tdongle_c5', 'stickc'}
        .contains(ref.read(bleManagerProvider).board);

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        if (hasBuzzer)
          IosSection(header: 'Sound', children: [
            ConfigToggleRow(
              icon: Icons.volume_up,
              label: 'Buzzer',
              subtitle: 'Beep on detections',
              color: AppTheme.warning,
              value: _buzzerEnabled,
              onChanged: (v) {
                setState(() => _buzzerEnabled = v);
                _writeHardwareConfig();
              },
            ),
            if (_buzzerEnabled)
              ConfigSliderRow(
                icon: Icons.graphic_eq,
                label: 'Volume',
                valueLabel: '$_buzzerVolume',
                min: 1,
                max: 255,
                divisions: 254,
                value: _buzzerVolume.toDouble(),
                color: AppTheme.warning,
                onChanged: (v) {
                  setState(() => _buzzerVolume = v.round());
                  _writeHardwareConfig();
                },
              ),
            if (_buzzerEnabled)
              ConfigActionRow(
                icon: Icons.music_note,
                label: 'Alert sounds',
                subtitle: 'Compose melodies and assign them to detections',
                color: AppTheme.warning,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AlertSoundsScreen())),
              ),
          ]),
        IosSection(header: 'Lights', children: [
          ConfigToggleRow(
            icon: Icons.lightbulb,
            label: 'Status LED',
            subtitle: 'Power and activity indicator',
            color: AppTheme.success,
            value: _ledEnabled,
            onChanged: (v) {
              setState(() => _ledEnabled = v);
              _writeHardwareConfig();
            },
          ),
          ConfigSliderRow(
            icon: Icons.brightness_6,
            label: 'NeoPixel brightness',
            valueLabel: '$_neopixelBrightness',
            min: 0,
            max: 255,
            divisions: 255,
            value: _neopixelBrightness.toDouble(),
            color: AppTheme.detector,
            onChanged: (v) {
              setState(() => _neopixelBrightness = v.round());
              _writeHardwareConfig();
            },
          ),
        ]),
        IosSection(header: 'Location', children: [
          ConfigInfoRow(
            icon: _hwGps.active ? Icons.satellite_alt : Icons.satellite_alt_outlined,
            label: 'GPS module',
            value: _hwGps.active ? 'Fix, ${_hwGps.satellites} satellites' : 'No fix',
            color: _hwGps.active ? AppTheme.success : AppTheme.error,
            monospace: false,
          ),
          ConfigInfoRow(
            icon: Icons.edit_location_alt,
            label: 'Recording from',
            value: _hwGps.inUse ? 'GPS module' : (_hwGps.fallback ? 'Phone (fallback)' : 'Phone'),
            color: _hwGps.fallback ? AppTheme.warning : AppTheme.accent,
            monospace: false,
          ),
          _gpsSourceRow(GpsSource.phone, Icons.smartphone, 'Use phone location', 'The node is never asked for GPS.'),
          _gpsSourceRow(GpsSource.hardware, Icons.memory, 'Use GPS module', 'Falls back to the phone whenever the module has no fix.'),
        ]),
        IosSection(header: 'Flock detection', children: [
          ConfigToggleRow(
            icon: Icons.lan,
            label: 'Extended vendor list',
            subtitle: 'Twice as many Flock vendor prefixes. More false positives.',
            color: AppTheme.error,
            value: _flockExtendedOui,
            onChanged: (v) {
              setState(() => _flockExtendedOui = v);
              _writeHardwareConfig();
            },
          ),
          ConfigToggleRow(
            icon: Icons.fingerprint,
            label: 'Report vendor-only Wi-Fi hits',
            subtitle: 'Report a Wi-Fi device on a Flock vendor match alone, with no probe or other evidence. More hits, more false positives.',
            color: AppTheme.error,
            value: _flockAllowOuiOnly,
            onChanged: (v) {
              setState(() => _flockAllowOuiOnly = v);
              _writeHardwareConfig();
            },
          ),
        ]),
        IosSection(
          header: 'Offline scanning',
          footer: 'Experimental. The node keeps scanning while the app is closed and detections import on reconnect.',
          children: [
            ConfigToggleRow(
              icon: Icons.cloud_off,
              label: 'Scan while disconnected',
              color: AppTheme.accent,
              value: _offlineScanEnabled,
              onChanged: (v) {
                setState(() => _offlineScanEnabled = v);
                _writeHardwareConfig();
              },
            ),
            if (_offlineScanEnabled)
              ConfigToggleRow(
                icon: Icons.my_location,
                label: 'Tag with last phone location',
                subtitle: 'Approximate. Uses where the phone last was.',
                color: AppTheme.accent,
                value: _offlineGpsTag,
                onChanged: (v) {
                  setState(() => _offlineGpsTag = v);
                  ref.read(sharedPreferencesProvider).setBool('offlineGpsTagEnabled', v);
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildAlertsTab() {
    final appState = ref.watch(appStateProvider);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const NotificationSettingsBody(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
        ),
        if (appState.isConnected)
          IosSection(header: 'Node alert timing', children: [
            ConfigNumberField(
              icon: Icons.hourglass_empty,
              label: 'Cooldown', suffix: 'ms', value: _cooldownMs,
              onChanged: (v) { setState(() => _cooldownMs = v); _writeAlertConfig(); },
            ),
            ConfigNumberField(
              icon: Icons.favorite,
              label: 'Heartbeat', suffix: 'ms', value: _heartbeatMs,
              onChanged: (v) { setState(() => _heartbeatMs = v); _writeAlertConfig(); },
            ),
            ConfigNumberField(
              icon: Icons.refresh,
              label: 'Rediscover', suffix: 'ms', value: _rediscoverMs,
              onChanged: (v) { setState(() => _rediscoverMs = v); _writeAlertConfig(); },
            ),
            ConfigNumberField(
              icon: Icons.bolt,
              label: 'Active heartbeat', suffix: 'ms', value: _hbActiveMs,
              onChanged: (v) { setState(() => _hbActiveMs = v); _writeAlertConfig(); },
            ),
          ]),
      ],
    );
  }

  final _ssidController = TextEditingController();
  final _passController = TextEditingController();

  Future<void> _wifiDisconnect() async {
    try {
      await ref.read(bleManagerProvider).wifiDisconnect();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WiFi disconnected'), backgroundColor: AppTheme.warning),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: AppTheme.error),
      );
    }
  }

  Future<void> _confirmWipeWifi() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Wipe WiFi credentials?'),
        content: const Text(
          'Device will disconnect from WiFi and forget SSID + password. '
          'You will need to re-enter them to use WiFi OTA again.',
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Wipe')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(bleManagerProvider).wifiWipeCreds();
      _ssidController.clear();
      _passController.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WiFi credentials wiped'), backgroundColor: AppTheme.error),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: AppTheme.error),
      );
    }
  }

  Future<void> _writeWifiConfig() async {
    final ssid = _ssidController.text.trim();
    final pass = _passController.text;
    if (ssid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SSID required'), backgroundColor: AppTheme.warning),
      );
      return;
    }
    final ble = ref.read(bleManagerProvider);
    if (ble.wifiConfig == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Firmware too old — no WiFi config characteristic. Flash latest via webflasher.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    try {
      await ble.writeWifiConfig(ssid, pass);
      DebugLog.log('CONFIG: WiFi creds pushed: $ssid');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved. Connecting to AP (up to 20s)...'),
          backgroundColor: AppTheme.success,
        ),
      );
      // Poll the live status — firmware brings up STA on save.
      for (int i = 0; i < 12; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final r = await ble.readWifiConfig();
        DebugLog.log('CONFIG: WiFi poll ${i+1}: connected=${r.connected} ssid=${r.ssid} ip=${r.ip}');
        if (r.connected) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Connected: ${r.ssid} · ${r.ip} · ${r.rssi}dBm'),
              backgroundColor: AppTheme.success,
            ),
          );
          return;
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved, but could not connect — verify creds/range'),
          backgroundColor: AppTheme.warning,
        ),
      );
    } catch (e) {
      DebugLog.log('CONFIG: WiFi config write failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: AppTheme.error),
      );
    }
  }

  Widget _buildMeshTab() {
    final appState = ref.watch(appStateProvider);
    if (!appState.isConnected) return _buildDisconnectedPlaceholder();
    final t = AppTheme.of(context);
    final modeEnc = appState.meshEnabled && appState.meshEncryption;
    final modePlain = appState.meshEnabled && !appState.meshEncryption;
    final modeOff = !appState.meshEnabled;
    final maxPeers = modeEnc ? 6 : (modePlain ? 12 : 0);
    final keyHex = appState.meshKeyFingerprint;

    final heard = appState.liveKnownNodes.where((n) => n.isNotEmpty && n != appState.nodeId).length;
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        IosSection(
          header: 'Mode',
          footer: 'ESP-NOW allows 6 encrypted or 12 unencrypted peers. Broadcast skips the peer table.',
          children: [
            _MeshModeTile(
              label: 'Off',
              subtitle: 'Single node',
              selected: modeOff,
              onTap: () => appState.disableMesh(),
            ),
            _MeshModeTile(
              label: 'Broadcast',
              subtitle: 'Unencrypted. Any number of nodes hear every packet on channel 1.',
              selected: modePlain,
              onTap: () => appState.enableMesh(encryption: false, peerMacs: const []),
            ),
            _MeshModeTile(
              label: 'Encrypted',
              subtitle: 'AES-256-GCM with a shared key. Up to 6 peers.',
              selected: modeEnc,
              onTap: () async {
                if (appState.meshKey == null) await appState.generateMeshKey();
                await appState.enableMesh(encryption: true, peerMacs: const []);
              },
            ),
          ],
        ),
        IosSection(header: 'Status', children: [
          ConfigInfoRow(icon: Icons.swap_vert, label: 'Sent / received', value: '${appState.meshTxCount} / ${appState.meshRxCount}', color: t.textDim),
          ConfigInfoRow(icon: Icons.group, label: 'Peer slots used', value: modeOff ? 'Off' : '$heard / $maxPeers'),
          ConfigInfoRow(icon: Icons.sensors, label: 'Nodes heard', value: '$heard'),
        ]),
        if (modeEnc)
          IosSection(header: 'Key', children: [
            ConfigInfoRow(icon: Icons.key, label: 'Fingerprint', value: keyHex.isEmpty ? 'None' : keyHex),
            ConfigActionRow(
              icon: Icons.autorenew,
              label: 'Generate new key',
              subtitle: 'Rotates the shared mesh key on this manager',
              onTap: () async {
                await appState.generateMeshKey();
                await appState.enableMesh(encryption: true, peerMacs: const []);
              },
            ),
          ]),
        ..._buildNodeManageRows(appState),
      ],
    );
  }

  List<Widget> _buildNodeManageRows(AppState appState) {
    final perNode = appState.detectionsPerSourceNode;
    final live = appState.liveKnownNodes;
    final all = <String>{...appState.knownNodes, ...live};
    if (appState.nodeId.isEmpty && !appState.isConnected) all.add('LOCAL');
    if (all.isEmpty) {
      return const [
        IosSection(header: 'Nodes', children: [IosRow(title: 'No nodes heard yet')]),
      ];
    }
    int sortFn(String a, String b) {
      if (a == 'LOCAL') return -1;
      if (b == 'LOCAL') return 1;
      if (a == appState.nodeId) return -1;
      if (b == appState.nodeId) return 1;
      return a.compareTo(b);
    }
    final liveIds = all.where((id) => live.contains(id) || id == appState.nodeId).toList()
      ..sort(sortFn);
    final offlineIds = all.where((id) => !live.contains(id) && id != appState.nodeId).toList()
      ..sort(sortFn);
    Widget row(String id, {required bool online}) {
      final dets = perNode[id] ?? 0;
      final label = appState.labelForNode(id);
      final hasCustom = appState.nodeLabels.containsKey(id);
      final isSelf = id == appState.nodeId && id != 'LOCAL';
      final parts = <String>[
        if (hasCustom) id,
        if (isSelf) 'This device',
        if (appState.nodeBoard(id) != null) boardDisplayName(appState.nodeBoard(id)),
        '$dets detections',
      ];
      return ConfigActionRow(
        icon: isSelf ? Icons.smartphone : Icons.memory,
        color: online ? AppTheme.success : AppTheme.textDim,
        label: label,
        subtitle: parts.join(' · '),
        onTap: () => _renameNodeDialog(appState, id),
      );
    }
    return [
      if (liveIds.isNotEmpty)
        IosSection(
          header: 'Online nodes',
          footer: 'Tap a node to rename or forget it.',
          children: [for (final id in liveIds) row(id, online: true)],
        ),
      if (offlineIds.isNotEmpty)
        IosSection(header: 'Offline nodes', children: [for (final id in offlineIds) row(id, online: false)]),
    ];
  }

  Future<void> _renameNodeDialog(AppState appState, String id) async {
    final controller = TextEditingController(text: appState.nodeLabels[id] ?? '');
    final result = await showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Rename $id'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: CupertinoTextField(
            controller: controller,
            autofocus: true,
            maxLength: 32,
            placeholder: 'Custom label (blank = reset)',
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          if (id != 'LOCAL' && id != appState.nodeId)
            CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, '__forget__'), child: const Text('Forget')),
          if (appState.nodeLabels.containsKey(id))
            CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Clear')),
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancel')),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    if (result == '__forget__') {
      appState.forgetNode(id);
      return;
    }
    appState.setNodeLabel(id, result.trim());
  }

  Widget _buildFirmwareTab() {
    final appState = ref.watch(appStateProvider);
    if (!appState.isConnected) return _buildDisconnectedPlaceholder();
    final isMgr = ref.read(bleManagerProvider).isManagerConnected;
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        IosSection(header: isMgr ? 'Manager' : 'Node', children: [
          ConfigInfoRow(icon: Icons.numbers, label: 'Firmware', value: _fwVersion),
          ConfigInfoRow(icon: Icons.developer_board, label: 'Board', value: boardDisplayName(ref.read(bleManagerProvider).board), monospace: false),
          ConfigInfoRow(icon: Icons.fingerprint, label: isMgr ? 'Manager ID' : 'Node ID', value: _nodeId),
          ConfigInfoRow(icon: Icons.memory, label: 'Free memory', value: _heapFree),
        ]),
        IosSection(
          header: 'Wi-Fi network',
          footer: 'The node joins this network to download firmware updates.',
          children: [
            _WifiStatusPanel(),
            _WifiEnableToggle(),
            ConfigTextField(icon: Icons.wifi, label: 'Network name', controller: _ssidController),
            ConfigTextField(icon: Icons.lock, label: 'Password', controller: _passController, obscure: true),
            ConfigActionRow(icon: Icons.save, label: 'Save and connect', color: AppTheme.success, onTap: _writeWifiConfig),
            ConfigActionRow(icon: Icons.link_off, label: 'Disconnect', color: AppTheme.warning, onTap: _wifiDisconnect),
            ConfigActionRow(icon: Icons.delete_forever, label: 'Forget network', destructive: true, onTap: _confirmWipeWifi),
          ],
        ),
        _OtaSection(currentVersion: _fwVersion),
        IosSection(header: 'Restart', children: [
          ConfigActionRow(
            icon: Icons.refresh,
            label: 'Reboot',
            subtitle: 'Restart without erasing settings',
            color: AppTheme.warning,
            onTap: _confirmReboot,
          ),
          ConfigActionRow(
            icon: Icons.restart_alt,
            label: 'Factory reset',
            subtitle: 'Erase all settings and reboot',
            destructive: true,
            onTap: _confirmFactoryReset,
          ),
        ]),
      ],
    );
  }

  Future<void> _confirmReboot() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Reboot device?'),
        content: const Text('Device will restart. BLE will reconnect automatically.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reboot')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(bleManagerProvider).rebootDevice();
  }

  Future<void> _confirmFactoryReset() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Factory reset?'),
        content: const Text(
          'This will ERASE all settings (watchlists, WiFi credentials, '
          'hardware config, mesh keys) and reboot the device. This cannot be undone.',
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase and reboot')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(bleManagerProvider).factoryReset();
  }

  Future<void> _writeHardwareConfig() async {
    try {
      await ref.read(bleManagerProvider).writeHardwareConfig(
            buzzer: _buzzerEnabled,
            led: _ledEnabled,
            neopixelBrightness: _neopixelBrightness,
            buzzerVolume: _buzzerVolume,
            extendedOui: _flockExtendedOui,
            allowOuiOnly: _flockAllowOuiOnly,
            offlineScan: _offlineScanEnabled,
          );
      ref.read(sharedPreferencesProvider)
          .setBool('offlineScanEnabled', _offlineScanEnabled);
      ref.read(sharedPreferencesProvider)
          .setInt('neopixelBrightness', _neopixelBrightness);
    } catch (e) {
      DebugLog.log('CONFIG: writeHardwareConfig failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Hardware config write failed — resyncing: $e')),
      );
      _readDeviceConfig();
    }
  }

  Future<void> _writeAlertConfig() async {
    try {
      await ref.read(bleManagerProvider).writeAlertConfig(
            cooldownMs: _cooldownMs,
            heartbeatMs: _heartbeatMs,
            rediscoverMs: _rediscoverMs,
            hbActiveMs: _hbActiveMs,
          );
    } catch (e) {
      DebugLog.log('CONFIG: writeAlertConfig failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Alert config write failed — resyncing: $e')),
      );
      _readDeviceConfig();
    }
  }
}

