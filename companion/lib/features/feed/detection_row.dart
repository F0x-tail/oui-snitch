import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:oui_spy/core/app_state.dart';
import 'package:oui_spy/core/deflock/deflock_provider.dart';
import 'package:oui_spy/core/drone_grouping.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/oui/oui_lookup_service.dart';
import 'package:oui_spy/core/radio_classifier.dart';
import 'package:oui_spy/core/services/faa_service.dart';
import 'package:oui_spy/core/wardrive_state.dart';
import 'package:oui_spy/features/devices/devices_screen.dart' show rssiColor;
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/widgets/ios.dart';

String _ago(DateTime ts) {
  final d = DateTime.now().difference(ts);
  if (d.inSeconds < 60) return '${d.inSeconds < 0 ? 0 : d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return DateFormat('MMM d').format(ts);
}

String detectionHeadline(Detection d) {
  if (d.engine == Engine.detector) return detectorTitle(d);
  if (d.wardrive != null && d.wardrive!.ssid.isNotEmpty) return d.wardrive!.ssid;
  if (d.ssid.isNotEmpty) return d.ssid;
  if (d.deviceName.isNotEmpty) return d.deviceName;
  return d.macAddress.toUpperCase();
}

String detectorTitle(Detection d) {
  final why = d.detector?.filterDescription?.trim() ?? '';
  return switch (d.method) {
    'probe_ssid' => why.isEmpty ? 'Wi-Fi probe request' : 'Probe request for "$why"',
    'ble_watchlist' || 'wifi_watchlist' => why.isEmpty ? 'Watchlist hit' : why,
    'deauth_storm' => 'Deauth / disassoc attack',
    _ => why.isEmpty ? methodLabel(d.method) : why,
  };
}

String methodLabel(String method) => switch (method) {
  'oui_addr1' => 'OUI in destination address',
  'oui_addr2' => 'OUI in source address',
  'oui_addr3' => 'OUI in BSSID',
  'ssid' => 'SSID',
  'wildcard_probe' => 'Probe request',
  'wildcard_probe_ie_sig' => 'Probe request signature',
  'oui_match' => 'Bluetooth OUI',
  'name_match' => 'Bluetooth name',
  'mfg_id' => 'Manufacturer data',
  'raven_uuid' => 'Raven service UUID',
  'gatt_uuid' => 'Flock GATT service',
  'nordic_dfu' => 'Nordic DFU service',
  'tracker' => 'Find My tracker',
  'flipper' => 'Flipper Zero',
  'deauth_storm' => 'Deauth storm',
  'probe_ssid' => 'Probe request',
  'pwnagotchi' => 'Pwnagotchi',
  'glasses' => 'Meta glasses',
  'axon' => 'Axon',
  'ble_watchlist' || 'wifi_watchlist' => 'Watchlist',
  'ble_proximity' || 'wifi_proximity' => 'Proximity',
  'wifi_ap' => 'Wi-Fi access point',
  'ble_adv' => 'Bluetooth advertisement',
  'unitree_ble' => 'Unitree robot',
  'odid_ble' => 'Remote ID over Bluetooth',
  'odid_nan' => 'Remote ID over Wi-Fi NAN',
  'odid_beacon' => 'Remote ID over Wi-Fi beacon',
  'pcap' => 'Packet capture',
  _ => method,
};

String _authLabel(int mode) => switch (mode) {
  0 => 'Open (no encryption)',
  1 => 'WEP',
  2 => 'WPA-PSK',
  3 => 'WPA2-PSK',
  4 => 'WPA/WPA2-PSK',
  5 => 'WPA2-Enterprise',
  6 => 'WPA3-SAE',
  _ => 'WPA2-PSK',
};

List<String> _flockSignalLabels(FlockExtension? flock) {
  if (flock == null || flock.signals == 0) return const [];
  return [
    if (flock.hasSignal(FlockSignal.oui)) 'OUI',
    if (flock.hasSignal(FlockSignal.name)) 'name',
    if (flock.hasSignal(FlockSignal.serial)) 'serial',
    if (flock.hasSignal(FlockSignal.mfg)) 'XUNTONG manufacturer data',
    if (flock.hasSignal(FlockSignal.tn)) 'TN serial',
    if (flock.hasSignal(FlockSignal.ravenUuid)) 'Raven UUID',
    if (flock.hasSignal(FlockSignal.gatt)) 'Flock GATT',
    if (flock.hasSignal(FlockSignal.dfu)) 'Nordic DFU',
  ];
}

Color _flockConfidenceColor(FlockConfidence c) => switch (c) {
  FlockConfidence.verified || FlockConfidence.high => AppTheme.success,
  FlockConfidence.suspected => AppTheme.warning,
};

void detectionZoomOnMap(BuildContext context, WidgetRef ref, Detection detection) {
  if (detection.latitude == null || detection.longitude == null) return;
  ref.read(wardriveProvider).requestZoom(detection.latitude!, detection.longitude!, detection: detection);
  context.go('/wardrive');
}

void detectionStartFoxhunt(BuildContext context, WidgetRef ref, Detection detection) {
  ref.read(appStateProvider).setFoxhunterTarget(detection.macAddress, channel: detection.channel);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Foxhunting ${detection.macAddress.toUpperCase()}')));
}

void showDetectionDetails(
  BuildContext context,
  WidgetRef ref,
  Detection detection, {
  bool showMapAction = true,
  VoidCallback? onDelete,
  VoidCallback? onShowMap,
}) {
  if (detection.flock != null && detection.latitude != null && detection.longitude != null) {
    ref.read(deflockProvider).ensureAround(detection.latitude!, detection.longitude!);
  }
  Navigator.of(context).push(CupertinoPageRoute<void>(
    builder: (_) => DetectionDetailPage(
      detection: detection,
      showMapAction: showMapAction,
      onDelete: onDelete,
      onShowMap: onShowMap,
    ),
  ));
}

class DetectionRow extends ConsumerWidget {
  const DetectionRow({super.key, required this.detection, this.onTap});
  final Detection detection;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final d = detection;
    final vendor = ref.watch(ouiLookupProvider).lookup(d.macAddress);
    final app = ref.watch(appStateProvider);
    final node = d.sourceNodeId.isEmpty ? '' : app.labelForNode(d.sourceNodeId);
    final headline = detectionHeadline(d);
    final mac = d.macAddress.toUpperCase();
    final generic = d.method == 'wifi_ap' || d.method == 'ble_adv';
    final idLine = [
      if (headline != mac) mac,
      if (vendor != null && vendor.isNotEmpty) vendor,
    ].join(' · ');
    final meta = [
      d.engine.label,
      if (!generic) methodLabel(d.method),
      if (d.channel > 0) 'ch ${d.channel}',
      if (d.wardrive != null && d.isWifiDetection) _authLabel(d.wardrive!.authMode),
      if (d.count > 1) '${d.count}×',
      if (node.isNotEmpty) node,
    ].join(' · ');
    final (flag, flagColor) = _flag(d);
    return IosRow(
      leading: Icon(d.isBleDetection ? CupertinoIcons.bluetooth : CupertinoIcons.wifi, color: d.engine.color, size: 24),
      title: headline,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (idLine.isNotEmpty) Text(idLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary)),
          Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (flag != null) Text(flag, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: flagColor, fontWeight: FontWeight.w600)),
        ],
      ),
      detail: _RssiAge(rssi: d.rssi, ts: d.appTimestamp),
      chevron: true,
      onTap: onTap ?? () => showDetectionDetails(context, ref, d),
    );
  }

  static (String?, Color) _flag(Detection d) {
    if (OuiLookupService.isLawEnforcement(d.macAddress)) return ('Law enforcement hardware', AppTheme.warning);
    if (d.flock?.isValidated == true) return ('Flock · validated', AppTheme.success);
    if (d.flock?.isRaven == true) return ('Raven gunshot sensor${(d.flock!.ravenFirmware ?? '').isNotEmpty ? ' · fw ${d.flock!.ravenFirmware}' : ''}', AppTheme.warning);
    if (d.flock != null) {
      final c = d.flock!.confidence(d.method);
      return (c.label(d.method), _flockConfidenceColor(c));
    }
    if (d.unipwn != null) return ('${d.unipwn!.robotType}${d.unipwn!.exploited ? ' · exploited' : ''}', Engine.uniPwn.color);
    if ((d.odid?.uavId ?? '').isNotEmpty) {
      return ('UAV ${d.odid!.uavId}${d.odid!.altitudeMsl != null ? ' · ${d.odid!.altitudeMsl} m' : ''}', Engine.skySpy.color);
    }
    return (null, AppTheme.accent);
  }
}

class _RssiAge extends StatelessWidget {
  const _RssiAge({required this.rssi, required this.ts});
  final int rssi;
  final DateTime ts;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$rssi dBm', style: TextStyle(color: rssiColor(rssi), fontSize: 15, fontWeight: FontWeight.w600)),
        Text(_ago(ts), style: TextStyle(color: t.textDim, fontSize: 13)),
      ],
    );
  }
}

class DroneDetectionRow extends ConsumerWidget {
  const DroneDetectionRow({super.key, required this.group});
  final DroneGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTheme.of(context);
    final d = group.representative;
    final node = d.sourceNodeId.isEmpty ? '' : ref.watch(appStateProvider).labelForNode(d.sourceNodeId);
    final transports = {for (final m in group.methods) methodLabel(m).replaceFirst('Remote ID over ', '')}.join(', ');
    return IosRow(
      leading: Icon(CupertinoIcons.airplane, color: Engine.skySpy.color, size: 24),
      title: group.uavId,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group.macs.map((m) => m.toUpperCase()).join(', '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary)),
          Text([
            'Remote ID over $transports',
            if (d.odid?.altitudeMsl != null) '${d.odid!.altitudeMsl} m MSL',
            if (node.isNotEmpty) node,
          ].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
      detail: _RssiAge(rssi: d.rssi, ts: d.appTimestamp),
      chevron: true,
      onTap: () => showDetectionDetails(context, ref, d),
    );
  }
}

class DetectionDetailPage extends ConsumerStatefulWidget {
  const DetectionDetailPage({super.key, required this.detection, this.showMapAction = true, this.onDelete, this.onShowMap});

  final Detection detection;
  final bool showMapAction;
  final VoidCallback? onDelete;
  final VoidCallback? onShowMap;

  @override
  ConsumerState<DetectionDetailPage> createState() => _DetectionDetailPageState();
}

class _DetectionDetailPageState extends ConsumerState<DetectionDetailPage> {
  bool _faaLoading = false;
  String? _faaError;

  Detection get d => widget.detection;

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1)));
  }

  Future<void> _faaLookup(String uasId) async {
    setState(() {
      _faaLoading = true;
      _faaError = null;
    });
    try {
      final reg = await ref.read(faaServiceProvider).lookup(uasId);
      if (!mounted) return;
      if (reg == null) {
        setState(() => _faaError = 'Not found in the FAA database');
        return;
      }
      Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => _FaaPage(reg: reg, uasId: uasId)));
    } on FaaLookupException catch (e) {
      if (mounted) setState(() => _faaError = e.message);
    } catch (e) {
      if (mounted) setState(() => _faaError = 'Lookup failed: $e');
    } finally {
      if (mounted) setState(() => _faaLoading = false);
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete this detection?'),
        content: const Text('Removes every MAC grouped with this device from the feed and the wardrive session.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop();
    if (widget.onDelete != null) {
      widget.onDelete!();
      return;
    }
    ref.read(appStateProvider).removeDetectionGroup(d);
    ref.read(wardriveProvider).removeDetectionGroup(d);
  }

  List<(String, String)> _fields() {
    final vendor = ref.read(ouiLookupProvider).lookup(d.macAddress);
    final node = d.sourceNodeId.isEmpty ? '' : ref.read(appStateProvider).labelForNode(d.sourceNodeId);
    final out = <(String, String)>[
      ('MAC address', d.macAddress.toUpperCase()),
      if (vendor != null) ('Vendor', vendor),
      if (d.deviceName.isNotEmpty) ('Name', d.deviceName),
      if (d.ssid.isNotEmpty) ('SSID', d.ssid),
      ('Engine', d.engine.label),
      ('Matched by', methodLabel(d.method)),
    ];
    final why = d.detector?.filterDescription?.trim() ?? '';
    if (why.isNotEmpty) {
      out.add((switch (d.method) {
        'probe_ssid' => 'Probing for',
        'ble_watchlist' || 'wifi_watchlist' => 'Watchlist entry',
        _ => 'Matched',
      }, why));
    }
    if (d.detector != null) out.add(('Match type', d.detector!.isFullMac ? 'Full MAC' : 'OUI prefix'));
    out.add(('Signal', '${d.rssi} dBm'));
    if (d.channel > 0) out.add(('Channel', '${d.channel}'));
    out.add(('Times seen', '${d.count}'));
    out.add(('Last seen', DateFormat('MMM d, HH:mm:ss').format(d.appTimestamp)));
    if (d.sourceNodeId.isNotEmpty) {
      out.add(('Heard by node', node.isNotEmpty && node != d.sourceNodeId ? '$node (${d.sourceNodeId})' : d.sourceNodeId));
    }
    if (d.wardrive != null) out.add(('Security', _authLabel(d.wardrive!.authMode)));
    if (d.flock?.isRaven == true) out.add(('Type', 'Raven gunshot sensor'));
    if (d.flock != null) out.add(('Confidence', d.flock!.confidence(d.method).label(d.method)));
    final sigs = _flockSignalLabels(d.flock);
    if (sigs.isNotEmpty) out.add(('Flock signals', sigs.join(', ')));
    if (d.unipwn != null) out.add(('Robot', '${d.unipwn!.robotType}${d.unipwn!.exploited ? ' · exploited' : ''}'));
    final lat = d.latitude;
    final lon = d.longitude;
    if (d.flock != null && lat != null && lon != null) {
      final df = ref.watch(deflockProvider);
      final match = df.match(lat, lon);
      final busy = df.loading && match.verdict == AlprMapVerdict.unknown;
      out.add(('DeFlock map', busy ? 'Checking the map…' : '${match.label} · ${match.detail}'));
      if (osmContributionAllowed(d.flock!.confidence(d.method), match.verdict)) {
        out.add(('Add to OpenStreetMap', DeflockProvider.osmNoteUrl(lat, lon)));
      }
    }
    final o = d.odid;
    if (o != null) {
      if ((o.uavId ?? '').isNotEmpty) out.add(('UAV ID', o.uavId!));
      if ((o.operatorId ?? '').isNotEmpty) out.add(('Operator ID', o.operatorId!));
      final hasPos = o.droneLat != null && o.droneLon != null && !(o.droneLat == 0 && o.droneLon == 0);
      if (hasPos) {
        out.add(('Drone position', '${o.droneLat!.toStringAsFixed(5)}, ${o.droneLon!.toStringAsFixed(5)}'));
      } else {
        out.add(('Drone position', 'No GPS fix'));
        out.add(('Estimated range', '${rssiRangeLabel(d.rssi, isBle: d.isBleDetection)} (from signal)'));
      }
      if (o.altitudeMsl != null) out.add(('Altitude MSL', '${o.altitudeMsl} m'));
      if (o.heightAgl != null) out.add(('Height AGL', '${o.heightAgl} m'));
      if (o.droneSpeed != null) out.add(('Speed', '${o.droneSpeed} m/s'));
      if (o.droneHeading != null) out.add(('Heading', '${o.droneHeading}°'));
      if (o.pilotLat != null && o.pilotLon != null && !(o.pilotLat == 0 && o.pilotLon == 0)) {
        out.add(('Pilot position', '${o.pilotLat!.toStringAsFixed(5)}, ${o.pilotLon!.toStringAsFixed(5)}'));
      }
      if (o.uaType != null && o.uaType! > 0) out.add(('Aircraft type', _odidUaType(o.uaType!)));
      if (o.idType != null && o.idType! > 0) out.add(('ID type', _odidIdType(o.idType!)));
      if ((o.selfId ?? '').isNotEmpty) {
        out.add((o.selfIdType != null && o.selfIdType! > 0 ? 'Self-ID (${o.selfIdType})' : 'Self-ID', o.selfId!));
      }
      if (o.vertSpeed != null) out.add(('Vertical speed', '${o.vertSpeed} m/s'));
      if (o.altitudeBaro != null) out.add(('Barometric altitude', '${o.altitudeBaro} m'));
      if (o.operatorAlt != null) out.add(('Operator altitude', '${o.operatorAlt} m'));
      if (o.opLocationType != null) out.add(('Operator location', _odidOpLocationType(o.opLocationType!)));
      if (o.heightType != null) out.add(('Height reference', o.heightType == 0 ? 'Above takeoff' : o.heightType == 1 ? 'Above ground' : 'Unknown (${o.heightType})'));
      if (o.status != null && o.status! > 0) out.add(('Aircraft status', _odidStatus(o.status!)));
      if (o.classification != null) {
        if (o.classification == 1) {
          if (o.categoryEu != null) out.add(('EU category', _odidCategoryEu(o.categoryEu!)));
          if (o.classEu != null) out.add(('EU class', o.classEu == 0 ? 'Undeclared' : (o.classEu! >= 1 && o.classEu! <= 6 ? 'EU C${o.classEu! - 1}' : 'Unknown (${o.classEu})')));
        } else {
          out.add(('Classification', 'Undeclared'));
        }
      }
      final acc = [
        if ((o.horizAcc ?? 0) > 0) 'horizontal ${o.horizAcc}',
        if ((o.vertAcc ?? 0) > 0) 'vertical ${o.vertAcc}',
        if ((o.baroAcc ?? 0) > 0) 'baro ${o.baroAcc}',
        if ((o.speedAcc ?? 0) > 0) 'speed ${o.speedAcc}',
      ];
      if (acc.isNotEmpty) out.add(('Accuracy codes', acc.join(' · ')));
      if ((o.areaCount ?? 0) > 0) {
        out.add(('Operating area', '${o.areaCount} aircraft · radius ${o.areaRadius ?? 0} m · ceiling ${o.areaCeiling ?? 0} m · floor ${o.areaFloor ?? 0} m'));
      }
      if ((o.locTimestamp ?? 0) > 0) out.add(('Location time', '${o.locTimestamp! ~/ 10}.${o.locTimestamp! % 10}s after the hour'));
    }
    if (lat != null && lon != null) {
      out.add((d.approxGps ? 'Location (phone, approximate)' : 'Location', '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final connected = ref.watch(appStateProvider).isConnected;
    final hasGps = d.latitude != null;
    final uas = d.odid?.uavId ?? '';
    final (flag, _) = DetectionRow._flag(d);
    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: detectionHeadline(d),
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: Icon(d.isBleDetection ? CupertinoIcons.bluetooth : CupertinoIcons.wifi, color: d.engine.color, size: 26),
                title: d.engine.label,
                subtitle: Text([methodLabel(d.method), ?flag].join('\n')),
                detail: _RssiAge(rssi: d.rssi, ts: d.appTimestamp),
              ),
            ]),
          ),
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: const IosIcon(CupertinoIcons.scope, AppTheme.foxhunter),
                title: 'Foxhunt this device',
                subtitle: Text(connected ? 'Track it by signal strength' : 'Connect a node first'),
                chevron: connected,
                disabled: !connected,
                onTap: connected
                    ? () {
                        Navigator.of(context).pop();
                        detectionStartFoxhunt(context, ref, d);
                      }
                    : null,
              ),
              if (widget.showMapAction)
                IosRow(
                  leading: const IosIcon(CupertinoIcons.map_fill, AppTheme.gpsGood),
                  title: 'Show on map',
                  subtitle: Text(hasGps ? (d.approxGps ? 'Phone location when it was logged' : 'Where it was detected') : 'No GPS fix for this detection'),
                  chevron: hasGps,
                  disabled: !hasGps,
                  onTap: hasGps
                      ? () {
                          Navigator.of(context).pop();
                          if (widget.onShowMap != null) {
                            widget.onShowMap!();
                          } else {
                            detectionZoomOnMap(context, ref, d);
                          }
                        }
                      : null,
                ),
              IosRow(
                leading: IosIcon(CupertinoIcons.doc_on_doc_fill, t.textDim),
                title: 'Copy MAC address',
                onTap: () => _copy('MAC address', d.macAddress.toUpperCase()),
              ),
              if (uas.isNotEmpty)
                IosRow(
                  leading: IosIcon(CupertinoIcons.doc_text_search, Engine.skySpy.color),
                  title: 'FAA registration lookup',
                  subtitle: Text(_faaError ?? 'Look up $uas', style: _faaError != null ? const TextStyle(color: AppTheme.error) : null),
                  trailing: _faaLoading ? const CupertinoActivityIndicator() : const CupertinoListTileChevron(),
                  onTap: _faaLoading ? null : () => _faaLookup(uas),
                ),
            ]),
          ),
          SliverToBoxAdapter(
            child: IosSection(
              header: 'Details',
              footer: 'Tap a row to copy it.',
              children: [
                for (final (k, v) in _fields())
                  IosRow(
                    title: k,
                    subtitle: Text(v, style: TextStyle(color: t.textSecondary, fontSize: 15)),
                    onTap: () => _copy(k, v),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: IosSection(children: [
              IosRow(
                leading: const IosIcon(CupertinoIcons.trash_fill, AppTheme.error),
                title: 'Delete detection',
                subtitle: const Text('Removes every MAC grouped with this device'),
                onTap: _confirmDelete,
              ),
            ]),
          ),
        ],
      ),
    );
  }

  static String _odidUaType(int v) => const {
        0: 'None', 1: 'Aeroplane', 2: 'Multirotor', 3: 'Gyroplane',
        4: 'Hybrid lift', 5: 'Ornithopter', 6: 'Glider', 7: 'Kite',
        8: 'Free balloon', 9: 'Captive balloon', 10: 'Airship',
        11: 'Free fall / parachute', 12: 'Rocket', 13: 'Tethered powered',
        14: 'Ground obstacle', 15: 'Other',
      }[v] ?? 'Unknown ($v)';

  static String _odidIdType(int v) => const {
        0: 'None', 1: 'Serial number', 2: 'CAA registration',
        3: 'UTM (UUID)', 4: 'Specific session ID',
      }[v] ?? 'Unknown ($v)';

  static String _odidOpLocationType(int v) => const {
        0: 'Takeoff point', 1: 'Live GNSS', 2: 'Fixed',
      }[v] ?? 'Unknown ($v)';

  static String _odidStatus(int v) => const {
        0: 'Undeclared', 1: 'On the ground', 2: 'Airborne',
        3: 'Emergency', 4: 'Remote ID system failure',
      }[v] ?? 'Unknown ($v)';

  static String _odidCategoryEu(int v) => const {
        0: 'Undeclared', 1: 'Open', 2: 'Specific', 3: 'Certified',
      }[v] ?? 'Unknown ($v)';
}

class _FaaPage extends StatelessWidget {
  const _FaaPage({required this.reg, required this.uasId});

  final FaaRegistration reg;
  final String uasId;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final age = DateTime.now().difference(reg.cachedAt);
    String date(String iso) {
      try {
        return DateFormat('yyyy-MM-dd').format(DateTime.parse(iso));
      } on FormatException {
        return iso;
      }
    }

    final rows = <(String, String)>[
      if (reg.status.isNotEmpty) ('Status', reg.status),
      if (reg.displayName.isNotEmpty) ('Aircraft', reg.displayName),
      if (reg.brand.isNotEmpty && reg.makeName.isNotEmpty && reg.brand != reg.makeName) ('Make', reg.makeName),
      if (reg.series.isNotEmpty) ('Series', reg.series),
      if (reg.manufacturerCode.isNotEmpty) ('Manufacturer code', reg.manufacturerCode),
      if (reg.productType.isNotEmpty) ('Type', reg.productType),
      if (reg.operationRules.isNotEmpty) ('Operation rules', reg.operationRules),
      if (reg.complianceCategories.isNotEmpty) ('Compliance', reg.complianceCategories),
      if (reg.trackingNumber.isNotEmpty) ('Tracking number', reg.trackingNumber),
      if (reg.updatedAt.isNotEmpty) ('Updated', date(reg.updatedAt)),
    ];
    return Scaffold(
      backgroundColor: t.background,
      body: IosPage(
        title: 'FAA registration',
        slivers: [
          SliverToBoxAdapter(
            child: IosSection(
              header: uasId,
              footer: age.inSeconds < 5 ? 'Live result' : 'Cached ${age.inMinutes < 60 ? '${age.inMinutes}m' : '${age.inHours}h'} ago',
              children: rows.isEmpty
                  ? [const IosRow(title: 'No registration data found')]
                  : [
                      for (final (k, v) in rows)
                        IosRow(
                          title: k,
                          subtitle: Text(v, style: TextStyle(color: t.textSecondary, fontSize: 15)),
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: v));
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$k copied'), duration: const Duration(seconds: 1)));
                          },
                        ),
                    ],
            ),
          ),
        ],
      ),
    );
  }
}
