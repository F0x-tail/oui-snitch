import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _out = Platform.environment['SHOT_DIR'];

class _D {
  const _D(this.name, this.mac, this.vendor, this.kind, this.rssi, this.ago, this.src, this.ble, this.color);
  final String name, mac, vendor, kind, ago, src;
  final int rssi;
  final bool ble;
  final Color color;
}

const _flock = Color(0xFF4ADE80);
const _le = Color(0xFFF87171);
const _other = Color(0xFFA78BFA);
const _grey = Color(0xFF9CA3AF);

const _devices = [
  _D('Axon body camera', '00:25:DF:11:22:33', 'Axon Enterprise', 'Public safety', -64, '2s', 'Node', false, _le),
  _D('FS Ext Battery', '58:8E:81:A1:B2:C3', 'Flock Safety', 'Flock', -86, '2m', 'Node', true, _flock),
  _D('Flock Safety Camera', 'B4:1E:52:44:55:66', 'Flock Safety', 'Flock', -90, '5m', 'Node', false, _flock),
  _D('ESP32-C3', 'iOS 5B2C9E10-7A1D…', 'Espressif', 'Hobby module', -55, '3s', 'Phone', true, _other),
  _D('Unknown BLE device', 'CF:61:AF:10:22:33', 'Randomized', 'Unclassified', -71, '6s', 'Node', true, _grey),
  _D('AirTag', 'D4:11:9A:0B:77:21', 'Apple', 'Tracker', -78, '12s', 'Node', true, Color(0xFFFBBF24)),
];

Color _rssiColor(int r) => r >= -60 ? const Color(0xFF4ADE80) : r >= -75 ? const Color(0xFFFBBF24) : const Color(0xFF9CA3AF);

Widget _ios() {
  final groups = <String, List<_D>>{};
  for (final d in _devices) {
    groups.putIfAbsent(d.kind, () => []).add(d);
  }
  return CupertinoApp(
    debugShowCheckedModeBanner: false,
    theme: const CupertinoThemeData(brightness: Brightness.dark),
    home: CupertinoTabScaffold(
      tabBar: CupertinoTabBar(items: const [
        BottomNavigationBarItem(icon: Icon(CupertinoIcons.house_fill), label: 'Home'),
        BottomNavigationBarItem(icon: Icon(CupertinoIcons.dot_radiowaves_left_right), label: 'Live'),
        BottomNavigationBarItem(icon: Icon(CupertinoIcons.device_phone_portrait), label: 'Devices'),
        BottomNavigationBarItem(icon: Icon(CupertinoIcons.map), label: 'Wardrive'),
        BottomNavigationBarItem(icon: Icon(CupertinoIcons.gear), label: 'Settings'),
      ], currentIndex: 2),
      tabBuilder: (context, _) => CupertinoPageScaffold(
        child: CustomScrollView(slivers: [
          const CupertinoSliverNavigationBar(
            largeTitle: Text('Devices'),
            trailing: Icon(CupertinoIcons.line_horizontal_3_decrease_circle),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(children: [
                const CupertinoSearchTextField(placeholder: 'Name, MAC, vendor'),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: 0,
                    onValueChanged: (_) {},
                    children: const {0: Text('All 6'), 1: Text('BLE 4'), 2: Text('Wi-Fi 2')},
                  ),
                ),
              ]),
            ),
          ),
          for (final e in groups.entries)
            SliverToBoxAdapter(
              child: CupertinoListSection.insetGrouped(
                header: Text(e.key.toUpperCase()),
                children: [
                  for (final d in e.value)
                    CupertinoListTile.notched(
                      leading: Icon(d.ble ? CupertinoIcons.bluetooth : CupertinoIcons.wifi, color: d.color),
                      title: Text(d.name),
                      subtitle: Text('${d.mac}\n${d.vendor} · ${d.src}', maxLines: 2),
                      additionalInfo: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${d.rssi} dBm', style: TextStyle(color: _rssiColor(d.rssi), fontWeight: FontWeight.w600)),
                          Text('${d.ago} ago', style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                      trailing: const CupertinoListTileChevron(),
                    ),
                ],
              ),
            ),
        ]),
      ),
    ),
  );
}

Widget _material() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF6E8BFF), brightness: Brightness.dark),
    home: Scaffold(
      appBar: AppBar(title: const Text('Devices'), actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert))]),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SearchBar(hintText: 'Search name, MAC, vendor', leading: const Icon(Icons.search), elevation: WidgetStateProperty.all(0)),
        ),
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final (l, s) in [('All', true), ('BLE', false), ('Wi-Fi', false), ('Flock', false), ('Trackers', false)])
              Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: Text(l), selected: s, onSelected: (_) {})),
          ]),
        ),
        for (final d in _devices) ...[
          ListTile(
            isThreeLine: true,
            leading: CircleAvatar(backgroundColor: d.color.withValues(alpha: 0.2), child: Icon(d.ble ? Icons.bluetooth : Icons.wifi, color: d.color)),
            title: Text(d.name),
            subtitle: Text('${d.mac}\n${d.kind} · ${d.vendor} · ${d.src}'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${d.rssi} dBm', style: TextStyle(color: _rssiColor(d.rssi), fontWeight: FontWeight.w600)),
                Text('${d.ago} ago'),
              ],
            ),
          ),
          const Divider(height: 1, indent: 72),
        ],
      ]),
      bottomNavigationBar: NavigationBar(selectedIndex: 2, destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.sensors), label: 'Live'),
        NavigationDestination(icon: Icon(Icons.devices), label: 'Devices'),
        NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Wardrive'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ]),
    ),
  );
}

Widget _table() {
  const mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5);
  const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF9CA3AF), letterSpacing: 0.5);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF6E8BFF)),
    home: Scaffold(
      appBar: AppBar(title: const Text('Devices'), actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.filter_list)),
      ]),
      body: Column(children: [
        Container(
          color: const Color(0xFF1F2430),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: const Row(children: [
            Expanded(flex: 5, child: Text('NAME / MAC', style: head)),
            Expanded(flex: 3, child: Text('CLASS', style: head)),
            SizedBox(width: 44, child: Text('RSSI', style: head, textAlign: TextAlign.right)),
            SizedBox(width: 40, child: Text('SEEN', style: head, textAlign: TextAlign.right)),
          ]),
        ),
        for (final (i, d) in _devices.indexed)
          Container(
            color: i.isOdd ? const Color(0xFF151922) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Container(width: 4, height: 34, color: d.color, margin: const EdgeInsets.only(right: 8)),
              Expanded(
                flex: 5,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(d.mac, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono.copyWith(color: const Color(0xFF9CA3AF))),
                ]),
              ),
              Expanded(flex: 3, child: Text(d.kind, style: TextStyle(fontSize: 12.5, color: d.color))),
              SizedBox(width: 44, child: Text('${d.rssi}', textAlign: TextAlign.right, style: mono.copyWith(color: _rssiColor(d.rssi)))),
              SizedBox(width: 40, child: Text(d.ago, textAlign: TextAlign.right, style: mono)),
            ]),
          ),
      ]),
      bottomNavigationBar: NavigationBar(selectedIndex: 2, destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.sensors), label: 'Live'),
        NavigationDestination(icon: Icon(Icons.devices), label: 'Devices'),
        NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Wardrive'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ]),
    ),
  );
}

Future<void> _font(String family, List<String> paths) async {
  final l = FontLoader(family);
  for (final p in paths) {
    l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
  }
  await l.load();
}

void main() {
  testWidgets('style mockups', (tester) async {
    if (_out == null) return;
    final root = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
    await tester.runAsync(() async {
      for (final f in ['Roboto', 'Ahem']) {
        await _font(f, ['$root/Roboto-Regular.ttf', '$root/Roboto-Medium.ttf', '$root/Roboto-Bold.ttf']);
      }
      for (final f in ['CupertinoSystemText', 'CupertinoSystemDisplay', '.SF Pro Text', '.SF Pro Display', '.SF UI Text', '.SF UI Display']) {
        await _font(f, ['/System/Library/Fonts/SFNS.ttf']);
      }
      await _font('MaterialIcons', ['$root/MaterialIcons-Regular.otf']);
      await _font('monospace', ['/System/Library/Fonts/SFNSMono.ttf']);
      final cup = Directory('${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev').listSync().whereType<Directory>().where((d) => d.path.contains('cupertino_icons')).toList();
      if (cup.isNotEmpty) await _font('packages/cupertino_icons/CupertinoIcons', ['${cup.last.path}/assets/CupertinoIcons.ttf']);
    });
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    for (final (name, w) in [('1_ios_native', _ios()), ('2_material3', _material()), ('3_dense_table', _table())]) {
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: key, child: w));
      await tester.pump(const Duration(milliseconds: 300));
      final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final img = await ro.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  });
}
