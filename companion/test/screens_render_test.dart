import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:oui_spy/app.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';
import 'package:oui_spy/features/feed/detection_row.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/observation.dart';
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/core/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _out = Platform.environment['SHOT_DIR'];

Future<void> _font(String family, List<String> paths) async {
  final l = FontLoader(family);
  for (final p in paths) {
    l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
  }
  await l.load();
}

Future<void> _fonts() async {
  final root = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  for (final family in ['Roboto', 'Ahem']) {
    await _font(family, ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf', '$root/Roboto-Bold.ttf']);
  }
  for (final f in ['CupertinoSystemText', 'CupertinoSystemDisplay', '.SF Pro Text', '.SF Pro Display', '.SF UI Text', '.SF UI Display']) {
    await _font(f, ['/System/Library/Fonts/SFNS.ttf']);
  }
  final cup = Directory('${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('cupertino_icons'))
      .toList();
  if (cup.isNotEmpty) await _font('packages/cupertino_icons/CupertinoIcons', ['${cup.last.path}/assets/CupertinoIcons.ttf']);
  await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
  await _font('monospace', ['/System/Library/Fonts/SFNSMono.ttf']);
}

void _mockChannels(String tmp) {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp);
  for (final name in [
    'flutter_blue_plus/methods',
    'dexterous.com/flutter/local_notifications',
    'flutter.baseflow.com/geolocator',
    'flutter.baseflow.com/geolocator_apple',
    'live_activities',
    'plugins.it_nomads.com/flutter_secure_storage',
  ]) {
    m.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
}

List<Observation> _sample(int now) => [
      Observation(key: 'BLE:58:8E:81:A1:B2:C3', kind: RadioKind.ble, mac: '58:8E:81:A1:B2:C3', name: 'FS Ext Battery', rssi: -86, rssiMin: -92, rssiMax: -78, firstSeenMs: now - 600000, lastSeenMs: now - 120000, gpsTrail: [GpsSample(now - 120000, 39.0, -105.0)]),
      Observation(key: 'BLE:CF:61:AF:10:22:33', kind: RadioKind.ble, mac: 'CF:61:AF:10:22:33', rssi: -71, firstSeenMs: now - 90000, lastSeenMs: now - 5000),
      Observation(key: 'WIFI:00:25:DF:11:22:33', kind: RadioKind.wifi, mac: '00:25:DF:11:22:33', name: 'AXON-BODY3', rssi: -64, rssiMin: -80, rssiMax: -60, channel: 6, authMode: 3, firstSeenMs: now - 30000, lastSeenMs: now - 1000),
      Observation(key: 'BLE:5B2C9E10-7A1D-4C77-9E5A-0F1B2C3D4E5F', kind: RadioKind.ble, mac: '', name: 'ESP32-C3', rssi: -55, firstSeenMs: now - 20000, lastSeenMs: now - 2000),
      Observation(key: 'WIFI:B4:1E:52:44:55:66', kind: RadioKind.wifi, mac: 'B4:1E:52:44:55:66', rssi: -90, channel: 11, authMode: 0, firstSeenMs: now - 400000, lastSeenMs: now - 300000),
    ];

List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

Future<void> _renderDetections(WidgetTester tester) async {
  final dets = [
    for (final h in [
      '0040486e8bd31aa9064a1a0000010000000000004e6f6b696120726f757465720000000000000000000000000000000000000000',
      '005cfce1006a24a706212100000500000000000056696c6c6173656e6f7200000000000000000000000000000000000000000000',
    ])
      BleProtocol.decodeDetection(_hex(h), sessionId: 's', nodeId: 'n', appTimestamp: DateTime.now().subtract(const Duration(seconds: 12))),
  ];
  final oui = OuiLookupService();
  final boundary = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(
    key: boundary,
    child: ProviderScope(
      overrides: [ouiLookupProvider.overrideWith((ref) => oui)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: IosPage(title: 'Live', slivers: [
            IosSliverSection(header: '2 detections', itemCount: dets.length, itemBuilder: (_, i) => DetectionRow(detection: dets[i])),
          ]),
        ),
      ),
    ),
  ));
  Future<void> shot(String name) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    tester.takeException();
    final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final img = await ro.toImage(pixelRatio: 1);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  await shot('live_rows');
  await tester.tap(find.byType(DetectionRow).first, warnIfMissed: false);
  await shot('detection_detail');
}

void main() {
  testWidgets('render detection rows', (tester) async {
    if (_out == null) return;
    await tester.runAsync(_fonts);
    final tmp = Directory.systemTemp.createTempSync('ouispy_rows').path;
    _mockChannels(tmp);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await _renderDetections(tester);
  });

  testWidgets('render every view', (tester) async {
    if (_out == null) return;
    await tester.runAsync(_fonts);
    final tmp = Directory.systemTemp.createTempSync('ouispy_shots').path;
    _mockChannels(tmp);
    SharedPreferences.setMockInitialValues({'onboardingComplete': true});
    final prefs = await SharedPreferences.getInstance();

    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final oui = OuiLookupService();
    final reg = DeviceRegistry(vendorOf: oui.lookup);
    await tester.runAsync(reg.loadCatalog);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final o in _sample(now)) {
      reg.ingest(o, source: o.mac.isEmpty ? 'phone' : 'esp32');
    }

    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          deviceRegistryProvider.overrideWith((ref) => reg),
          ouiLookupProvider.overrideWith((ref) => oui),
        ],
        child: const OuiSpyApp(),
      ),
    ));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final e = tester.takeException();
      if (e != null) debugPrint('SHOT-EXC: ${e.toString().split('\n').first}');
    }

    Future<void> shot(String name) async {
      await settle();
      final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final img = await ro.toImage(pixelRatio: 1);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    GoRouter router() => ProviderScope.containerOf(tester.element(find.byType(OuiSpyApp))).read(routerProvider);

    Future<void> tapTooltip(String t) async {
      final f = find.byTooltip(t);
      if (f.evaluate().isEmpty) return;
      await tester.tap(f.first, warnIfMissed: false);
      await settle();
    }

    Future<void> closeSheet() async {
      for (final type in [BottomSheet, CupertinoActionSheet]) {
        final f = find.byType(type);
        if (f.evaluate().isNotEmpty) {
          Navigator.of(tester.element(f.first)).pop();
          await settle();
        }
      }
    }

    for (final r in ['/home', '/detections', '/devices', '/wardrive', '/config']) {
      router().go(r);
      final n = r.substring(1);
      await shot(n);
      await tapTooltip('Filter');
      await shot('${n}_filter');
      await closeSheet();
      await tapTooltip('More');
      await shot('${n}_more');
      await closeSheet();
    }
    router().go('/detections');
    await settle();
    await tester.tap(find.text('History').first, warnIfMissed: false);
    await settle();
    await shot('history');
    await tapTooltip('Filter');
    await shot('history_filter');
    await closeSheet();
    router().go('/wardrive');
    await settle();
    final sessions = find.text('SESSIONS');
    if (sessions.evaluate().isNotEmpty) {
      await tester.tap(sessions.first, warnIfMissed: false);
      await shot('wardrive_sessions');
      await closeSheet();
    }
    router().go('/config');
    await settle();
    await shot('settings_root');
    for (final s in ['App', 'Scanning', 'Watchlist', 'Threat signatures', 'Ignore list', 'Notifications', 'Hardware', 'Mesh', 'Firmware', 'Wardrive accounts', 'Packet captures', 'Export and backup']) {
      try {
        await tester.scrollUntilVisible(find.text(s), 200, scrollable: find.byType(Scrollable).first, maxScrolls: 20);
      } catch (_) {}
      await settle();
      final g = find.text(s);
      if (g.evaluate().isEmpty) continue;
      await tester.tap(g.first, warnIfMissed: false);
      await shot('settings_${s.toLowerCase().replaceAll(' ', '_')}');
      final back = find.byType(CupertinoNavigationBarBackButton);
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first, warnIfMissed: false);
        await settle();
      }
    }
    for (final r in ['/engine/detector', '/engine/foxhunter', '/engine/skyspy', '/engine/pcap', '/export', '/onboarding']) {
      router().go(r);
      await shot(r.substring(1).replaceAll('/', '_'));
    }
    router().go('/devices');
    await settle();
    await tester.tap(find.text('Axon').first, warnIfMissed: false);
    await shot('device_detail');
  });
}
