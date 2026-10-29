// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';
import 'package:oui_spy/core/ble/gatt_uuids.dart';
import 'package:oui_spy/core/ble/wd_log_packets.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/detector_signatures.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/features/pcap/pcap_stats.dart';
import 'package:oui_spy/core/watchlist_state.dart';

/// One step of an offline wardrive transfer from the board.
class WdLogEvent {
  const WdLogEvent.header(this.total, this.boardFull)
      : rows = const [], done = false, aborted = false;
  const WdLogEvent.rows(this.rows)
      : total = 0, boardFull = false, done = false, aborted = false;
  const WdLogEvent.done()
      : rows = const [], total = 0, boardFull = false, done = true, aborted = false;
  const WdLogEvent.aborted()
      : rows = const [], total = 0, boardFull = false, done = false, aborted = true;

  final List<WdLogRow> rows;
  final int total;
  final bool boardFull;
  final bool done;
  final bool aborted;
  bool get isHeader => !done && !aborted && rows.isEmpty;
}

class SpoolImportProgress {
  final int seen;
  final int total;
  final int dropped;
  final bool done;
  final bool aborted;
  final Map<String, int> byEngine;
  const SpoolImportProgress({
    required this.seen,
    required this.total,
    required this.dropped,
    required this.done,
    required this.aborted,
    this.byEngine = const {},
  });
}

/// BLE connection state.
enum NodeConnectionState {
  disconnected,
  scanning,
  connecting,
  negotiating,
  syncing,
  ready,
  reconnecting,
}

/// Companion-link protocol version this build understands. Must track
/// OUISPY_BLE_PROTO_VERSION in the firmware's protocol.h.
const int kSupportedProtoVersion = 1;

/// Whether the board restarted since the app last saw it, from the boot epoch
/// reported in deviceInfo.
///
/// A restart means nothing the app pushed still stands, so it must re-assert
/// its desired state rather than adopt what it reads back. An empty [reported]
/// is firmware too old to carry the epoch: it cannot prove it kept running, so
/// it is treated as restarted — the safe direction, since re-asserting state
/// the board already has is harmless, while adopting state it has lost is not.
bool boardRestartedFrom(String reported, String lastSeen) =>
    reported.isEmpty || reported != lastSeen;

class BleManager {
  BleManager();

  BluetoothDevice? _device;
  BluetoothDevice? _lastDevice;
  BluetoothCharacteristic? _engineControl;
  BluetoothCharacteristic? _detectionEvents;
  BluetoothCharacteristic? _deviceStatus;
  BluetoothCharacteristic? _gpsReceive;
  BluetoothCharacteristic? _hardwareConfig;
  BluetoothCharacteristic? _alertConfig;
  BluetoothCharacteristic? _ignoreList;
  BluetoothCharacteristic? _melody;
  BluetoothCharacteristic? _pairing;
  BluetoothCharacteristic? _nodeRadio;
  BluetoothCharacteristic? _foxhunterRssi;
  BluetoothCharacteristic? _unipwnCommand;
  BluetoothCharacteristic? _foxhunterConfig;
  BluetoothCharacteristic? _meshConfig;
  BluetoothCharacteristic? _meshStatus;
  BluetoothCharacteristic? _dfuControl;
  BluetoothCharacteristic? _dfuData;
  BluetoothCharacteristic? _systemControl;
  BluetoothCharacteristic? _wifiConfig;
  BluetoothCharacteristic? _pcapStats;
  BluetoothCharacteristic? _pcapData;
  BluetoothCharacteristic? _detectorConfig;
  List<WatchlistEntry> Function()? _watchlistGetter;

  void setWatchlistGetter(List<WatchlistEntry> Function() getter) {
    _watchlistGetter = getter;
  }

  int Function()? _sigMaskGetter;

  void setDetectorSigMaskGetter(int Function() getter) {
    _sigMaskGetter = getter;
  }

  final _connectionState = StreamController<NodeConnectionState>.broadcast();
  final _detections = StreamController<Detection>.broadcast();
  final _foxhunterRssiStream = StreamController<({int rssi, int intervalMs})>.broadcast();
  final _engineStates = StreamController<({int available, int active, List<EngineState> states})>.broadcast();
  final _meshStatusStream = StreamController<({bool enabled, int peerCount, int connectedPeers, int rxCount, int txCount, List<({String id, int role, int activeEngines, int fwVersion, String board})> liveNodes})>.broadcast();
  final _pcapStatsStream = StreamController<PcapStats>.broadcast();
  final _pcapDataStream = StreamController<Uint8List>.broadcast();
  PcapStats _latestPcapStats = PcapStats.empty;

  final _importedDetections = StreamController<Detection>.broadcast();
  Stream<Detection> get importedDetections => _importedDetections.stream;

  final _awayLiveDetections = StreamController<Detection>.broadcast();
  Stream<Detection> get awayLiveDetections => _awayLiveDetections.stream;

  final _wdLog = StreamController<WdLogEvent>.broadcast();
  /// The board's offline wardrive log, as it arrives after a request.
  Stream<WdLogEvent> get wdLogImport => _wdLog.stream;
  Timer? _wdLogTimer;

  final _spoolImport = StreamController<SpoolImportProgress>.broadcast();
  Stream<SpoolImportProgress> get spoolImport => _spoolImport.stream;

  final _awayImport = StreamController<SpoolImportProgress>.broadcast();
  Stream<SpoolImportProgress> get awayImport => _awayImport.stream;

  bool _offlineScanEnabled = false;
  bool get offlineScanEnabled => _offlineScanEnabled;

  bool wardriveSessionActive = false;

  bool _importing = false;
  int _awaySeen = 0;
  final Map<String, int> _awayByEngine = {};
  Timer? _awaySettle;
  int _importTotal = 0;
  int _importSeen = 0;
  int _importDropped = 0;
  int _importDeviceNow = 0;
  int get importDeviceNowMs => _importDeviceNow;
  Timer? _importTimer;

  // WiFi OTA progress notifications: opcode 0x06, status[1], bytes[4 LE]
  final _wifiOtaStream = StreamController<({int status, int bytesRead})>.broadcast();
  Stream<({int status, int bytesRead})> get wifiOtaUpdates => _wifiOtaStream.stream;

  // Fleet (mesh byte-relay) OTA progress: opcode 0x08, phase[1], pct[1], done[1], seen[1]
  final _fleetOtaStream =
      StreamController<({int phase, int pct, int done, int seen})>.broadcast();
  Stream<({int phase, int pct, int done, int seen})> get fleetOtaUpdates =>
      _fleetOtaStream.stream;

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  int _mtu = 23;
  String _sessionId = '';
  String _nodeId = '';
  String _board = '';
  String _role = '';
  String? _lastDeviceId;
  String? _primaryDeviceId;
  bool _userInitiatedDisconnect = false;
  bool _isReconnect = false;

  // -- Boot identity (see deviceInfo fields [5]..[7]) --
  //
  // After a BLE drop the app cannot otherwise tell "the link blipped, the board
  // kept scanning" from "the board rebooted and lost everything we pushed".
  // Reading back the engine mask does not settle it — a rebooted board reports
  // a plausible-looking mask of zero. The boot epoch does settle it: it is
  // random per boot, so a change means nothing we pushed still stands.
  String _bootEpoch = '';
  String _lastBootEpoch = '';
  int _bootCount = 0;
  int _protoVersion = 0;

  /// True when the board has restarted since the previous connection, so the
  /// app must re-push its desired state instead of adopting what it reads.
  /// Also true on the first connection of a session, where there is nothing to
  /// adopt — re-pushing is the safe default either way.
  bool boardRestarted = true;

  int get bootCount => _bootCount;
  int get protoVersion => _protoVersion;

  /// Serialises app->board GATT writes. flutter_blue_plus surfaces concurrent
  /// writes as "GATT operation already in progress"; the reconnect burst
  /// (engine mask + ignore list + radio roles) is exactly when several fire at
  /// once, so every write in this class goes through one chain.
  Future<void> _writeChain = Future<void>.value();

  /// How long a single GATT write may take before we stop waiting on it.
  ///
  /// Writes are chained so only one is outstanding at a time, which the
  /// Android stack requires. Without a bound, one write that never completes
  /// parks every later write behind it for the life of the connection — the
  /// app stays "connected", the UI keeps accepting taps, and nothing reaches
  /// the board. Ten seconds is far longer than a healthy write (tens of
  /// milliseconds) and short enough to recover inside one user action.
  static const Duration kWriteTimeout = Duration(seconds: 10);

  Future<void> _serialWrite(BluetoothCharacteristic c, List<int> value,
      {bool withoutResponse = false, Duration? timeout}) {
    final next = _writeChain.then((_) async {
      await c.write(value, withoutResponse: withoutResponse).timeout(
        timeout ?? kWriteTimeout,
        onTimeout: () {
          DebugLog.log('BLE: write to ${c.uuid} timed out — releasing the queue');
          throw TimeoutException('GATT write timed out', timeout ?? kWriteTimeout);
        },
      );
    });
    // Keep the chain alive even if one write throws, or every later write on
    // this connection would inherit the failure.
    _writeChain = next.catchError((Object _) {});
    return next;
  }

  // -- Public streams --

  Stream<NodeConnectionState> get connectionState => _connectionState.stream;
  Stream<Detection> get detections => _detections.stream;
  Stream<({int rssi, int intervalMs})> get foxhunterRssi => _foxhunterRssiStream.stream;
  Stream<({int available, int active, List<EngineState> states})> get engineStates =>
      _engineStates.stream;
  Stream<({bool enabled, int peerCount, int connectedPeers, int rxCount, int txCount, List<({String id, int role, int activeEngines, int fwVersion, String board})> liveNodes})> get meshStatusUpdates =>
      _meshStatusStream.stream;
  Stream<PcapStats> get pcapStats => _pcapStatsStream.stream;
  Stream<Uint8List> get pcapData => _pcapDataStream.stream;
  PcapStats get latestPcapStats => _latestPcapStats;

  File? _pcapFile;
  IOSink? _pcapSink;
  int _pcapBytesWritten = 0;
  Uint8List _pcapRx = Uint8List(0);
  int _pcapRxStart = 0;
  bool _pcapPrevActive = false;

  final _pcapBytesStream = StreamController<int>.broadcast();
  final _pcapSavedStream = StreamController<File>.broadcast();
  Stream<int> get pcapBytesWritten => _pcapBytesStream.stream;
  Stream<File> get pcapCaptureSaved => _pcapSavedStream.stream;
  File? get currentPcapFile => _pcapFile;
  int get pcapBytesWrittenLatest => _pcapBytesWritten;

  Future<void> abortActivePcap() async {
    try {
      await stopPcap();
    } on Exception {
      // proceed to close locally regardless
    }
    await _closePcapFile(silent: true);
  }

  static const int _kPcapLtWifi = 127;
  static const int _kPcapLtBle = 256;
  static const int _kPcapSnap = 2500;
  static const int _kPcapMagic = 0xCAFEBABE;
  static const int _kPcapEnd = 0xDEADBEEF;

  Future<Directory> _pcapDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/pcaps');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Uint8List _buildPcapHeader(int linkType) {
    final bd = ByteData(24);
    bd.setUint32(0, 0xa1b2c3d4, Endian.little);
    bd.setUint16(4, 2, Endian.little);
    bd.setUint16(6, 4, Endian.little);
    bd.setInt32(8, 0, Endian.little);
    bd.setUint32(12, 0, Endian.little);
    bd.setUint32(16, _kPcapSnap, Endian.little);
    bd.setUint32(20, linkType, Endian.little);
    return bd.buffer.asUint8List();
  }

  Future<void> _openPcapFile(int mode, {PcapStats? stats}) async {
    await _closePcapFile(silent: true);
    final dir = await _pcapDir();
    final ts = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now().toLocal());
    final suffix = mode == 1 ? 'ble' : 'wifi';
    String name;
    if (stats != null && stats.isAutoTriggered) {
      final macFlat = stats.autoTriggerMac
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      name = 'ouispy_${ts}_${macFlat}_${stats.autoTriggerEngineName}_$suffix.pcap';
    } else {
      name = 'oui_spy_${suffix}_$ts.pcap';
    }
    _pcapFile = File('${dir.path}/$name');
    _pcapSink = _pcapFile!.openWrite(mode: FileMode.writeOnly);
    final lt = mode == 1 ? _kPcapLtBle : _kPcapLtWifi;
    _pcapSink!.add(_buildPcapHeader(lt));
    _pcapBytesWritten = 24;
    _pcapRx = Uint8List(0);
    _pcapRxStart = 0;
    _pcapBytesStream.add(_pcapBytesWritten);
  }

  Future<void> _closePcapFile({bool silent = false}) async {
    if (_pcapSink == null) {
      _pcapFile = null;
      return;
    }
    final f = _pcapFile;
    final bytes = _pcapBytesWritten;
    try {
      await _pcapSink!.flush();
      await _pcapSink!.close();
    } on Exception catch (e) {
      DebugLog.log('pcap close error: $e');
    }
    _pcapSink = null;
    _pcapRx = Uint8List(0);
    _pcapRxStart = 0;
    if (!silent && f != null && bytes > 24) {
      _pcapSavedStream.add(f);
    }
    _pcapFile = null;
  }

  void _handlePcapStatsTransition(PcapStats stats) {
    final active = stats.state == 1;
    if (active && !_pcapPrevActive) {
      _openPcapFile(stats.mode, stats: stats);
    } else if (!active && _pcapPrevActive) {
      _closePcapFile();
    }
    _pcapPrevActive = active;
  }

  void _ingestPcapBytes(Uint8List bytes) {
    if (_pcapSink == null || bytes.isEmpty) return;
    final avail = _pcapRx.length - _pcapRxStart;
    final needed = avail + bytes.length;
    if (_pcapRxStart > 0 && _pcapRx.length - avail >= 4096) {
      final compact = Uint8List(needed);
      compact.setRange(0, avail, _pcapRx, _pcapRxStart);
      compact.setRange(avail, needed, bytes);
      _pcapRx = compact;
      _pcapRxStart = 0;
    } else if (_pcapRx.length < _pcapRxStart + needed) {
      int cap = _pcapRx.isEmpty ? 4096 : _pcapRx.length * 2;
      while (cap < _pcapRxStart + needed) {
        cap *= 2;
      }
      final grown = Uint8List(cap);
      grown.setRange(0, _pcapRx.length, _pcapRx);
      _pcapRx = grown;
    }
    _pcapRx.setRange(_pcapRxStart + avail, _pcapRxStart + needed, bytes);
    final end = _pcapRxStart + needed;

    int i = _pcapRxStart;
    int totalWritten = 0;
    while (true) {
      while (end - i >= 4) {
        final m = _pcapRx[i] |
            (_pcapRx[i + 1] << 8) |
            (_pcapRx[i + 2] << 16) |
            (_pcapRx[i + 3] << 24);
        if (m == _kPcapMagic) break;
        i++;
      }
      if (end - i < 8) break;
      final recLen = _pcapRx[i + 4] |
          (_pcapRx[i + 5] << 8) |
          (_pcapRx[i + 6] << 16) |
          (_pcapRx[i + 7] << 24);
      if (recLen < 16 || recLen > _kPcapSnap + 16) {
        i++;
        continue;
      }
      if (end - i < 8 + recLen + 4) break;
      final endOff = i + 8 + recLen;
      final endMark = _pcapRx[endOff] |
          (_pcapRx[endOff + 1] << 8) |
          (_pcapRx[endOff + 2] << 16) |
          (_pcapRx[endOff + 3] << 24);
      if (endMark != _kPcapEnd) {
        i++;
        continue;
      }
      final rec = Uint8List.sublistView(_pcapRx, i + 8, i + 8 + recLen);
      _pcapSink!.add(rec);
      totalWritten += recLen;
      i += 8 + recLen + 4;
    }
    _pcapRxStart = i;
    if (_pcapRxStart >= end) {
      _pcapRxStart = 0;
      _pcapRx = Uint8List(0);
    }
    if (totalWritten > 0) {
      _pcapBytesWritten += totalWritten;
      _pcapBytesStream.add(_pcapBytesWritten);
    }
  }

  NodeConnectionState _currentState = NodeConnectionState.disconnected;

  bool get isConnected =>
      _currentState == NodeConnectionState.ready ||
      (_device?.isConnected ?? false);

  NodeConnectionState get currentConnectionState => _currentState;
  String get nodeId => _nodeId;
  String get board => _board;
  bool get isC5 => _board.endsWith('c5');
  String get role => _role;
  String? get connectedDeviceId => _primaryDeviceId ?? _lastDeviceId;
  bool get isManagerConnected =>
      _role == 'mgr' ||
      (_role.isEmpty &&
          _nameSaysManager(_device?.platformName ?? ''));

  /// The advertised name was renamed from OUI-SPY to OUI-SNITCH. The old name
  /// is still accepted so a board that has not been reflashed is recognised.
  static bool nameIsOurBoard(String name) {
    final n = name.toUpperCase();
    return n.contains('OUI-SNITCH') || n.contains('OUI-SPY');
  }

  static bool _nameSaysManager(String name) =>
      name.toUpperCase().contains('-MGR');

  /// Set while a reconnect is aimed at a board found by role rather than by
  /// address: the node id it must turn out to be, checked once the link is up.
  String? _reconnectExpectNodeId;
  /// Addresses a role scan has already offered and been wrong about, so a
  /// second board in range is not retried forever.
  final Set<String> _reconnectRejected = {};

  /// Find a board of the same role as the one we lost. Every scan result is
  /// already one of ours — startScan filters on our service UUID — so the only
  /// question is node or manager. Matched on the name's -MGR suffix rather than
  /// the product name, which is being renamed.
  Future<BluetoothDevice?> _scanForSameRole(bool mgr,
      {required Set<String> exclude,
      Duration timeout = const Duration(seconds: 6)}) async {
    final completer = Completer<BluetoothDevice?>();
    final sub = scanResults.listen((results) {
      for (final r in results) {
        if (exclude.contains(r.device.remoteId.toString())) continue;
        final n = '${r.device.platformName} ${r.advertisementData.advName}'
            .trim()
            .toUpperCase();
        // A board with a bonded phone advertises without its name, so the name
        // can only rule a candidate out when there is one. The node-id check
        // after connecting is what actually decides.
        if (n.isNotEmpty && n.contains('-MGR') != mgr) continue;
        if (!completer.isCompleted) completer.complete(r.device);
      }
    });
    try {
      await startScan(timeout: timeout);
    } on Exception catch (e) {
      DebugLog.log('BLE: role scan error $e');
    }
    final found = await completer.future
        .timeout(timeout + const Duration(seconds: 2), onTimeout: () => null);
    await sub.cancel();
    await stopScan();
    return found;
  }

  void markAsPrimary() {
    _primaryDeviceId = _lastDeviceId;
    final id = _primaryDeviceId;
    if (id != null && id.isNotEmpty) {
      final mgr = isManagerConnected;
      SharedPreferences.getInstance().then((p) {
        p.setString('lastPrimaryDeviceId', id);
        p.setBool('lastPrimaryIsManager', mgr);
      });
    }
  }

  /// Get a discovered characteristic by UUID (for direct read/write).
  BluetoothCharacteristic? getCharacteristic(Guid uuid) {
    if (uuid == GattUuids.engineControl) return _engineControl;
    if (uuid == GattUuids.detectionEvents) return _detectionEvents;
    if (uuid == GattUuids.deviceStatus) return _deviceStatus;
    if (uuid == GattUuids.gpsReceive) return _gpsReceive;
    if (uuid == GattUuids.hardwareConfig) return _hardwareConfig;
    if (uuid == GattUuids.alertConfig) return _alertConfig;
    if (uuid == GattUuids.ignoreList) return _ignoreList;
    if (uuid == GattUuids.nodeRadio) return _nodeRadio;
    if (uuid == GattUuids.foxhunterRssi) return _foxhunterRssi;
    if (uuid == GattUuids.foxhunterConfig) return _foxhunterConfig;
    if (uuid == GattUuids.meshConfig) return _meshConfig;
    if (uuid == GattUuids.meshStatus) return _meshStatus;
    if (uuid == GattUuids.deviceInfo) return _deviceInfoChar;
    if (uuid == GattUuids.dfuControl) return _dfuControl;
    if (uuid == GattUuids.dfuData) return _dfuData;
    if (uuid == GattUuids.systemControl) return _systemControl;
    if (uuid == GattUuids.wifiConfig) return _wifiConfig;
    return null;
  }

  int get mtu => _mtu;
  BluetoothCharacteristic? get dfuControl => _dfuControl;
  BluetoothCharacteristic? get dfuData => _dfuData;
  BluetoothCharacteristic? get systemControl => _systemControl;
  BluetoothCharacteristic? get wifiConfig => _wifiConfig;

  BluetoothCharacteristic? _deviceInfoChar;

  // -- GPS state for stamping detections --

  double? _lastLat;
  double? _lastLon;
  double? _lastAccuracy;
  int? _lastSatCount;

  void updateGps({
    required double latitude,
    required double longitude,
    double? accuracy,
    int? satelliteCount,
  }) {
    _lastLat = latitude;
    _lastLon = longitude;
    _lastAccuracy = accuracy;
    _lastSatCount = satelliteCount;
  }

  // -- Scanning --

  /// Scan for our boards. Results arrive on FlutterBluePlus.onScanResults.
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    // Ensure BLE adapter is on
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
    }

    await FlutterBluePlus.startScan(withServices: [GattUuids.service], timeout: timeout);
  }

  /// Stream of scan results (list updated each scan cycle).
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.onScanResults;

  Future<void> stopScan() async => FlutterBluePlus.stopScan();

  Future<BluetoothDevice?> scanForDeviceNamed(String exactName,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final target = exactName.toUpperCase();
    final completer = Completer<BluetoothDevice?>();
    final sub = scanResults.listen((results) {
      for (final r in results) {
        final n = r.device.platformName.toUpperCase();
        final a = r.advertisementData.advName.toUpperCase();
        if ((n == target || a == target) && !completer.isCompleted) {
          completer.complete(r.device);
        }
      }
    });
    try {
      await startScan(timeout: timeout);
    } on Exception catch (e) {
      DebugLog.log('BLE: scanForDeviceNamed scan error $e');
    }
    final found = await completer.future
        .timeout(timeout + const Duration(seconds: 2), onTimeout: () => null);
    await sub.cancel();
    await stopScan();
    return found;
  }

  Future<BluetoothDevice?> _scanForRemoteId(String remoteId,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final completer = Completer<BluetoothDevice?>();
    final sub = scanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId.toString() == remoteId && !completer.isCompleted) {
          completer.complete(r.device);
        }
      }
    });
    try {
      await startScan(timeout: timeout);
    } on Exception catch (e) {
      DebugLog.log('BLE: reconnect scan error $e');
    }
    final found = await completer.future
        .timeout(timeout + const Duration(seconds: 2), onTimeout: () => null);
    await sub.cancel();
    await stopScan();
    return found;
  }

  Future<bool> connectAndReady(BluetoothDevice device,
      {Duration timeout = const Duration(seconds: 25)}) async {
    final completer = Completer<bool>();
    final sub = connectionState.listen((s) {
      if (s == NodeConnectionState.ready && !completer.isCompleted) {
        completer.complete(true);
      } else if (s == NodeConnectionState.disconnected &&
          !completer.isCompleted) {
        completer.complete(false);
      }
    });
    try {
      await connect(device,
          sessionId: 'ota-${DateTime.now().microsecondsSinceEpoch}');
      markAsPrimary();
    } on Exception catch (e) {
      DebugLog.log('BLE: connectAndReady connect error $e');
      if (!completer.isCompleted) completer.complete(false);
    }
    final ok =
        await completer.future.timeout(timeout, onTimeout: () => isConnected);
    await sub.cancel();
    return ok;
  }

  /// Reconnect to a previously-seen device by its remoteId (no scan needed).
  Future<bool> connectByIdAndReady(String remoteId,
      {Duration timeout = const Duration(seconds: 25)}) async {
    try {
      return await connectAndReady(BluetoothDevice.fromId(remoteId),
          timeout: timeout);
    } on Exception catch (e) {
      DebugLog.log('BLE: connectByIdAndReady error $e');
      return false;
    }
  }

  // -- Connection --

  /// Connect to a specific device and set up GATT subscriptions.
  /// Raised when the board refuses the pairing, so the UI can say something
  /// more useful than a GATT error number.
  final _pairingFailures = StreamController<String>.broadcast();
  Stream<String> get pairingFailures => _pairingFailures.stream;

  /// Every characteristic on the board needs an authenticated, encrypted link,
  /// so pairing has to finish before service discovery — otherwise discovery
  /// comes back with the characteristics but every read fails.
  ///
  /// Android raises the passkey prompt on its own the first time it touches an
  /// encrypted attribute, but doing it here means the prompt appears while the
  /// UI is still saying "pairing" rather than part-way through a sync.
  Future<void> _ensureBonded(BluetoothDevice device) async {
    if (!Platform.isAndroid) return; // iOS prompts by itself; nothing to drive.
    try {
      await device.createBond();
      DebugLog.log('BLE: bonded');
    } on FlutterBluePlusException catch (e) {
      // A board that has been factory reset has forgotten its keys while the
      // phone still holds a bond for it. That pairing can never succeed, so
      // drop our side and let the next attempt start clean.
      DebugLog.log('BLE: bonding failed (${e.description}) — clearing stale bond');
      try {
        await device.removeBond();
      } on FlutterBluePlusException catch (e2) {
        DebugLog.log('BLE: removeBond also failed: ${e2.description}');
      }
      _pairingFailures.add(
        'Pairing failed. A new board uses the passkey 123456. If you changed '
        'it under Settings > Node, enter that instead. A board that has been '
        'factory reset is back to the default.',
      );
      // Deliberately not fatal. Firmware from before pairing was introduced
      // requires no encryption, and bonding against it can fail harmlessly —
      // refusing to continue would strand anyone who has not reflashed. If the
      // board really does require pairing, discovery fails next and the user
      // has already been told why.
    }
  }

  Future<void> connect(BluetoothDevice device,
      {required String sessionId, bool useAutoConnect = false}) async {
    if (_connecting) {
      DebugLog.log('BLE: connect in flight — ignoring duplicate ${device.remoteId}');
      return;
    }
    _connecting = true;
    try {
      await _doConnect(device, sessionId: sessionId, useAutoConnect: useAutoConnect);
    } finally {
      _connecting = false;
      _isReconnect = false;
    }
  }

  /// How long to let the operating system hold a pending connection before
  /// falling back to scanning for the board ourselves.
  ///
  /// The OS attempt costs nothing while it waits, so this is generous. It
  /// exists only for the cases autoConnect cannot serve — chiefly a board that
  /// comes back on a different address, which the controller will never match.
  static const Duration kOsReconnectWindow = Duration(seconds: 60);

  Future<void> _doConnect(BluetoothDevice device,
      {required String sessionId, bool useAutoConnect = false}) async {
    // Clean up previous subscriptions to prevent reconnect storm
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _reconnectTimer?.cancel();
    _stopLinkWatchdog();

    _sessionId = sessionId;
    _device = device;
    _userInitiatedDisconnect = false;
    _currentState = NodeConnectionState.connecting; _connectionState.add(NodeConnectionState.connecting);

    _lastDeviceId = device.remoteId.toString();
    DebugLog.log('BLE: connecting to ${device.remoteId}'
        '${useAutoConnect ? ' (os autoConnect)' : ''}');
    if (useAutoConnect) {
      // Hand recovery to the Bluetooth controller. It holds the connection
      // pending and completes it the instant the board advertises again —
      // no scanning, no polling, no worst-case wait, and it keeps working
      // while the app is backgrounded. autoConnect takes no timeout and
      // forbids an MTU argument, so the wait is ours to bound.
      await device.connect(autoConnect: true, mtu: null);
      final reached = await device.connectionState
          .firstWhere((s) => s == BluetoothConnectionState.connected)
          .timeout(kOsReconnectWindow,
              onTimeout: () => BluetoothConnectionState.disconnected);
      if (reached != BluetoothConnectionState.connected) {
        // Stand the pending connection down before anything else tries.
        await device.disconnect();
        throw TimeoutException(
            'autoConnect window elapsed', kOsReconnectWindow);
      }
    } else {
      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 15),
      );
    }
    DebugLog.log('BLE: connected');
    if (_userInitiatedDisconnect || _device != device) {
      DebugLog.log('BLE: disconnect requested during connect — aborting');
      await device.disconnect();
      return;
    }

    _subscriptions.add(
      device.connectionState.listen((state) {
        DebugLog.log('BLE: connectionState=$state');
        if (state == BluetoothConnectionState.disconnected) {
          _stopLinkWatchdog();
          _currentState = NodeConnectionState.disconnected; _connectionState.add(NodeConnectionState.disconnected);
          if (_importing) {
            _abortImport();
          }
          if (_userInitiatedDisconnect) {
            DebugLog.log('BLE: skipping reconnect (user-initiated)');
            _userInitiatedDisconnect = false;
          } else {
            _startReconnect();
          }
        }
      }),
    );

    _currentState = NodeConnectionState.negotiating; _connectionState.add(NodeConnectionState.negotiating);

    await _ensureBonded(device);
    if (_userInitiatedDisconnect || _device != device) {
      DebugLog.log('BLE: disconnect requested during pairing — aborting');
      return;
    }

    try {
      _mtu = await device.requestMtu(512);
      DebugLog.log('BLE: MTU negotiated=$_mtu');
    } on FlutterBluePlusException catch (e) {
      DebugLog.log('BLE: requestMtu unsupported (${e.description}) — reading actual');
      // iOS auto-negotiates; mtuNow is populated after connect.
      _mtu = device.mtuNow;
      DebugLog.log('BLE: MTU (auto)=$_mtu');
    }
    if (_mtu < 23) {
      DebugLog.log('BLE: MTU $_mtu too low, defaulting to 23');
      _mtu = 23;
    }

    try {
      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      DebugLog.log('BLE: requested high conn priority');
    } on FlutterBluePlusException catch (e) {
      DebugLog.log('BLE: conn priority unsupported: ${e.description}');
    }

    // Discover services
    _currentState = NodeConnectionState.syncing; _connectionState.add(NodeConnectionState.syncing);
    DebugLog.log('BLE: discovering services...');
    final services = await device.discoverServices();

    for (final s in services) {
      DebugLog.log('BLE: service=${s.uuid} chars=${s.characteristics.length}');
      for (final c in s.characteristics) {
        DebugLog.log('  char=${c.uuid} props=${c.properties}');
      }
    }

    final ouiService = services.firstWhere(
      (s) => s.uuid == GattUuids.service,
      orElse: () {
        final msg = 'OUI-SNITCH service not found. Expected=${GattUuids.service} '
            'Found=${services.map((s) => s.uuid.toString()).join(", ")}';
        DebugLog.log('BLE: ERROR $msg');
        throw Exception(msg);
      },
    );
    DebugLog.log('BLE: service found');

    // Map characteristics
    for (final c in ouiService.characteristics) {
      if (c.uuid == GattUuids.engineControl) _engineControl = c;
      if (c.uuid == GattUuids.detectionEvents) _detectionEvents = c;
      if (c.uuid == GattUuids.deviceStatus) _deviceStatus = c;
      if (c.uuid == GattUuids.gpsReceive) _gpsReceive = c;
      if (c.uuid == GattUuids.hardwareConfig) _hardwareConfig = c;
      if (c.uuid == GattUuids.alertConfig) _alertConfig = c;
      if (c.uuid == GattUuids.ignoreList) _ignoreList = c;
      if (c.uuid == GattUuids.melody) _melody = c;
      if (c.uuid == GattUuids.pairing) _pairing = c;
      if (c.uuid == GattUuids.nodeRadio) _nodeRadio = c;
      if (c.uuid == GattUuids.foxhunterRssi) _foxhunterRssi = c;
      if (c.uuid == GattUuids.unipwnCommand) _unipwnCommand = c;
      if (c.uuid == GattUuids.foxhunterConfig) _foxhunterConfig = c;
      if (c.uuid == GattUuids.meshConfig) _meshConfig = c;
      if (c.uuid == GattUuids.meshStatus) _meshStatus = c;
      if (c.uuid == GattUuids.dfuControl) _dfuControl = c;
      if (c.uuid == GattUuids.dfuData) _dfuData = c;
      if (c.uuid == GattUuids.systemControl) _systemControl = c;
      if (c.uuid == GattUuids.wifiConfig) _wifiConfig = c;
      if (c.uuid == GattUuids.pcapStats) _pcapStats = c;
      if (c.uuid == GattUuids.pcapData) _pcapData = c;
      if (c.uuid == GattUuids.detectorConfig) _detectorConfig = c;
    }

    // Read device info to get node ID
    _deviceInfoChar = ouiService.characteristics.firstWhere(
      (c) => c.uuid == GattUuids.deviceInfo,
    );
    final infoData = await _deviceInfoChar!.read();
    final parts = _parseDeviceInfo(infoData);
    _nodeId = parts.length > 1 ? parts[1] : '';
    _board = parts.length > 2 ? parts[2] : '';
    _role = parts.length > 3 ? parts[3] : '';

    // A role scan can only say "a board of the right kind"; the node id says
    // which one. Reaching the wrong board is not a failure to retry — it is
    // someone else's device, so it is put down untouched and not offered again.
    final expectNodeId = _reconnectExpectNodeId;
    if (expectNodeId != null && _nodeId != expectNodeId) {
      DebugLog.log('BLE: reconnect reached $_nodeId, expected $expectNodeId — '
          'dropping it untouched');
      _reconnectRejected.add(device.remoteId.toString());
      for (final sub in _subscriptions) {
        await sub.cancel();
      }
      _subscriptions.clear();
      await device.disconnect();
      _currentState = NodeConnectionState.reconnecting;
      _connectionState.add(NodeConnectionState.reconnecting);
      throw Exception('reconnect: different board');
    }
    _reconnectRejected.clear();

    // Fields [5]..[7] are absent on firmware older than this handshake. Treat
    // that as "cannot prove it kept running" and re-push, which is what the
    // app did unconditionally before the epoch existed.
    _bootEpoch = parts.length > 5 ? parts[5] : '';
    _bootCount = parts.length > 6 ? (int.tryParse(parts[6]) ?? 0) : 0;
    _protoVersion = parts.length > 7 ? (int.tryParse(parts[7]) ?? 0) : 0;
    boardRestarted = boardRestartedFrom(_bootEpoch, _lastBootEpoch);
    if (_protoVersion > kSupportedProtoVersion) {
      DebugLog.log('BLE: WARNING board protocol v$_protoVersion is newer than '
          'this app (v$kSupportedProtoVersion) — fields may not decode');
    }
    DebugLog.log('BLE: nodeId=$_nodeId board=$_board role=$_role '
        'proto=$_protoVersion boot=$_bootEpoch#$_bootCount '
        'restarted=$boardRestarted');
    _lastBootEpoch = _bootEpoch;
    await _readDeviceConfig();

    // Subscribe to detection notifications
    if (_detectionEvents != null) {
      await _detectionEvents!.setNotifyValue(true);
      _subscriptions.add(
        _detectionEvents!.onValueReceived.listen(_onDetection),
      );
    }

    // Subscribe to engine state notifications
    if (_engineControl != null) {
      await _engineControl!.setNotifyValue(true);
      _subscriptions.add(
        _engineControl!.onValueReceived.listen((data) {
          _lastInboundAt = DateTime.now();
          _engineStates.add(BleProtocol.decodeEngineStatus(data));
        }),
      );
      final isMgr = _role == 'mgr' ||
          (_role.isEmpty &&
              _nameSaysManager(device.platformName));
      if (!isMgr && !_offlineScanEnabled && !wardriveSessionActive && !_isReconnect) {
        await _serialWrite(_engineControl!, BleProtocol.encodeDisableAll());
        DebugLog.log('BLE: sent DISABLE_ALL on fresh connect (node)');
        await Future.delayed(const Duration(milliseconds: 300));
      } else if (!isMgr && boardRestarted) {
        // Reconnect or live session, but this is a different boot: the engines
        // the app asked for are gone. Nothing to adopt — whoever owns the
        // desired state re-pushes it (see WardriveController._adoptFirmwareState).
        DebugLog.log('BLE: board restarted (boot $_bootEpoch #$_bootCount) — '
            'firmware state discarded, desired state must be re-pushed');
      } else if (!isMgr) {
        DebugLog.log('BLE: same boot $_bootEpoch — board kept running, adopting its state');
      } else {
        DebugLog.log('BLE: skipped DISABLE_ALL on connect (manager)');
      }
      final refreshed = await _engineControl!.read();
      _engineStates.add(BleProtocol.decodeEngineStatus(refreshed));
    }

    // Subscribe to foxhunter RSSI
    if (_foxhunterRssi != null) {
      await _foxhunterRssi!.setNotifyValue(true);
      _subscriptions.add(
        _foxhunterRssi!.onValueReceived.listen((data) {
          _foxhunterRssiStream.add(BleProtocol.decodeFoxhunterRssi(data));
        }),
      );
    }

    // Subscribe to mesh status
    if (_meshStatus != null) {
      await _meshStatus!.setNotifyValue(true);
      _subscriptions.add(
        _meshStatus!.onValueReceived.listen((data) {
          _meshStatusStream.add(BleProtocol.decodeMeshStatus(data));
        }),
      );
    }


    if (_pcapStats != null) {
      await _pcapStats!.setNotifyValue(true);
      _subscriptions.add(
        _pcapStats!.onValueReceived.listen((data) {
          final stats = PcapStats.decode(data);
          if (stats != null) {
            _latestPcapStats = stats;
            _pcapStatsStream.add(stats);
            _handlePcapStatsTransition(stats);
          }
        }),
      );
    }

    if (_pcapData != null) {
      await _pcapData!.setNotifyValue(true);
      _subscriptions.add(
        _pcapData!.onValueReceived.listen((data) {
          final bytes = Uint8List.fromList(data);
          _pcapDataStream.add(bytes);
          _ingestPcapBytes(bytes);
        }),
      );
    }

    _currentState = NodeConnectionState.ready; _connectionState.add(NodeConnectionState.ready);
    _startLinkWatchdog();

    final getter = _watchlistGetter;
    if (getter != null && _detectorConfig != null) {
      try {
        await syncDetectorWatchlist(getter());
      } catch (e) {
        DebugLog.log('BLE: watchlist sync failed: $e');
      }
    }

    final sigGetter = _sigMaskGetter;
    if (sigGetter != null && _detectorConfig != null) {
      try {
        await setDetectorSigMask(sigGetter());
      } catch (e) {
        DebugLog.log('BLE: sigmask sync failed: $e');
      }
    }

    if (_systemControl != null) {
      await _systemControl!.setNotifyValue(true);
      _subscriptions.add(
        _systemControl!.onValueReceived.listen((data) {
          if (data.isEmpty) return;
          if (data[0] == 0x06 && data.length >= 6) {
            final status = data[1];
            final bytes = data[2]
                | (data[3] << 8)
                | (data[4] << 16)
                | (data[5] << 24);
            _wifiOtaStream.add((status: status, bytesRead: bytes));
          } else if (data[0] == 0x08 && data.length >= 5) {
            _fleetOtaStream.add((
              phase: data[1],
              pct: data[2],
              done: data[3],
              seen: data[4],
            ));
          }
        }),
      );
    }

    if (_systemControl != null) {
      try {
        await _serialWrite(_systemControl!, 
          Uint8List.fromList([0x03]),
          withoutResponse: false,
        );
        DebugLog.log('BLE: sent OTA confirm');
      } on FlutterBluePlusException catch (e) {
        DebugLog.log('BLE: OTA confirm write failed: ${e.description}');
      }
    }

    _awaySettle?.cancel();
    _awaySeen = 0;
    _awayByEngine.clear();
    // A spool flush flips _importing on, which diverts every incoming detection
    // from the live feed into the import stream for up to 12s. During a wardrive
    // that would empty the live feed for nothing — wardrive is not spoolable
    // (no SD on this board), so there is nothing of its to import. Skip the
    // flush while wardriving; the spoolable engines import on the next connect
    // when no session is running.
    if (await _sendPendingBacklogClear()) return;
    if (_offlineScanEnabled && !wardriveSessionActive) {
      await requestSpoolFlush();
    }
    // Asked for even mid-session: these are exactly the rows recorded while
    // the board was out of reach.
    if (_offlineScanEnabled) await requestWdLog();
  }

  /// Asks the board for the wardrive rows it recorded on its own.
  Future<void> requestWdLog() async {
    if (_systemControl == null) return;
    await _serialWrite(_systemControl!, WdLogPackets.sendCmd, withoutResponse: false);
    DebugLog.log('BLE: offline wardrive log requested');
  }

  /// The rows are saved; the board may delete them.
  Future<void> confirmWdLogImported() async {
    if (_systemControl == null) throw StateError('no link to the board');
    await _serialWrite(_systemControl!, WdLogPackets.clearCmd, withoutResponse: false);
    DebugLog.log('BLE: offline wardrive log clear sent');
  }

  /// A transfer that stops arriving is abandoned; the board keeps its copy.
  void _armWdLogTimer() {
    _wdLogTimer?.cancel();
    _wdLogTimer = Timer(const Duration(seconds: 15), () {
      _wdLog.add(const WdLogEvent.aborted());
      DebugLog.log('BLE: offline wardrive transfer stalled — abandoned');
    });
  }

  static const _kBacklogClearPending = 'spool_clear_pending';

  /// Throws away what the board is holding for the phone. Used when the user
  /// clears the detection log: otherwise the board would hand the same records
  /// back on the next connect. Without a link the request waits for one.
  Future<void> clearBoardBacklog() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBacklogClearPending, true);
    if (_systemControl != null) await _sendPendingBacklogClear();
  }

  /// Sends a clear the user asked for while the board was away. Returns true
  /// when it did, so the caller skips asking for the backlog it just dropped.
  Future<bool> _sendPendingBacklogClear() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kBacklogClearPending) ?? false)) return false;
    try {
      await confirmSpoolImported();
      await prefs.remove(_kBacklogClearPending);
      DebugLog.log('BLE: board backlog cleared at the user\'s request');
      return true;
    } catch (e) {
      DebugLog.log('BLE: board backlog clear failed, will retry on reconnect: $e');
      return false;
    }
  }

  // -- System control --

  /// Reboot device. Magic bytes prevent accidental triggers.
  Future<void> rebootDevice() async {
    if (_systemControl == null) return;
    await _serialWrite(_systemControl!, 
      Uint8List.fromList([0x01, 0xC0, 0xDE]),
      withoutResponse: false,
    );
  }

  /// Power off: put the device into deep sleep (it has no self power-cut).
  /// It stays off until a physical reset / re-power. Magic bytes required.
  Future<void> powerOffDevice() async {
    if (_systemControl == null) return;
    await _serialWrite(_systemControl!, 
      Uint8List.fromList([0x0E, 0xC0, 0xDE]),
      withoutResponse: false,
    );
  }

  /// Factory reset: erase NVS and reboot. Magic bytes required.
  Future<void> factoryReset() async {
    if (_systemControl == null) return;
    await _serialWrite(_systemControl!, 
      Uint8List.fromList([0x02, 0xC0, 0xDE]),
      withoutResponse: false,
    );
  }

  /// Ask the board to ring a tracker so a hidden one can be located.
  /// User-triggered counter-surveillance; returns false if not connected.
  Future<bool> ringTracker(String mac, {int hint = 0}) async {
    if (_systemControl == null) return false;
    await _serialWrite(_systemControl!, 
      BleProtocol.ringTrackerCmd(mac, hint: hint),
      withoutResponse: false,
    );
    DebugLog.log('BLE: ring requested for $mac (hint $hint)');
    return true;
  }

  Future<void> requestSpoolFlush() async {
    if (_systemControl == null || !_offlineScanEnabled) return;
    _importing = true;
    _importSeen = 0;
    _importTotal = 0;
    _importDropped = 0;
    _importDeviceNow = 0;
    _importTimer?.cancel();
    _importTimer = Timer(const Duration(seconds: 12), _abortImport);
    await _serialWrite(_systemControl!, BleProtocol.flushSpoolCmd, withoutResponse: false);
    DebugLog.log('BLE: spool flush requested');
  }

  Future<void> confirmSpoolImported() async {
    if (_systemControl == null) {
      throw StateError('no link to the board');
    }
    await _serialWrite(_systemControl!, BleProtocol.spoolClearCmd, withoutResponse: false);
    DebugLog.log('BLE: spool clear sent after DB commit');
  }

  Future<void> writeWifiConfig(String ssid, String pass) async {
    if (_wifiConfig == null) {
      throw StateError('WiFi config characteristic not found — firmware too old');
    }
    final ssidBytes = ssid.codeUnits;
    final passBytes = pass.codeUnits;
    if (ssidBytes.length > 32) {
      throw ArgumentError('SSID too long (max 32 bytes)');
    }
    if (passBytes.length > 64) {
      throw ArgumentError('Password too long (max 64 bytes)');
    }
    final payload = Uint8List(2 + ssidBytes.length + passBytes.length);
    payload[0] = ssidBytes.length;
    payload.setRange(1, 1 + ssidBytes.length, ssidBytes);
    payload[1 + ssidBytes.length] = passBytes.length;
    payload.setRange(2 + ssidBytes.length,
                     2 + ssidBytes.length + passBytes.length, passBytes);
    await _serialWrite(_wifiConfig!, payload, withoutResponse: false);
  }

  Future<({bool hasCreds, bool connected, bool enabled, String ssid, String ip, int rssi})> readWifiConfig() async {
    const empty = (hasCreds: false, connected: false, enabled: false, ssid: '', ip: '', rssi: 0);
    if (_wifiConfig == null) return empty;
    final data = await _wifiConfig!.read();
    if (data.length < 8) return empty;
    final has = data[0] == 1;
    final connected = data[1] == 1;
    final ip = '${data[2]}.${data[3]}.${data[4]}.${data[5]}';
    final rssi = data[6] >= 128 ? data[6] - 256 : data[6];
    final ssidLen = data[7];
    if (data.length < 8 + ssidLen) {
      return (hasCreds: has, connected: connected, enabled: false, ssid: '', ip: ip, rssi: rssi);
    }
    final ssid = String.fromCharCodes(data.sublist(8, 8 + ssidLen));
    final enabled = (data.length >= 8 + ssidLen + 1) ? data[8 + ssidLen] == 1 : false;
    return (
      hasCreds: has,
      connected: connected,
      enabled: enabled,
      ssid: ssid,
      ip: connected ? ip : '',
      rssi: connected ? rssi : 0,
    );
  }

  Future<void> setWifiStaEnabled(bool enabled) async {
    if (_wifiConfig == null) return;
    await _serialWrite(_wifiConfig!, 
      Uint8List.fromList([0xF1, enabled ? 1 : 0]),
      withoutResponse: false,
    );
  }

  Future<void> wipeWifiCreds() async {
    if (_wifiConfig == null) return;
    await _serialWrite(_wifiConfig!, 
      Uint8List.fromList([0xF2]),
      withoutResponse: false,
    );
  }

  Future<void> setIgnoreList(List<int> bytes) async {
    if (_ignoreList == null) return;
    await _serialWrite(_ignoreList!, bytes, withoutResponse: false);
  }

  /// Older firmware has no pairing characteristic, so the UI hides the control
  /// rather than offering something that would silently do nothing.
  bool get hasPairingSupport => _pairing != null;

  /// The board's current passkey, and whether it is still the shipped default.
  /// Readable only because we are already paired.
  Future<({int pin, bool isDefault})?> readPairingPin() async {
    final c = _pairing;
    if (c == null) return null;
    try {
      final v = await c.read();
      if (v.length < 5) return null;
      final pin = v[0] | (v[1] << 8) | (v[2] << 16) | (v[3] << 24);
      return (pin: pin, isDefault: v[4] != 0);
    } catch (e) {
      DebugLog.log('BLE: pairing read failed: $e');
      return null;
    }
  }

  /// Change the board's passkey. Phones already bonded are unaffected; the new
  /// value applies to the next phone that pairs.
  Future<bool> writePairingPin(int pin) async {
    final c = _pairing;
    if (c == null || pin < 0 || pin > 999999) return false;
    try {
      await _serialWrite(c, [
        pin & 0xFF,
        (pin >> 8) & 0xFF,
        (pin >> 16) & 0xFF,
        (pin >> 24) & 0xFF,
      ], withoutResponse: false);
      return true;
    } catch (e) {
      DebugLog.log('BLE: pairing write failed: $e');
      return false;
    }
  }

  bool get hasMelodySupport => _melody != null;

  Future<void> writeMelodyOps(List<List<int>> ops) async {
    final c = _melody;
    if (c == null) return;
    try {
      for (final op in ops) {
        await _serialWrite(c, op, withoutResponse: false);
      }
    } catch (e) {
      DebugLog.log('BLE: melody write failed: $e');
    }
  }

  Future<void> setNodeRadioRoles(Map<String, int> roles) async {
    if (_nodeRadio == null) return;
    final valid = roles.entries.where((e) => e.key.length == 4).toList();
    if (valid.length > 255) valid.removeRange(255, valid.length);
    final bytes = <int>[valid.length];
    for (final e in valid) {
      bytes.addAll(e.key.codeUnits);
      final m = e.value & 0x03;
      bytes.add(m == 0 ? 0x03 : m);
    }
    await _serialWrite(_nodeRadio!, bytes, withoutResponse: false);
  }

  Future<void> setAutoPcap(bool enabled) async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList([0x10, enabled ? 1 : 0]),
      ),
    );
  }

  Future<void> setAutoPcapDuration(int seconds) async {
    if (_engineControl == null) return;
    final s = seconds.clamp(1, 65535);
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList([0x11, s & 0xFF, (s >> 8) & 0xFF]),
      ),
    );
  }

  Future<void> setAutoPcapCooldown(int seconds) async {
    if (_engineControl == null) return;
    final s = seconds.clamp(0, 65535);
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList([0x12, s & 0xFF, (s >> 8) & 0xFF]),
      ),
    );
  }

  Future<void> wifiDisconnect() async {
    if (_systemControl == null) return;
    await _serialWrite(_systemControl!, 
      Uint8List.fromList([0x06, 0xC0, 0xDE]),
      withoutResponse: false,
    );
  }

  Future<void> wifiWipeCreds() async {
    if (_systemControl == null) return;
    await _serialWrite(_systemControl!, 
      Uint8List.fromList([0x07, 0xC0, 0xDE]),
      withoutResponse: false,
    );
  }

  Future<void> triggerWifiOta(String url) async {
    if (_systemControl == null) {
      throw StateError('System control characteristic not found');
    }
    final urlBytes = url.codeUnits;
    final payload = Uint8List(3 + urlBytes.length);
    payload[0] = 0x04; // SYS_CMD_OTA_VIA_WIFI
    payload[1] = 0xC0;
    payload[2] = 0xDE;
    payload.setRange(3, 3 + urlBytes.length, urlBytes);
    await _serialWrite(_systemControl!, payload, withoutResponse: false);
  }

  Future<void> triggerFleetOta(String nodeUrl) async {
    if (_systemControl == null) {
      throw StateError('System control characteristic not found');
    }
    final urlBytes = nodeUrl.codeUnits;
    final payload = Uint8List(3 + urlBytes.length);
    payload[0] = 0x05; // SYS_CMD_FLEET_OTA
    payload[1] = 0xC0;
    payload[2] = 0xDE;
    payload.setRange(3, 3 + urlBytes.length, urlBytes);
    await _serialWrite(_systemControl!, payload, withoutResponse: false);
  }

  Future<void> triggerFleetWifiOta(String nodeUrl) async {
    if (_systemControl == null) {
      throw StateError('System control characteristic not found');
    }
    final urlBytes = nodeUrl.codeUnits;
    final payload = Uint8List(3 + urlBytes.length);
    payload[0] = 0x0A; // SYS_CMD_FLEET_WIFI_OTA
    payload[1] = 0xC0;
    payload[2] = 0xDE;
    payload.setRange(3, 3 + urlBytes.length, urlBytes);
    await _serialWrite(_systemControl!, payload, withoutResponse: false);
  }

  // -- Engine control --

  /// Engine writes share the one write chain with everything else — two
  /// independent chains would not serialise against each other, which is the
  /// collision this is meant to prevent.
  Future<T> _serializedEngineWrite<T>(Future<T> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> enableEngine(Engine engine, {int? radio, String? targetNodeId}) async {
    if (_engineControl == null) return;
    if (radio != null) {
      try {
        await _serializedEngineWrite(() => _engineControl!.write(
              BleProtocol.encodeEngineConfig(
                engine: engine,
                payload: Uint8List.fromList([radio]),
              ),
            ));
        await Future.delayed(const Duration(milliseconds: 50));
      } catch (e) {
        DebugLog.log('BLE: enable-radio config ${engine.name} failed: $e');
      }
    }
    try {
      await _serializedEngineWrite(() => _engineControl!.write(
            BleProtocol.encodeEngineControl(
              engine: engine, enable: true, targetNodeId: targetNodeId,
            ),
          ));
    } catch (e) {
      DebugLog.log('BLE: enableEngine ${engine.name} failed: $e');
      rethrow;
    }
    unawaited(_refreshEngineState());
  }

  Future<void> disableEngine(Engine engine, {String? targetNodeId}) async {
    if (_engineControl == null) return;
    try {
      await _serializedEngineWrite(() => _engineControl!.write(
            BleProtocol.encodeEngineControl(
              engine: engine, enable: false, targetNodeId: targetNodeId,
            ),
          ));
    } catch (e) {
      DebugLog.log('BLE: disableEngine ${engine.name} failed: $e');
      rethrow;
    }
    unawaited(_refreshEngineState());
  }

  Future<void> sendEngineConfig(Engine engine, Uint8List payload) async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(engine: engine, payload: payload),
    );
  }

  /// Push the global WiFi band mask (bit0=2.4GHz, bit1=5GHz) to all WiFi engines.
  Future<void> sendWifiBand(int mask) async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, BleProtocol.encodeWifiBand(mask));
  }

  Future<void> syncDetectorWatchlist(List<WatchlistEntry> entries) async {
    if (_detectorConfig == null) {
      DebugLog.log('BLE: detectorConfig char missing; skip watchlist sync');
      return;
    }
    await _serialWrite(_detectorConfig!, Uint8List.fromList([0x00]), withoutResponse: false);
    int pushed = 0;
    for (final e in entries) {
      if (e.isName) continue;
      if (e.isServiceUuid) {
        final uuid = _parseUuid16(e.identifier);
        if (uuid == null) continue;
        final descBytes = utf8.encode(e.description).take(28).toList();
        final pkt = <int>[0x02, uuid & 0xFF, (uuid >> 8) & 0xFF, ...descBytes];
        await _serialWrite(_detectorConfig!, Uint8List.fromList(pkt), withoutResponse: false);
        pushed++;
        continue;
      }
      final mac = _parseMac(e.identifier);
      if (mac == null) continue;
      final prefixLen = e.isFullMac ? 6 : 3;
      final descBytes = utf8.encode(e.description).take(31).toList();
      final pkt = <int>[0x01, prefixLen, ...mac, ...descBytes];
      await _serialWrite(_detectorConfig!, Uint8List.fromList(pkt), withoutResponse: false);
      pushed++;
    }
    DebugLog.log('BLE: synced $pushed/${entries.length} watchlist entries to detector');
  }

  Future<void> setDetectorSigMask(int mask) async {
    if (_detectorConfig == null) {
      DebugLog.log('BLE: detectorConfig char missing; skip sigmask');
      return;
    }
    await _serialWrite(_detectorConfig!,
        Uint8List.fromList([0x03, mask & 0xFF]), withoutResponse: false);
    DebugLog.log('BLE: detector sigmask=0x${(mask & 0xFF).toRadixString(16)}');
  }

  static int? _parseUuid16(String s) {
    final clean = s.trim().replaceFirst(RegExp(r'^0x', caseSensitive: false), '');
    if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(clean)) return null;
    final v = int.parse(clean, radix: 16);
    if (v < 0 || v > 0xFFFF) return null;
    return v;
  }

  static Uint8List? _parseMac(String s) {
    final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.length < 6 || clean.length > 12 || clean.length.isOdd) return null;
    final out = Uint8List(6);
    for (int i = 0; i < clean.length; i += 2) {
      out[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return out;
  }

  Future<void> disableAllEngines() async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, BleProtocol.encodeDisableAll());
    DebugLog.log('BLE: sent DISABLE_ALL');
    await _refreshEngineState();
  }

  /// Read engine state directly — bypasses unreliable NOTIFY under load.
  Future<void> _refreshEngineState() async {
    if (_engineControl == null) return;
    try {
      await Future.delayed(const Duration(milliseconds: 150));
      final data = await _engineControl!.read();
      _engineStates.add(BleProtocol.decodeEngineStatus(data));
    } catch (e) {
      DebugLog.log('BLE: engine state read failed: $e');
    }
  }

  Future<int> readActiveEngineMask() async {
    if (_engineControl == null) return -1;
    try {
      final data = await _engineControl!.read();
      final status = BleProtocol.decodeEngineStatus(data);
      _engineStates.add(status);
      return status.active;
    } catch (e) {
      DebugLog.log('BLE: active-engine-mask read failed: $e');
      return -1;
    }
  }

  Future<int> readCommandedEngineMask() async {
    if (_engineControl == null) return -1;
    try {
      final data = await _engineControl!.read();
      final status = BleProtocol.decodeEngineStatus(data);
      _engineStates.add(status);
      return commandedEngineMask(status.states);
    } catch (e) {
      DebugLog.log('BLE: commanded-engine-mask read failed: $e');
      return -1;
    }
  }

  Future<void> resyncOnResume() async {
    if (_currentState != NodeConnectionState.ready || _device == null) {
      if (_device != null &&
          !_userInitiatedDisconnect &&
          _currentState != NodeConnectionState.connecting &&
          _currentState != NodeConnectionState.negotiating &&
          _currentState != NodeConnectionState.syncing) {
        DebugLog.log('BLE: resume — link down, restarting reconnect loop');
        _startReconnect();
      } else if (_device == null && _lastDevice != null) {
        DebugLog.log('BLE: resume — device torn down on detach, reconnecting to last');
        await reconnectPrimary();
      } else {
        DebugLog.log('BLE: resume — not connected, autoconnect handles it');
      }
      return;
    }
    DebugLog.log('BLE: app resumed — reconcile to firmware state');
    try {
      await _readDeviceConfig();
      await _refreshEngineState();
    } catch (e) {
      DebugLog.log('BLE: resync on resume failed: $e');
    }
  }

  // -- GPS push --

  Future<void> pushGps({
    required double latitude,
    required double longitude,
    double altitude = 0,
    double speed = 0,
    double heading = 0,
    double accuracy = 0,
    int satelliteCount = 0,
    bool suppressAlerts = false,
  }) async {
    if (_gpsReceive == null) return;
    updateGps(
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      satelliteCount: satelliteCount,
    );
    await _serialWrite(_gpsReceive!, 
      BleProtocol.encodeGps(
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        speed: speed,
        heading: heading,
        accuracy: accuracy,
        satelliteCount: satelliteCount,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        suppressAlerts: suppressAlerts,
      ),
      withoutResponse: true,
    );
  }

  Future<GpsStatus?> readGpsStatus() async {
    if (_gpsReceive == null || !isConnected) return null;
    try {
      return BleProtocol.decodeGpsStatus(await _gpsReceive!.read());
    } catch (e) {
      DebugLog.log('BLE: GPS status read failed: $e');
      return null;
    }
  }

  // -- Hardware config --

  Future<void> _readDeviceConfig() async {
    if (_hardwareConfig == null) return;
    try {
      final value = await _hardwareConfig!.read();
      _offlineScanEnabled = value.length > 5 && value[5] == 1;
      DebugLog.log('BLE: hardwareConfig read len=${value.length} offlineScan=$_offlineScanEnabled');
    } on Exception catch (e) {
      DebugLog.log('BLE: hardwareConfig read failed: $e');
      _offlineScanEnabled = false;
    }
  }

  Future<void> writeHardwareConfig({
    required bool buzzer,
    required bool led,
    required int neopixelBrightness,
    required int buzzerVolume,
    bool extendedOui = false,
    bool offlineScan = false,
    bool allowOuiOnly = false,
    bool passiveBleScan = false,
  }) async {
    if (_hardwareConfig == null) return;
    await _serialWrite(_hardwareConfig!, 
      BleProtocol.encodeHardwareConfig(
        buzzer: buzzer,
        led: led,
        neopixelBrightness: neopixelBrightness,
        buzzerVolume: buzzerVolume,
        extendedOui: extendedOui,
        offlineScan: offlineScan,
        allowOuiOnly: allowOuiOnly,
        passiveBleScan: passiveBleScan,
      ),
    );
  }

  Future<void> writeAlertConfig({
    required int cooldownMs,
    required int heartbeatMs,
    required int rediscoverMs,
    required int hbActiveMs,
  }) async {
    if (_alertConfig == null) return;
    await _serialWrite(_alertConfig!, 
      BleProtocol.encodeAlertConfig(
        cooldownMs: cooldownMs,
        heartbeatMs: heartbeatMs,
        rediscoverMs: rediscoverMs,
        hbActiveMs: hbActiveMs,
      ),
    );
  }

  // -- Foxhunter --

  Future<void> setFoxhunterTarget(String mac, {int channel = 0, String? nodeId}) async {
    if (nodeId != null) {
      if (_engineControl == null) return;
      final macBytes = BleProtocol.encodeFoxhunterTarget(mac, channel: channel);
      final payload = <int>[
        ...BleProtocol.targetEnvelope(nodeId),
        ...macBytes,
      ];
      await _serialWrite(_engineControl!, 
        BleProtocol.encodeEngineConfig(
          engine: Engine.foxhunter,
          payload: Uint8List.fromList(payload),
        ),
      );
      return;
    }
    if (_foxhunterConfig == null) return;
    await _serialWrite(_foxhunterConfig!, 
      BleProtocol.encodeFoxhunterTarget(mac, channel: channel),
    );
  }

  // -- UniPwn --

  Future<void> sendUnipwnCommand({
    required String targetMac,
    required int commandType,
    String payload = '',
  }) async {
    if (_unipwnCommand == null) return;
    await _serialWrite(_unipwnCommand!, 
      BleProtocol.encodeUnipwnCommand(
        targetMac: targetMac,
        commandType: commandType,
        payload: payload,
      ),
    );
  }

  // -- Mesh --

  Future<void> writeMeshConfig({
    required bool enabled,
    required bool encryption,
    required Uint8List key,
    required List<Uint8List> peerMacs,
  }) async {
    if (_meshConfig == null) return;
    await _serialWrite(_meshConfig!, 
      BleProtocol.encodeMeshConfig(
        enabled: enabled,
        encryption: encryption,
        key: key,
        peerMacs: peerMacs,
      ),
    );
  }

  // -- Disconnect --

  Future<void> disconnect() async {
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _stopLinkWatchdog();
    DebugLog.log('BLE: disconnect — leaving engine state to firmware (offline-scan aware)');
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    try {
      await _device?.disconnect();
    } on FlutterBluePlusException catch (e) {
      DebugLog.log('BLE: device.disconnect failed: ${e.description}');
    }
    _device = null;
    _currentState = NodeConnectionState.disconnected; _connectionState.add(NodeConnectionState.disconnected);
  }

  Future<void> disconnectQuiet() async {
    if (_device != null) _lastDevice = _device;
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _stopLinkWatchdog();
    final subs = List.of(_subscriptions);
    _subscriptions.clear();
    for (final sub in subs) {
      try {
        await sub.cancel();
      } on Exception catch (e) {
        DebugLog.log('BLE: sub cancel on quiet disconnect: $e');
      }
    }
    try {
      await _device?.disconnect();
    } on FlutterBluePlusException catch (e) {
      DebugLog.log('BLE: quiet disconnect failed: ${e.description}');
    }
    _device = null;
    _currentState = NodeConnectionState.disconnected;
    _connectionState.add(NodeConnectionState.disconnected);
  }

  void signalAutoReconnect(bool active) {
    if (_currentState == NodeConnectionState.ready ||
        _currentState == NodeConnectionState.connecting ||
        _currentState == NodeConnectionState.negotiating ||
        _currentState == NodeConnectionState.syncing) {
      return;
    }
    final s = active
        ? NodeConnectionState.reconnecting
        : NodeConnectionState.disconnected;
    _currentState = s;
    _connectionState.add(s);
  }

  Future<void> reconnectPrimary() async {
    if (_currentState == NodeConnectionState.ready) return;
    final dev = _lastDevice;
    if (dev == null) return;
    _userInitiatedDisconnect = false;
    _isReconnect = true;
    signalAutoReconnect(true);
    DebugLog.log('BLE: resume — reconnecting to ${dev.platformName}');
    try {
      await connect(dev,
          sessionId: DateTime.now().millisecondsSinceEpoch.toString());
    } on Exception catch (e) {
      if (_currentState != NodeConnectionState.ready) {
        _currentState = NodeConnectionState.disconnected;
        _connectionState.add(NodeConnectionState.disconnected);
      }
      DebugLog.log('BLE: reconnect on resume failed: $e');
    }
  }

  void dispose() {
    disconnect();
    _importTimer?.cancel();
    _awaySettle?.cancel();
    _connectionState.close();
    _detections.close();
    _importedDetections.close();
    _wdLog.close();
    _wdLogTimer?.cancel();
    _awayLiveDetections.close();
    _spoolImport.close();
    _awayImport.close();
    _foxhunterRssiStream.close();
    _engineStates.close();
    _meshStatusStream.close();
    _pairingFailures.close();
    _wifiOtaStream.close();
    _fleetOtaStream.close();
    _pcapStatsStream.close();
    _pcapDataStream.close();
  }

  // -- PCAP --

  Future<void> startPcap({
    int mode = 0,
    int channelStart = 1,
    int channelEnd = 11,
    int mode5g = 1,
    String? targetNodeId,
  }) async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList(
          [0x01, mode, channelStart, channelEnd, 0x00, mode5g & 0x03],
        ),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 50));
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineControl(
        engine: Engine.pcap, enable: true, targetNodeId: targetNodeId,
      ),
    );
  }

  Future<void> setWardriveNodeRadio(String nodeId, int radioMask) async {
    if (_engineControl == null) return;
    if (nodeId.length != 4) {
      throw ArgumentError('nodeId must be canonical 4-hex form, got "$nodeId"');
    }
    final m = radioMask & 0x03;
    final payload = <int>[
      ...BleProtocol.targetEnvelope(nodeId),
      m == 0 ? 0x03 : m,
    ];
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.wardrive,
        payload: Uint8List.fromList(payload),
      ),
    );
  }

  Future<void> stopPcap({String? targetNodeId}) async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineControl(
        engine: Engine.pcap, enable: false, targetNodeId: targetNodeId,
      ),
    );
  }

  Future<void> clearPcap() async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList([0x03]), // PCAP_CTRL_CLEAR
      ),
    );
  }

  Future<void> pausePcap() async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList([0x04]), // PCAP_CTRL_PAUSE
      ),
    );
  }

  Future<void> resumePcap() async {
    if (_engineControl == null) return;
    await _serialWrite(_engineControl!, 
      BleProtocol.encodeEngineConfig(
        engine: Engine.pcap,
        payload: Uint8List.fromList([0x05]), // PCAP_CTRL_RESUME
      ),
    );
  }


  // -- Private --

  void _onDetection(List<int> data) {
    // Checked first: these never come from a detection, and during a spool
    // import every other packet is diverted to it.
    if (WdLogPackets.isHeader(data)) {
      final h = WdLogPackets.header(data);
      _wdLog.add(WdLogEvent.header(h.count, h.full));
      _armWdLogTimer();
      return;
    }
    if (WdLogPackets.isRows(data)) {
      _wdLog.add(WdLogEvent.rows(WdLogPackets.rows(data)));
      _armWdLogTimer();
      return;
    }
    if (WdLogPackets.isDone(data)) {
      _wdLogTimer?.cancel();
      _wdLog.add(const WdLogEvent.done());
      return;
    }
    if (_importing) {
      _importTimer?.cancel();
      _importTimer = Timer(const Duration(seconds: 12), _abortImport);
      if (BleProtocol.isSpoolHeader(data)) {
        final h = BleProtocol.decodeSpoolHeader(data);
        _importTotal = h.count;
        _importDropped = h.dropped;
        _importDeviceNow = h.deviceNowMs;
        _spoolImport.add(SpoolImportProgress(seen: 0, total: _importTotal, dropped: _importDropped, done: false, aborted: false));
        return;
      }
      if (BleProtocol.isSpoolDone(data)) {
        _importTimer?.cancel();
        _importTimer = null;
        _importing = false;
        _spoolImport.add(SpoolImportProgress(seen: _importSeen, total: _importTotal, dropped: _importDropped, done: true, aborted: false));
        return;
      }
      if (data.length < 14) return;
      final detection = BleProtocol.decodeDetection(
        data,
        sessionId: _sessionId,
        nodeId: _nodeId,
        appTimestamp: DateTime.now(),
        latitude: null,
        longitude: null,
        accuracy: null,
        satelliteCount: null,
      );
      _importSeen++;
      _importedDetections.add(detection);
      _noteAway(detection);
      return;
    }
    if (data.length < 14) return;
    final isAway = data.isNotEmpty && (data[0] & 0x80) != 0;
    final detection = BleProtocol.decodeDetection(
      data,
      sessionId: _sessionId,
      nodeId: _nodeId,
      appTimestamp: DateTime.now(),
      latitude: isAway ? null : _lastLat,
      longitude: isAway ? null : _lastLon,
      accuracy: isAway ? null : _lastAccuracy,
      satelliteCount: isAway ? null : _lastSatCount,
    );
    _detections.add(detection);
    if (isAway) {
      _noteAway(detection);
      _awayLiveDetections.add(detection);
    }
  }

  void _noteAway(Detection detection) {
    _awaySeen++;
    _awayByEngine[detection.engine.name] =
        (_awayByEngine[detection.engine.name] ?? 0) + 1;
    _awaySettle?.cancel();
    _awayImport.add(SpoolImportProgress(
        seen: _awaySeen, total: 0, dropped: _importDropped, done: false,
        aborted: false, byEngine: Map.of(_awayByEngine)));
    _awaySettle = Timer(const Duration(seconds: 3), () {
      _awayImport.add(SpoolImportProgress(
          seen: _awaySeen, total: _awaySeen, dropped: _importDropped, done: true,
          aborted: false, byEngine: Map.of(_awayByEngine)));
      _awaySeen = 0;
      _awayByEngine.clear();
    });
  }

  void _abortImport() {
    if (!_importing) return;
    _importTimer?.cancel();
    _importTimer = null;
    _importing = false;
    _spoolImport.add(SpoolImportProgress(seen: _importSeen, total: _importTotal, dropped: _importDropped, done: true, aborted: true));
    DebugLog.log('BLE: spool import aborted (timeout)');
  }

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _connecting = false;

  // -- Soft-dead link watchdog --
  //
  // A GATT connection can stay nominally up while nothing crosses it: the
  // board resets its BLE stack, the controller keeps the handle, and the app
  // sits there looking connected with a live UI and no data. It is the link
  // version of the wedged sniffer the firmware watches for, and it fails the
  // same way — silently, with every indicator saying fine.
  //
  // The board notifies engine state every 5 s whenever a phone is connected,
  // so that is a heartbeat that ticks regardless of whether anything is being
  // detected. Detections are the wrong signal: a quiet street would read as a
  // dead link.
  static const Duration kLinkSilenceLimit = Duration(seconds: 25);
  static const Duration kLinkCheckInterval = Duration(seconds: 10);
  DateTime? _lastInboundAt;
  Timer? _linkWatchdog;

  void _startLinkWatchdog() {
    _linkWatchdog?.cancel();
    _lastInboundAt = DateTime.now();
    _linkWatchdog = Timer.periodic(kLinkCheckInterval, (_) {
      // Only judge a link we believe is up. While reconnecting, the OS may be
      // holding a pending connection — tearing that down would fight the very
      // mechanism that is recovering us.
      if (_currentState != NodeConnectionState.ready) return;
      final last = _lastInboundAt;
      if (last == null) return;
      final silent = DateTime.now().difference(last);
      if (silent < kLinkSilenceLimit) return;
      DebugLog.log('BLE: no heartbeat for ${silent.inSeconds}s on a connected '
          'link — forcing a reconnect');
      _lastInboundAt = DateTime.now(); // do not fire again while this runs
      final target = _device;
      if (target == null) return;
      // Dropping the link puts us through the normal disconnect path, which
      // starts recovery; it does not count as a user-initiated disconnect.
      target.disconnect().catchError((Object e) {
        DebugLog.log('BLE: watchdog disconnect failed: $e');
      });
    });
  }

  void _stopLinkWatchdog() {
    _linkWatchdog?.cancel();
    _linkWatchdog = null;
  }

  void _startReconnect() {
    if (_device == null) return;
    if (_connecting || (_reconnectTimer?.isActive ?? false)) return;
    _currentState = NodeConnectionState.reconnecting; _connectionState.add(NodeConnectionState.reconnecting);
    _reconnectAttempt = 0;
    _attemptReconnect();
  }

  /// Recovery alternates between two strategies rather than running both.
  ///
  /// Even attempts hand the job to the operating system (see
  /// [kOsReconnectWindow]): it completes the moment the board advertises, so
  /// a blip is recovered in about as long as the board takes to come back,
  /// instead of waiting out a timer. Odd attempts scan and connect ourselves,
  /// which is the only thing that finds a board whose address has changed.
  ///
  /// They alternate instead of racing: two connect paths against one device
  /// fight each other, and the loser's failure looks like a real one.
  void _attemptReconnect() {
    final useOs = _reconnectAttempt.isEven;
    final delay = useOs
        ? Duration.zero
        : Duration(seconds: [1, 2, 4, 8, 15, 30][(_reconnectAttempt ~/ 2).clamp(0, 5)]);
    _reconnectTimer?.cancel();
    _stopLinkWatchdog();
    _reconnectTimer = Timer(delay, () async {
      if (_device == null || _userInitiatedDisconnect) return;
      final target = _device!;
      BluetoothDevice? found;
      final expectNodeId = _nodeId;
      if (!useOs) {
        found = await _scanForRemoteId(target.remoteId.toString());
        if (found == null && expectNodeId.isNotEmpty) {
          // The saved address never appeared. A board that randomises its MAC
          // each boot is gone from that address for good, so look for one of
          // the same role and let the node-id check decide if it is ours.
          found = await _scanForSameRole(_role == 'mgr',
              exclude: _reconnectRejected);
          if (found != null) {
            DebugLog.log('BLE: saved address gone — trying ${found.remoteId} '
                '(the board may have rotated its MAC)');
            _reconnectExpectNodeId = expectNodeId;
          }
        }
        if (_device == null || _userInitiatedDisconnect) {
          _reconnectExpectNodeId = null;
          return;
        }
      }
      _isReconnect = true;
      try {
        await connect(found ?? target,
            sessionId: _sessionId, useAutoConnect: useOs);
        // Reconnected at a new address: save it, or every later attempt starts
        // from the address that is never coming back.
        if (_reconnectExpectNodeId != null &&
            _currentState == NodeConnectionState.ready) {
          markAsPrimary();
        }
      } catch (e) {
        DebugLog.log('BLE: reconnect attempt failed (${useOs ? 'os' : 'scan'}): $e');
      } finally {
        _reconnectExpectNodeId = null;
      }
      if (_device != null &&
          !_userInitiatedDisconnect &&
          _currentState != NodeConnectionState.ready) {
        _reconnectAttempt++;
        _attemptReconnect();
      }
    });
  }

  List<String> _parseDeviceInfo(List<int> data) {
    final out = <String>[];
    int start = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0) {
        out.add(String.fromCharCodes(data.sublist(start, i)));
        start = i + 1;
      }
    }
    if (start < data.length) {
      out.add(String.fromCharCodes(data.sublist(start)));
    }
    return out;
  }
}

final bleManagerProvider = Provider<BleManager>((ref) {
  final manager = BleManager();
  manager.setWatchlistGetter(() => ref.read(watchlistProvider).enabledEntries);
  ref.listen(watchlistProvider, (prev, next) {
    if (manager.currentConnectionState == NodeConnectionState.ready) {
      manager.syncDetectorWatchlist(next.enabledEntries);
    }
  });
  manager.setDetectorSigMaskGetter(() => ref.read(detectorSigMaskProvider));
  ref.listen(detectorSigMaskProvider, (prev, next) {
    if (manager.currentConnectionState == NodeConnectionState.ready) {
      manager.setDetectorSigMask(next);
    }
  });
  ref.onDispose(manager.dispose);
  return manager;
});
