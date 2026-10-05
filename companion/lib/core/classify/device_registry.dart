import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/radio_classifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'co_travel.dart';
import 'device_explain.dart';
import 'flood.dart';
import 'observation.dart';
import 'signature_engine.dart';

abstract class ObservationSource {
  String get name;
  Stream<Observation> get observations;
  void dispose() {}
}

String _hexBytes(Iterable<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String _uuidLe(List<int> b) {
  final h = _hexBytes(b.reversed);
  if (h.length != 32) return h;
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class AdvParts {
  final String name;
  final List<String> serviceUuids;
  final List<MfgRecord> mfg;
  final List<ServiceDataRecord> serviceData;
  final int? appearance;
  const AdvParts(this.name, this.serviceUuids, this.mfg, this.serviceData, this.appearance);
}

AdvParts parseAdvStructures(List<int> raw) {
  var name = '';
  final uuids = <String>[];
  final mfg = <MfgRecord>[];
  final sd = <ServiceDataRecord>[];
  int? appearance;
  var i = 0;
  while (i < raw.length) {
    final len = raw[i];
    if (len == 0 || i + 1 + len > raw.length) break;
    final type = raw[i + 1];
    final d = raw.sublist(i + 2, i + 1 + len);
    switch (type) {
      case 0x02 || 0x03:
        for (var j = 0; j + 2 <= d.length; j += 2) {
          uuids.add(_uuidLe(d.sublist(j, j + 2)));
        }
      case 0x04 || 0x05:
        for (var j = 0; j + 4 <= d.length; j += 4) {
          uuids.add(_uuidLe(d.sublist(j, j + 4)));
        }
      case 0x06 || 0x07:
        for (var j = 0; j + 16 <= d.length; j += 16) {
          uuids.add(_uuidLe(d.sublist(j, j + 16)));
        }
      case 0x08 || 0x09:
        if (type == 0x09 || name.isEmpty) name = String.fromCharCodes(d.where((c) => c >= 0x20 && c < 0x7F));
      case 0x16:
        if (d.length >= 2) sd.add(ServiceDataRecord(_uuidLe(d.sublist(0, 2)), _hexBytes(d.sublist(2))));
      case 0x20:
        if (d.length >= 4) sd.add(ServiceDataRecord(_uuidLe(d.sublist(0, 4)), _hexBytes(d.sublist(4))));
      case 0x21:
        if (d.length >= 16) sd.add(ServiceDataRecord(_uuidLe(d.sublist(0, 16)), _hexBytes(d.sublist(16))));
      case 0x19:
        if (d.length >= 2) appearance = d[0] | (d[1] << 8);
      case 0xFF:
        if (d.length >= 2) mfg.add(MfgRecord(d[0] | (d[1] << 8), _hexBytes(d.sublist(2))));
    }
    i += 1 + len;
  }
  return AdvParts(name, uuids, mfg, sd, appearance);
}

Observation observationFromDetection(Detection d) {
  final ble = d.isBleDetection;
  final mac = MacUtil.normalize(d.macAddress);
  final at = d.appTimestamp.millisecondsSinceEpoch;
  final adv = parseAdvStructures((d.wardrive == null ? null : wardriveAdvRaw[d.wardrive!]) ?? const []);
  final name = d.ssid.isNotEmpty ? d.ssid : (d.deviceName.isNotEmpty ? d.deviceName : adv.name);
  return Observation(
    serviceUuids: adv.serviceUuids,
    mfgRecords: adv.mfg,
    serviceData: adv.serviceData,
    appearance: adv.appearance,
    key: '${ble ? 'BLE' : 'WIFI'}:$mac',
    kind: ble ? RadioKind.ble : RadioKind.wifi,
    mac: mac,
    name: name,
    rssi: d.rssi,
    firstSeenMs: at,
    lastSeenMs: at,
    channel: ble ? 0 : d.channel,
    gpsTrail: d.latitude != null && d.longitude != null && !d.approxGps
        ? [GpsSample(at, d.latitude!, d.longitude!, d.rssi)]
        : const [],
  );
}

class EspDetectionSource extends ObservationSource {
  EspDetectionSource(Stream<Detection> detections) : observations = detections.map(observationFromDetection);

  @override
  String get name => 'esp32';

  @override
  final Stream<Observation> observations;
}

class PhoneBleSource extends ObservationSource {
  static const scanWindow = Duration(seconds: 8);
  static const scanEvery = Duration(seconds: 20);

  final _out = StreamController<Observation>.broadcast();
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _timer;
  bool _active = false;
  GpsSample? Function()? here;

  PhoneBleSource({this.here}) {
    _sub = FlutterBluePlus.onScanResults.listen(_onResults);
  }

  @override
  String get name => 'phone';

  @override
  Stream<Observation> get observations => _out.stream;

  bool get active => _active;

  void setActive(bool on) {
    if (on == _active) return;
    _active = on;
    _timer?.cancel();
    _timer = null;
    if (on) {
      _kick();
      _timer = Timer.periodic(scanEvery, (_) => _kick());
    }
  }

  Future<void> _kick() async {
    if (!_active || FlutterBluePlus.isScanningNow) return;
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) return;
    try {
      await FlutterBluePlus.startScan(timeout: scanWindow);
    } on Exception catch (e) {
      DebugLog.log('CLASSIFY: phone scan failed: $e');
    }
  }

  void _onResults(List<ScanResult> results) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final fix = here?.call();
    for (final r in results) {
      final id = r.device.remoteId.toString();
      final isMac = !Platform.isIOS && !Platform.isMacOS;
      final mac = isMac ? MacUtil.normalize(id) : '';
      final adv = r.advertisementData;
      _out.add(Observation(
        key: 'BLE:${isMac ? mac : id}',
        kind: RadioKind.ble,
        mac: mac,
        name: adv.advName,
        rssi: r.rssi,
        firstSeenMs: now,
        lastSeenMs: now,
        serviceUuids: [for (final u in adv.serviceUuids) u.str128.toUpperCase()],
        mfgRecords: [
          for (final e in adv.manufacturerData.entries) MfgRecord(e.key, _hex(e.value)),
        ],
        serviceData: [
          for (final e in adv.serviceData.entries) ServiceDataRecord(e.key.str128.toUpperCase(), _hex(e.value)),
        ],
        appearance: adv.appearance,
        gpsTrail: fix == null ? const [] : [GpsSample(now, fix.lat, fix.lon, r.rssi)],
      ));
    }
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _out.close();
  }
}

class ClassifiedDevice {
  final Observation obs;
  final List<Signature> signatures;
  final Set<String> sources;
  const ClassifiedDevice(this.obs, this.signatures, this.sources);

  List<String> get signatureNames => [for (final s in signatures) s.name];
  Guess get guess => DeviceExplain.guess(obs, signatureNames);
  SignatureClass? get primaryClass => signatures.isEmpty ? null : signatures.first.kind;
}

class DeviceRegistry extends ChangeNotifier {
  static const catalogAsset = 'assets/fieldwatch-signatures-v2.json';
  static const maxDevices = 2000;
  static const _trailCap = 48;
  static const phoneScanPref = 'phoneBleScanEnabled';

  DeviceRegistry({SignatureEngine? engine}) : _engine = engine;

  SignatureEngine? _engine;
  final _devices = <String, ClassifiedDevice>{};
  final _subs = <StreamSubscription<Observation>>[];
  final _sources = <ObservationSource>[];
  final pairingFlood = PairingFlood();
  final _path = <GpsSample>[];
  Timer? _tick;
  bool _dirty = false;

  Iterable<ClassifiedDevice> get devices => _devices.values;
  int get count => _devices.length;
  bool get ready => _engine != null;
  List<GpsSample> get path => List.unmodifiable(_path);

  Future<void> loadCatalog() async {
    if (_engine != null) return;
    try {
      _engine = SignatureEngine(Signature.parseCatalog(await rootBundle.loadString(catalogAsset)));
      DebugLog.log('CLASSIFY: catalog ${_engine!.signatures.length} signatures');
      notifyListeners();
    } on Exception catch (e) {
      DebugLog.log('CLASSIFY: catalog load failed: $e');
    }
  }

  void attach(ObservationSource source) {
    _sources.add(source);
    _subs.add(source.observations.listen((o) => ingest(o, source: source.name)));
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void recordPhoneFix(double lat, double lon, int atMs) {
    if (_path.isNotEmpty) {
      final last = _path.last;
      if (geoMeters(last.lat, last.lon, lat, lon) < 8) return;
    }
    _path.add(GpsSample(atMs, lat, lon));
    if (_path.length > 500) _path.removeRange(0, _path.length - 500);
  }

  void ingest(Observation o, {String source = ''}) {
    final now = o.lastSeenMs;
    final prev = _devices[o.key];
    if (prev == null && o.kind == RadioKind.ble) pairingFlood.consider(o, now);
    var trail = prev?.obs.gpsTrail ?? const <GpsSample>[];
    for (final s in o.gpsTrail) {
      trail = appendTrail(trail, s, _trailCap);
    }
    final merged = (prev == null ? o : prev.obs.merge(o)).withTrail(trail);
    final sigs = _engine?.match(merged) ?? const <Signature>[];
    _devices[o.key] = ClassifiedDevice(merged, sigs, {...?prev?.sources, if (source.isNotEmpty) source});
    if (_devices.length > maxDevices) _evictOldest();
    _dirty = true;
  }

  static List<GpsSample> appendTrail(List<GpsSample> trail, GpsSample s, int cap) {
    if (trail.isNotEmpty) {
      final last = trail.last;
      final d = geoMeters(last.lat, last.lon, s.lat, s.lon);
      if (d < 8.0) return trail;
      if (d < 18.0 && s.atMs - last.atMs < 30000) return trail;
    }
    final next = [...trail, s];
    if (next.length <= cap) return next;
    final lastIdx = next.length - 1;
    final out = <GpsSample>[];
    for (var i = 0; i < cap; i++) {
      final p = next[(i * lastIdx) ~/ (cap - 1)];
      if (out.isEmpty || out.last.atMs != p.atMs) out.add(p);
    }
    if (out.last.atMs != next.last.atMs) out.add(next.last);
    return out;
  }

  void _evictOldest() {
    String? oldest;
    var at = 1 << 62;
    _devices.forEach((k, v) {
      if (v.obs.lastSeenMs < at) {
        at = v.obs.lastSeenMs;
        oldest = k;
      }
    });
    if (oldest != null) _devices.remove(oldest);
  }

  void _onTick() {
    final had = pairingFlood.notice;
    pairingFlood.tick(DateTime.now().millisecondsSinceEpoch);
    if (_dirty || !identical(had, pairingFlood.notice)) {
      _dirty = false;
      notifyListeners();
    }
  }

  bool withYou(ClassifiedDevice d) =>
      CoTravel.withYou(d.obs, CoTravelCtx.of(_path), DateTime.now().millisecondsSinceEpoch);

  TrackerKind? trackerKind(ClassifiedDevice d) => TrackerMatch.kind(d.obs, d.signatureNames);

  void clear() {
    _devices.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    for (final s in _sources) {
      s.dispose();
    }
    super.dispose();
  }
}

final phoneBleSourceProvider = Provider<PhoneBleSource>((ref) {
  final gps = ref.read(gpsProvider);
  final src = PhoneBleSource(here: () {
    final p = gps.lastPosition;
    return p == null ? null : GpsSample(0, p.latitude, p.longitude);
  });
  SharedPreferences.getInstance().then((p) => src.setActive(p.getBool(DeviceRegistry.phoneScanPref) ?? false));
  ref.onDispose(src.dispose);
  return src;
});

final deviceRegistryProvider = ChangeNotifierProvider<DeviceRegistry>((ref) {
  final reg = DeviceRegistry();
  reg.loadCatalog();
  reg.attach(EspDetectionSource(ref.read(bleManagerProvider).detections));
  reg.attach(ref.read(phoneBleSourceProvider));
  final gps = ref.read(gpsProvider);
  final sub = gps.positionStream.listen(
    (p) => reg.recordPhoneFix(p.latitude, p.longitude, DateTime.now().millisecondsSinceEpoch),
  );
  ref.onDispose(sub.cancel);
  return reg;
});
