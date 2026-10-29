// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:oui_spy/core/ble/ble_manager.dart';
import 'package:oui_spy/core/db/app_database.dart' hide Detection, Session;
import 'package:oui_spy/core/db/detection_mapper.dart';
import 'package:oui_spy/core/debug_log.dart';
import 'package:oui_spy/core/drone_grouping.dart';
import 'package:oui_spy/core/export/wigle_csv.dart';
import 'package:oui_spy/core/export/wigle_csv_import.dart';
import 'package:oui_spy/core/watchlist_state.dart';
import 'package:oui_spy/core/gps/gps_provider.dart';
import 'package:oui_spy/core/gps/gps_types.dart';
import 'package:oui_spy/core/geofence/geofence_filter.dart';
import 'package:oui_spy/core/ignore_list_state.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/radio_classifier.dart';
import 'package:oui_spy/core/models/session.dart';
import 'package:oui_spy/core/notifications/live_activity_service.dart';
import 'package:oui_spy/theme/app_theme.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' as drift;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum WardriveState { idle, running, paused }

enum WardriveTarget {
  flock('FLOCK', 'Flock Safety cameras', Icons.videocam),
  drone('DRONE', 'FAA Remote ID drones', Icons.flight),
  wigle('WIGLE', 'All networks (WiGLE)', Icons.wifi_find),
  detector('DETECT', 'Watchlist devices', Icons.radar),
  wigleFlock('WIGLE+FLOCK', 'All networks + Flock', Icons.hub);

  const WardriveTarget(this.label, this.description, this.icon);
  final String label;
  final String description;
  final IconData icon;

  /// One tint for every target; the icon and label tell them apart.
  Color get color => AppTheme.accent;

  List<Engine> engines(WardriveRadio radio) => switch (this) {
    // Flock is Wi-Fi only now. The BLE engine was removed from the firmware:
    // upstream reports the community BLE method stopped working in spring 2026,
    // and the Wi-Fi IE fingerprint is the reliable path. Selecting the BLE radio
    // no longer enables a Flock engine rather than enabling a dead one.
    WardriveTarget.flock => switch (radio) {
      WardriveRadio.wifi => [Engine.flockWifi],
      WardriveRadio.ble => const <Engine>[],
      WardriveRadio.both => [Engine.flockWifi],
    },
    WardriveTarget.drone => [Engine.skySpy],
    WardriveTarget.wigle => [Engine.wardrive],
    WardriveTarget.detector => [Engine.detector],
    WardriveTarget.wigleFlock => switch (radio) {
      WardriveRadio.wifi => [Engine.wardrive, Engine.flockWifi],
      WardriveRadio.ble => [Engine.wardrive],
      WardriveRadio.both => [Engine.wardrive, Engine.flockWifi],
    },
  };

  bool get hasRadioChoice => true;

  bool get usesPerNodeRadio => this == wigle || this == wigleFlock;

  Engine? get radioMaskEngine => switch (this) {
    WardriveTarget.wigle || WardriveTarget.wigleFlock => Engine.wardrive,
    WardriveTarget.detector => Engine.detector,
    WardriveTarget.drone => Engine.skySpy,
    WardriveTarget.flock => null,
  };

  /// Whether this target includes flock detection engines.
  bool get includesFlock => this == flock || this == wigleFlock;
}

enum WardriveRadio {
  wifi('WiFi'), ble('BLE'), both('WiFi+BLE');
  const WardriveRadio(this.label);
  final String label;
}

Set<WardriveTarget> targetsFromEngineMask(int mask) {
  final targets = <WardriveTarget>{};
  if ((mask & Engine.flockWifi.bitmask) != 0) {
    targets.add(WardriveTarget.flock);
  }
  if ((mask & Engine.skySpy.bitmask) != 0) targets.add(WardriveTarget.drone);
  if ((mask & Engine.detector.bitmask) != 0) targets.add(WardriveTarget.detector);
  return targets;
}

Set<WardriveTarget> reconciledTargets(
    int mask, Set<WardriveTarget> current, bool keepRunning) {
  final t = targetsFromEngineMask(mask);
  if (current.contains(WardriveTarget.wigle) && !keepRunning) {
    t.add(WardriveTarget.wigle);
  }
  return t;
}

Future<void> reconcileDanglingWardriveSessions(AppDatabase db) async {
  final rows = await db.getWardriveSessions();
  for (final s in rows) {
    if (s.endedAt != null) continue;
    final dets = await db.getDetectionsForSession(s.id);
    if (dets.isEmpty) {
      await db.deleteSession(s.id);
      continue;
    }
    final uniq = await db.uniqueMacCount(s.id);
    await db.updateSession(SessionsCompanion(
      id: drift.Value(s.id),
      endedAt: drift.Value(dets.first.appTimestamp),
      detectionCount: drift.Value(dets.length),
      uniqueMacCount: drift.Value(uniq),
    ));
  }
}

enum WifiBand { band24, band5, both }

/// The engines a board-reported engine mask says are running.
Set<Engine> enginesFromMask(int mask) {
  if (mask <= 0) return {};
  return Engine.values.where((e) => mask & e.bitmask != 0).toSet();
}

/// Whether a wardrive teardown succeeded, given the mask the board reports
/// afterwards and the engines that were already running before the session.
///
/// Success is "nothing left running but what we were asked to preserve", not
/// "nothing running at all" — the latter reads a deliberately preserved engine
/// as a failed teardown.
/// Whether a coordinate is usable for plotting. Null island and the poles are
/// what a device reports when it has no fix, not somewhere it has been.
bool plottableCoord(double? lat, double? lon) {
  if (lat == null || lon == null) return false;
  if (!lat.isFinite || !lon.isFinite) return false;
  if (lat == 0.0 && lon == 0.0) return false;
  if (lat.abs() > 89.5) return false;
  return true;
}

/// Of two sightings of the same device, which one's position should be plotted.
///
/// The map shows one marker per device, so repeat sightings have to collapse to
/// a single point, and something must decide which. The strongest sighting
/// wins: RSSI falls off with distance, so the loudest sample is the one taken
/// nearest the transmitter. It also keeps the marker's position and its
/// reported signal drawn from the *same* sample, which neither previous rule
/// did.
///
/// A sighting with no usable fix never wins, however loud — otherwise driving
/// through a GPS shadow would move a device to nowhere.
///
/// Deliberately not an average of the sightings. For a stationary transmitter
/// the mean is dragged toward wherever the most samples were taken, which is
/// wherever traffic was slowest, not where the device is. For a moving one —
/// a tracker in someone's bag, a randomised MAC — the mean is a point the
/// device never occupied, and nothing in the data says which case applies.
bool sightingWinsPlot(
  double? candLat, double? candLon, int candRssi,
  double? curLat, double? curLon, int curRssi,
) {
  final candFix = plottableCoord(candLat, candLon);
  if (!candFix) return false;
  if (!plottableCoord(curLat, curLon)) return true;
  return candRssi > curRssi;
}

/// The targets a wardrive actually runs with, given what the user selected.
///
/// A wardrive with nothing selected is not an error: an unfiltered run that
/// logs every network for WiGLE is the ordinary case, and it is what the
/// wardrive tile means. Selecting nothing therefore means "everything", not
/// "refuse to start".
///
/// This rule lives here, and only here. It used to exist twice — once in the
/// tile path, which *cleared* the selection and forced WiGLE, and once in the
/// map path, which preserved it — so the same switch did different things
/// depending on which screen you touched it from.
Set<WardriveTarget> wardriveTargetsForStart(Set<WardriveTarget> selected) =>
    selected.isEmpty ? {WardriveTarget.wigle} : {...selected};

bool teardownComplete(int maskAfter, Set<Engine> preserved) {
  if (maskAfter < 0) return false; // could not read — do not claim success
  int expected = 0;
  for (final e in preserved) {
    expected |= e.bitmask;
  }
  return (maskAfter & ~expected) == 0;
}

/// How old a fix may be before it stops standing in for a missing one. Past
/// this the device is somewhere else entirely — in a car, minutes are
/// kilometres — and the coordinate would be fiction.
const Duration kStaleFixAfter = Duration(minutes: 3);

/// Whether [p] is good enough and recent enough at [now] to stand in for a
/// detection that arrived without a position of its own.
///
/// A wrong coordinate is worse than no coordinate: WiGLE tolerates a missing
/// position, but a confident one that is minutes stale corrupts their
/// trilateration for that transmitter and cannot be withdrawn after upload.
bool fixUsableAsFallback(GpsPosition p, DateTime now) {
  if (p.quality == GpsQuality.poor || p.quality == GpsQuality.none) {
    return false;
  }
  final age = now.difference(p.timestamp);
  return !age.isNegative && age <= kStaleFixAfter;
}

/// Accuracy to record for [p] when it stands in for a fix taken at [now].
///
/// The device may have moved since, so the radius grows by the distance it
/// could have covered: the last known speed, but never less than walking
/// pace, because a stopped receiver reports zero right up to the moment it
/// moves.
double borrowedFixAccuracy(GpsPosition p, DateTime now) {
  final ageS = now.difference(p.timestamp).inMilliseconds / 1000.0;
  if (ageS <= 0) return p.accuracy;
  const walkingMs = 1.5;
  final speed = p.speed.isFinite && p.speed > walkingMs ? p.speed : walkingMs;
  return p.accuracy + ageS * speed;
}

/// How long a running wardrive waits for the board before giving up.
///
/// Without the phone, the board keeps wardrive rows only if offline scan is on
/// and it has its own GPS module (src/wd_log.cpp); those rows are imported on
/// reconnect. Otherwise nothing is recorded while the link is down, so a
/// session whose board is gone is not paused, it is over — it just does not
/// know it yet, and every minute it stays "running" is a minute the user
/// believes is being logged.
///
/// Five minutes is the compromise. Long enough to cover a walk round a
/// building, a pocketed phone or a flat battery swapped on the move; short
/// enough that nobody drives for an hour trusting a dead session.
const Duration kWardriveResumeWindow = Duration(minutes: 5);

/// Whether a session that lost its link [lostFor] ago should be given up on.
///
/// Separate from the timer that normally triggers it, because a timer is not
/// trustworthy here: Android may hold it in Doze while the phone is in a
/// pocket, which is exactly when a link is most likely to drop. The elapsed
/// time is therefore re-checked whenever the app comes back to life, and this
/// is the one rule both paths use.
bool resumeWindowExpired(Duration lostFor, {Duration window = kWardriveResumeWindow}) {
  return !lostFor.isNegative && lostFor >= window;
}

/// Whether a reconnect may resume a wardrive session from the board's engine
/// mask.
///
/// The mask alone cannot answer this. An engine switched on from HOME sets the
/// same bits a session with that target would, so adopting on the mask alone
/// turns a detector tile into a running wardrive the next time the phone comes
/// back in range. [sessionIntent] is the only thing that distinguishes them.
bool canAdoptSession({
  required bool offlineScanEnabled,
  required bool userStopped,
  required bool sessionIntent,
}) {
  // Nothing was asked to keep running, so whatever is on the board is stale.
  if (!offlineScanEnabled) return false;
  // The user stopped it; do not bring it back.
  if (userStopped) return false;
  return sessionIntent;
}

class WardriveController extends ChangeNotifier {
  WardriveController(this._ble, this._gps, this._db, this._ignoreList, this._geofenceFilter, this._notificationService, this._liveActivity) {
    _connSub = _ble.connectionState.listen((connState) {
      if (connState == NodeConnectionState.ready) {
        SharedPreferences.getInstance().then(
            (p) => offlineGpsTag = p.getBool('offlineGpsTagEnabled') ?? false);
        // The board is back. Either it beat the window, or the window elapsed
        // while a timer was held in Doze and we only find out now.
        if (!_closeResumeWindow()) return;
        if (state == WardriveState.running &&
            _droppedWhileRunning &&
            !_ble.offlineScanEnabled) {
          _droppedWhileRunning = false;
          // The app owns the intent here, so it re-asserts it rather than
          // asking the user to guess what the board is doing. The boot epoch
          // says which case this is; both end in re-pushing the engines this
          // session wants, so the session simply continues either way.
          if (_ble.boardRestarted) {
            DebugLog.log('WARDRIVE: board restarted mid-session '
                '(boot #${_ble.bootCount}) — re-asserting engines');
          } else {
            DebugLog.log('WARDRIVE: link blipped, same boot — session intact, '
                're-asserting engines to be sure');
          }
          _reEnableEngines();
          _pushWifiBand();
          notifyListeners();
          return;
        }
        _droppedWhileRunning = false;
        _adoptFirmwareState();
        _pushWifiBand();
      } else if (connState == NodeConnectionState.disconnected ||
          connState == NodeConnectionState.reconnecting) {
        if (state == WardriveState.running) {
          _droppedWhileRunning = true;
          _beginResumeWindow();
        }
      }
    });
    // Always-on recorder. Detections used to reach the database only while a
    // wardrive session ran (`_onDetection` returns early unless running, and
    // its subscription is cancelled on stop), so an engine tile on its own
    // detected and alerted but stored nothing. This records every live
    // detection, under an ambient session when no wardrive session is active.
    _ambientDetSub = _ble.detections.listen(_onAmbientDetection);
    _importedDetSub = _ble.importedDetections.listen(_onImportedDetection);
    _awayLiveSub = _ble.awayLiveDetections.listen(_onAwayLiveDetection);
    _spoolImportSub = _ble.spoolImport.listen(_onSpoolProgress);
    _wdLogSub = _ble.wdLogImport.listen((e) => _wdLogChain = _wdLogChain.then((_) => _onWdLog(e)));
    _prefsLoaded = _loadPrefs();
    _reconciled = reconcileDanglingWardriveSessions(_db);
  }

  late final Future<void> _reconciled;
  Future<void>? _prefsLoaded;

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    offlineGpsTag = p.getBool('offlineGpsTagEnabled') ?? false;
    _sessionIntent = p.getBool('wd_sessionIntent') ?? false;
    _wifiRssiRelogDb = p.getInt('wd_wifiRssiRelog') ?? 20;
    _bleRssiRelogDb = p.getInt('wd_bleRssiRelog') ?? 15;
    _wifiScanInterval = p.getInt('wd_wifiScanInterval') ?? 350;
    _wifiDwellPerCh = p.getInt('wd_wifiDwellPerCh') ?? 150;
    _bleScanDuration = p.getInt('wd_bleScanDuration') ?? 800;
    _bleScanInterval = p.getInt('wd_bleScanInterval') ?? 3000;
    _channelStart = p.getInt('wd_channelStart') ?? 1;
    _channelEnd = p.getInt('wd_channelEnd') ?? 14;
    _wardrive24Mode = p.getInt('wd_wardrive24Mode') ?? 0;
    _activeProbe = p.getBool('wd_activeProbe') ?? false;
    _wifiBand = WifiBand.values[
        (p.getInt('wd_wifiBand') ?? WifiBand.both.index)
            .clamp(0, WifiBand.values.length - 1)];
    radio = radioFromMask(p.getInt('wd_radio') ?? 0x03);
    final savedTargets = p.getStringList('wd_targets');
    if (savedTargets != null) {
      selectedTargets
        ..clear()
        ..addAll(savedTargets
            .map((n) => WardriveTarget.values
                .where((t) => t.name == n)
                .cast<WardriveTarget?>()
                .firstWhere((t) => t != null, orElse: () => null))
            .whereType<WardriveTarget>());
    }
    if (!(p.getBool('wd_dwellFast_v6') ?? false)) {
      _wifiScanInterval = 300;
      _wifiDwellPerCh = 110;
      _channelEnd = 14;
      await p.setInt('wd_wifiScanInterval', _wifiScanInterval);
      await p.setInt('wd_wifiDwellPerCh', _wifiDwellPerCh);
      await p.setInt('wd_channelEnd', _channelEnd);
      await p.setInt('wd_wardrive24Mode', _wardrive24Mode);
      await p.setBool('wd_activeProbe', _activeProbe);
      await p.setBool('wd_dwellFast_v6', true);
    }
    notifyListeners();
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    p.setInt('wd_wifiRssiRelog', _wifiRssiRelogDb);
    p.setInt('wd_bleRssiRelog', _bleRssiRelogDb);
    p.setInt('wd_wifiScanInterval', _wifiScanInterval);
    p.setInt('wd_wifiDwellPerCh', _wifiDwellPerCh);
    p.setInt('wd_bleScanDuration', _bleScanDuration);
    p.setInt('wd_bleScanInterval', _bleScanInterval);
    p.setInt('wd_channelStart', _channelStart);
    p.setInt('wd_channelEnd', _channelEnd);
    p.setInt('wd_wardrive24Mode', _wardrive24Mode);
    p.setBool('wd_activeProbe', _activeProbe);
    p.setInt('wd_wifiBand', _wifiBand.index);
    p.setInt('wd_radio', radioBitmask);
    p.setStringList('wd_targets', selectedTargets.map((t) => t.name).toList());
  }

  /// Map a radio mask (0x01/0x02/0x03) to the [WardriveRadio] enum.
  static WardriveRadio radioFromMask(int mask) => switch (mask & 0x03) {
    0x01 => WardriveRadio.wifi,
    0x02 => WardriveRadio.ble,
    _ => WardriveRadio.both,
  };

  final BleManager _ble;
  final GpsProvider _gps;
  final AppDatabase _db;
  final IgnoreListState _ignoreList;
  final GeofenceFilter _geofenceFilter;
  final NotificationService _notificationService;
  final LiveActivityService _liveActivity;
  StreamSubscription<NodeConnectionState>? _connSub;
  StreamSubscription<Detection>? _ambientDetSub;
  StreamSubscription<Detection>? _importedDetSub;
  StreamSubscription<Detection>? _awayLiveSub;
  StreamSubscription<SpoolImportProgress>? _spoolImportSub;
  StreamSubscription<WdLogEvent>? _wdLogSub;
  // Transfers are handled strictly in order: a header resets the counts the
  // rows and the final confirm depend on.
  Future<void> _wdLogChain = Future.value();
  int _wdExpected = -1;
  int _wdHandled = 0;
  String? _wdSessionId;
  bool _wdSessionIsOwn = false;
  int _wdLastHeardMs = 0;

  /// Rows the board recorded on its own that were saved, and whether it
  /// filled up and stopped recording, for the last transfer.
  int offlineRowsImported = 0;
  bool offlineLogWasFull = false;
  String? _spoolSessionId;
  Future<String>? _spoolSessionIdFuture;
  int _spoolInserted = 0;
  int _spoolExpectedTotal = -1;
  bool _spoolDone = false;
  bool _spoolConfirmed = false;

  bool isImperial = false;

  bool offlineGpsTag = false;

  WardriveState state = WardriveState.idle;
  String? radioTransition;
  /// Detections dropped because they fell inside a wardrive-exclusion zone.
  int geofenceSuppressed = 0;
  bool _userStopped = false;
  /// Whether the user has a wardrive session open, persisted so it survives
  /// the app being killed.
  ///
  /// Adoption below needs to tell "the board is still running my session"
  /// from "the board has an engine tile on". Both look identical in the
  /// engine mask, and without this an engine switched on from HOME was
  /// promoted to a full wardrive session on the next reconnect.
  bool _sessionIntent = false;
  bool _droppedWhileRunning = false;
  bool pendingReconnectPrompt = false;
  final Set<WardriveTarget> selectedTargets = {};
  static const List<WardriveTarget> selectableTargets = [
    WardriveTarget.flock,
    WardriveTarget.drone,
    WardriveTarget.wigle,
    WardriveTarget.detector,
  ];
  bool isTargetSelected(WardriveTarget t) => selectedTargets.contains(t);
  bool get keepRunningEnabled => _ble.offlineScanEnabled;
  WardriveTarget get primaryTarget {
    for (final t in selectableTargets) {
      if (selectedTargets.contains(t)) return t;
    }
    return WardriveTarget.wigle;
  }
  WardriveTarget get target => primaryTarget;
  bool get includesFlock => selectedTargets.any((t) => t.includesFlock);

  bool ownsEngine(Engine e) =>
      isActive &&
      (activeEngines.contains(e) || (includesFlock && e == Engine.flockWifi));
  String get activeLabel => selectableTargets
      .where(selectedTargets.contains)
      .map((t) => t.label)
      .join(' + ');
  WardriveRadio radio = WardriveRadio.both;
  bool flockFilter = false;
  bool detectorFilter = false;

  int _wifiRssiRelogDb = 20;
  int get wifiRssiRelogDb => _wifiRssiRelogDb;
  set wifiRssiRelogDb(int v) { _wifiRssiRelogDb = v; notifyListeners(); _savePrefs(); }

  int _bleRssiRelogDb = 15;
  int get bleRssiRelogDb => _bleRssiRelogDb;
  set bleRssiRelogDb(int v) { _bleRssiRelogDb = v; notifyListeners(); _savePrefs(); }

  int _wifiScanInterval = 350;
  int get wifiScanInterval => _wifiScanInterval;
  set wifiScanInterval(int v) { _wifiScanInterval = v; notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  int _wifiDwellPerCh = 150;
  int get wifiDwellPerCh => _wifiDwellPerCh;
  set wifiDwellPerCh(int v) { _wifiDwellPerCh = v; notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  int _bleScanDuration = 800;
  int get bleScanDuration => _bleScanDuration;
  set bleScanDuration(int v) { _bleScanDuration = v; notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  int _bleScanInterval = 3000;
  int get bleScanInterval => _bleScanInterval;
  set bleScanInterval(int v) { _bleScanInterval = v; notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  int _channelStart = 1;
  int get channelStart => _channelStart;
  set channelStart(int v) { _channelStart = v.clamp(1, 14); notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  int _channelEnd = 14;
  int get channelEnd => _channelEnd;
  set channelEnd(int v) { _channelEnd = v.clamp(_channelStart, 14); notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  int _wardrive24Mode = 0;
  int get wardrive24Mode => _wardrive24Mode;
  set wardrive24Mode(int v) { _wardrive24Mode = v.clamp(0, 1); notifyListeners(); _savePrefs(); _pushWardriveConfigLive(); }

  WifiBand _wifiBand = WifiBand.both;
  WifiBand get wifiBand => _wifiBand;
  int get wifiBandMask => switch (_wifiBand) {
        WifiBand.band24 => 0x01,
        WifiBand.band5 => 0x02,
        WifiBand.both => 0x03,
      };
  set wifiBand(WifiBand v) { _wifiBand = v; notifyListeners(); _savePrefs(); _pushWifiBand(); }

  /// Active probing. Passive by default — see [activeProbe].
  bool _activeProbe = false;
  bool get activeProbe => _activeProbe;
  set activeProbe(bool v) {
    if (_activeProbe == v) return;
    _activeProbe = v;
    notifyListeners();
    _savePrefs();
    // Pushed unconditionally, not via _pushWardriveConfigLive(): that returns
    // early unless a wardrive session is running, but this flag is global radio
    // policy and also gates Flock-WiFi's own probe transmitter. The firmware
    // forwards config to an engine whether or not it is currently running.
    if (_ble.isConnected) {
      _ble.sendEngineConfig(Engine.wardrive, _wardriveConfigPayload);
    }
  }

  Uint8List get _wardriveConfigPayload => Uint8List.fromList([
        radioBitmask,
        wifiScanInterval & 0xFF, (wifiScanInterval >> 8) & 0xFF,
        wifiDwellPerCh & 0xFF, (wifiDwellPerCh >> 8) & 0xFF,
        bleScanDuration & 0xFF, (bleScanDuration >> 8) & 0xFF,
        bleScanInterval & 0xFF, (bleScanInterval >> 8) & 0xFF,
        channelStart,
        channelEnd,
        wardrive24Mode,
        _activeProbe ? 1 : 0,
      ]);

  void _pushWardriveConfigLive() {
    if (!isActive) return;
    if (!activeEngines.contains(Engine.wardrive)) return;
    _ble.sendEngineConfig(Engine.wardrive, _wardriveConfigPayload);
  }

  void _pushWifiBand() {
    if (!isActive) return;
    _ble.sendWifiBand(wifiBandMask);
  }

  int rawWifiCount = 0;
  int rawBleCount = 0;

  /// Per-source-node WiFi/BLE detection counts for overlay display.
  final Map<String, int> nodeWifiCounts = {};
  final Map<String, int> nodeBleCount = {};

  List<Engine> get activeEngines {
    final set = <Engine>{};
    for (final t in selectedTargets) {
      set.addAll(t.engines(radio));
    }
    return set.toList();
  }

  List<Engine> get _fleetEngines {
    if (!_ble.isManagerConnected) return activeEngines;
    final set = <Engine>{};
    for (final t in selectedTargets) {
      set.addAll(t.engines(WardriveRadio.both));
    }
    return set.toList();
  }

  /// Local-only WiFi/BLE counts (excludes peer detections).
  int get localWifiCount =>
      rawWifiCount - nodeWifiCounts.values.fold(0, (a, b) => a + b);
  int get localBleCount =>
      rawBleCount - nodeBleCount.values.fold(0, (a, b) => a + b);

  Map<String, int> get detectionsPerNode {
    final m = <String, int>{};
    for (final k in {...nodeWifiCounts.keys, ...nodeBleCount.keys}) {
      m[k] = (nodeWifiCounts[k] ?? 0) + (nodeBleCount[k] ?? 0);
    }
    return m;
  }

  String? foxhuntTarget;
  String sessionId = '';

  LatLng? pendingZoomTarget;

  /// Detection the map should isolate when it consumes [pendingZoomTarget].
  Detection? pendingZoomDetection;

  int sessionLoadEpoch = 0;

  /// Request the wardrive map to zoom to a specific location.
  void requestZoom(double lat, double lon, {Detection? detection}) {
    pendingZoomTarget = LatLng(lat, lon);
    pendingZoomDetection = detection;
    notifyListeners();
  }

  /// Consume the pending zoom target (called by wardrive screen after moving camera).
  LatLng? consumeZoomTarget() {
    final target = pendingZoomTarget;
    pendingZoomTarget = null;
    return target;
  }

  Detection? consumeZoomDetection() {
    final d = pendingZoomDetection;
    pendingZoomDetection = null;
    return d;
  }

  DateTime? startTime;
  final Map<String, Detection> _dedupedByMac = {};
  final List<Detection> _dedupedOrdered = [];
  List<Detection> get detections => _dedupedOrdered;
  int rawDetectionCount = 0;
  final Set<String> uniqueMacs = {};
  final Set<String> _wifiNetworkMacs = {};
  final Set<String> _flockMacs = {};
  final Map<String, Detection> _flockByMac = {};
  List<Detection>? _cachedFlockDetections;
  final Set<String> _detectorMacs = {};
  final Map<String, Detection> _detectorByMac = {};
  List<Detection>? _cachedDetectorDetections;
  final List<LatLng> routePoints = [];
  double distanceKm = 0;
  LatLng? sessionCenter;
  double _sessionOutlierKm = 200.0;
  GpsPosition? lastGpsForDistance;
  GpsPosition? currentPosition;
  int get droneCount => droneDetections.length;

  List<WatchlistEntry> Function()? _watchlistGetter;
  void setWatchlistGetter(List<WatchlistEntry> Function() g) {
    _watchlistGetter = g;
  }

  String? _rescanSessionId;
  int _rescanCur = 0;
  int _rescanTotal = 0;
  int _rescanNewDetector = 0;
  int _rescanNewFlock = 0;
  String? get rescanSessionId => _rescanSessionId;
  int get rescanCur => _rescanCur;
  int get rescanTotal => _rescanTotal;
  int get rescanNewDetector => _rescanNewDetector;
  int get rescanNewFlock => _rescanNewFlock;

  List<Detection> get dedupedDetections => _dedupedOrdered;

  StreamSubscription<Detection>? _detSub;
  StreamSubscription<GpsPosition>? _gpsSub;
  Timer? _statsTimer;
  bool _inExclusion = false;
  bool get inExclusion => _inExclusion;
  bool _autoPcapPausedByExclusion = false;

  bool get isRunning => state == WardriveState.running;
  bool get isActive => state != WardriveState.idle;
  int get flockCount => _flockMacs.length;
  int get detectorCount => _detectorMacs.length;

  List<Detection> get flockDetections {
    if (_cachedFlockDetections != null) return _cachedFlockDetections!;
    final list = _flockByMac.values.toList();
    list.sort((a, b) => b.appTimestamp.compareTo(a.appTimestamp));
    _cachedFlockDetections = list;
    return list;
  }

  List<Detection> get detectorDetections {
    if (_cachedDetectorDetections != null) return _cachedDetectorDetections!;
    final list = _detectorByMac.values.toList();
    list.sort((a, b) => b.appTimestamp.compareTo(a.appTimestamp));
    _cachedDetectorDetections = list;
    return list;
  }

  bool get includesDrone =>
      selectedTargets.any((t) => t.engines(radio).contains(Engine.skySpy));

  bool get includesDetector =>
      selectedTargets.any((t) => t.engines(radio).contains(Engine.detector));

  List<Detection> get droneDetections {
    final byKey = <String, Detection>{};
    for (final d in _dedupedOrdered) {
      if (d.engine != Engine.skySpy) continue;
      final id = (d.odid?.uavId?.isNotEmpty ?? false)
          ? d.odid!.uavId!
          : d.macAddress;
      final ex = byKey[id];
      if (ex == null ||
          odidCompleteness(d.odid) > odidCompleteness(ex.odid)) {
        byKey[id] = d;
      }
    }
    final list = byKey.values.toList();
    list.sort((a, b) => b.appTimestamp.compareTo(a.appTimestamp));
    return list;
  }

  /// Persist and publish a direct change to [selectedTargets] made from outside
  /// the normal toggle path (e.g. the wardrive tile defaulting to WiGLE).
  void notifyTargetsChanged() {
    notifyListeners();
    _savePrefs();
  }

  void toggleTarget(WardriveTarget t) {
    if (isActive) return;
    if (selectedTargets.contains(t)) {
      selectedTargets.remove(t);
    } else {
      selectedTargets.add(t);
    }
    notifyListeners();
    _savePrefs();
  }

  Future<void> onChipTap(WardriveTarget t, Set<WardriveTarget> liveTargets) async {
    if (state != WardriveState.running) {
      if (selectedTargets.contains(t)) {
        selectedTargets.remove(t);
      } else {
        selectedTargets.add(t);
      }
      notifyListeners();
      _savePrefs();
      return;
    }
    if (selectedTargets.contains(t)) {
      await _removeTargetLive(t);
    } else {
      await _addTargetLive(t);
    }
  }

  Future<void> _addTargetLive(WardriveTarget t) async {
    selectedTargets.add(t);
    _savePrefs();
    notifyListeners();
    await _ensureLoggingAttached();
    final engines =
        _ble.isManagerConnected ? t.engines(WardriveRadio.both) : t.engines(radio);
    await _enableEnginesSequentially(engines);
    notifyListeners();
    DebugLog.log('WARDRIVE: added target $t live -> $activeLabel');
  }

  Future<void> _removeTargetLive(WardriveTarget t) async {
    selectedTargets.remove(t);
    final keep = <Engine>{};
    for (final rt in selectedTargets) {
      keep.addAll(rt.engines(radio));
    }
    final toStop = t.engines(radio).toSet()..removeAll(keep);
    for (final e in toStop) {
      try {
        await _ble.disableEngine(e);
      } catch (err) {
        DebugLog.log('WARDRIVE: removeTargetLive $e error: $err');
      }
    }
    _savePrefs();
    _updateLiveActivity();
    notifyListeners();
    DebugLog.log('WARDRIVE: removed target $t live -> $activeLabel');
  }

  void setTarget(WardriveTarget t) {
    if (isActive) return;
    selectedTargets
      ..clear()
      ..add(t);
    notifyListeners();
    _savePrefs();
  }

  void setRadio(WardriveRadio r) {
    if (isActive) return;
    radio = r;
    notifyListeners();
    _savePrefs();
  }

  Future<void> stopOwnedEngine(Engine e) async {
    if (!isActive) return;
    if (e == Engine.wardrive) {
      await stopSession();
      return;
    }
    final removed = selectedTargets.where((t) => t.engines(radio).contains(e)).toSet();
    if (removed.isEmpty) {
      try {
        await _ble.disableEngine(e);
      } catch (err) {
        DebugLog.log('WARDRIVE: stopOwnedEngine $e error: $err');
      }
      return;
    }
    final remaining = selectedTargets.where((t) => !removed.contains(t)).toSet();
    if (remaining.isEmpty) {
      await stopSession();
      return;
    }
    final keep = <Engine>{};
    for (final t in remaining) {
      keep.addAll(t.engines(radio));
    }
    final toStop = <Engine>{};
    for (final t in removed) {
      toStop.addAll(t.engines(radio));
    }
    toStop.removeAll(keep);
    selectedTargets
      ..clear()
      ..addAll(remaining);
    for (final eng in toStop) {
      try {
        await _ble.disableEngine(eng);
      } catch (err) {
        DebugLog.log('WARDRIVE: stopOwnedEngine $eng error: $err');
      }
    }
    _updateLiveActivity();
    notifyListeners();
  }

  Future<void> removeDetectionGroup(Detection d) async {
    final uav = d.odid?.uavId;
    final byUav = uav != null && uav.isNotEmpty;
    final macs = <String>{};
    final keys = <String>[];
    _dedupedByMac.forEach((k, det) {
      final match =
          byUav ? (det.odid?.uavId == uav) : (det.macAddress == d.macAddress);
      if (match) {
        keys.add(k);
        macs.add(det.macAddress);
      }
    });
    for (final k in keys) {
      final det = _dedupedByMac.remove(k);
      if (det != null) _dedupedOrdered.remove(det);
    }
    for (final m in macs) {
      _flockByMac.remove(m);
      _detectorByMac.remove(m);
      _flockMacs.remove(m);
      _detectorMacs.remove(m);
      uniqueMacs.remove(m);
    }
    _cachedFlockDetections = null;
    _cachedDetectorDetections = null;
    final sid = sessionId.isNotEmpty ? sessionId : (_lastCompletedSessionId ?? '');
    if (sid.isNotEmpty && macs.isNotEmpty) {
      try {
        await _db.deleteDetectionsByMacs(sid, macs.toList());
      } catch (e) {
        DebugLog.log('WARDRIVE: deleteDetectionsByMacs failed: $e');
      }
    }
    notifyListeners();
  }

  Future<void> startSession() async {
    if (isActive) {
      DebugLog.log('WARDRIVE: start ignored — already $state');
      return;
    }
    final targets = wardriveTargetsForStart(selectedTargets);
    if (selectedTargets.isEmpty) {
      // Nothing selected: run unfiltered for WiGLE, on both radios so Bluetooth
      // devices are captured too. Persisted, so the chips on the map agree with
      // what is running.
      selectedTargets
        ..clear()
        ..addAll(targets);
      radio = WardriveRadio.both;
      _savePrefs();
      DebugLog.log('WARDRIVE: no target — defaulting to WiGLE all-networks, WiFi+BLE');
    }
    final gpsOk = await _gps.start();
    if (!gpsOk) {
      DebugLog.log('WARDRIVE: GPS failed to start — check permissions/services');
    }

    startTime = DateTime.now();
    sessionId = const Uuid().v4();
    _dedupedOrdered.clear();
    _dedupedByMac.clear();
    rawDetectionCount = 0;
    rawWifiCount = 0;
    rawBleCount = 0;
    geofenceSuppressed = 0;
    nodeWifiCounts.clear();
    nodeBleCount.clear();
    uniqueMacs.clear();
    _wifiNetworkMacs.clear();
    _flockMacs.clear();
    _flockByMac.clear();
    _cachedFlockDetections = null;
    _detectorMacs.clear();
    _detectorByMac.clear();
    _cachedDetectorDetections = null;
    routePoints.clear();
    distanceKm = 0;    lastGpsForDistance = null;
    gpsTagsRejected = 0;
    foxhuntTarget = null;

    // Reload geofence exclusion zones at session start
    await _geofenceFilter.reload();
    _notificationService.resetMilestones();

    _db.insertSession(SessionsCompanion(
      id: drift.Value(sessionId),
      name: drift.Value('Wardrive ${DateTime.now().toIso8601String().substring(0, 16)}'),
      nodeId: const drift.Value('default'),
      startedAt: drift.Value(DateTime.now().millisecondsSinceEpoch),
      isWardrive: const drift.Value(true),
    )).catchError((e) => DebugLog.log('WARDRIVE: insertSession failed: $e'));

    state = WardriveState.running;
    _userStopped = false;
    _setSessionIntent(true);
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _linkLostAt = null;
    _ble.wardriveSessionActive = true;
    radioTransition = 'starting';
    notifyListeners();

    _detSub?.cancel();
    _gpsSub?.cancel();
    _statsTimer?.cancel();
    _detSub = _ble.detections.listen(_onDetection);
    _gpsSub = _gps.positionStream.listen(_onGpsUpdate);
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());

    final cached = _gps.lastPosition;
    if (cached != null) {
      currentPosition = cached;
    }

    // A session can be started from inside an exclusion zone. The position
    // stream only reports transitions, so without this the radios come up and
    // stay up until the user crosses the boundary outwards.
    final startFix = currentPosition;
    _inExclusion = startFix != null &&
        _geofenceFilter.isExcludedNullable(startFix.latitude, startFix.longitude);
    if (_inExclusion) {
      DebugLog.log('WARDRIVE: started inside an exclusion zone — radios held off');
    }

    _preSessionEngines = await _readRunningEngines();
    if (_preSessionEngines.isNotEmpty) {
      DebugLog.log('WARDRIVE: engines already running, will be left alone on '
          'stop: ${_preSessionEngines.map((e) => e.name).join(', ')}');
    }

    await _enableEnginesSequentially(_fleetEngines);

    radioTransition = null;
    WakelockPlus.enable();

    // Start iOS Live Activity (Dynamic Island / Lock Screen)
    _updateLiveActivity(allowStart: true);

    notifyListeners();
    DebugLog.log('WARDRIVE: started $sessionId targets=$activeLabel radio=${radio.label}');
  }

  Future<void> stopSession() async {
    DebugLog.log('WARDRIVE: stop requested (state=$state)');
    // Deliberately NOT idle yet. This used to flip to idle and notify before
    // asking the board to stop, with the teardown failure only logged — so the
    // UI said "off" while the board kept scanning, streaming detections and
    // raising notifications. Only an app restart (reconnect + resync) stopped
    // it. Stay in 'stopping' until the board confirms.
    radioTransition = 'stopping';
    _userStopped = true;
    _setSessionIntent(false);
    _droppedWhileRunning = false;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _linkLostAt = null;
    pendingReconnectPrompt = false;
    stopIncomplete = false;
    _ble.wardriveSessionActive = false;
    notifyListeners();

    _detSub?.cancel();
    _gpsSub?.cancel();
    _statsTimer?.cancel();
    _detSub = null;
    _gpsSub = null;
    _statsTimer = null;

    var stopped = false;
    try {
      stopped = await _teardownAndVerify();
      if (!stopped) {
        DebugLog.log('WARDRIVE: engines still active after teardown — retrying');
        stopped = await _teardownAndVerify();
      }
    } catch (e) {
      DebugLog.log('WARDRIVE: engine teardown failed: $e');
    } finally {
      WakelockPlus.disable();
      _liveActivity.end();
    }

    state = WardriveState.idle;
    // Only a warning when the link is up: if the board is unreachable we
    // cannot confirm, and the engine state is re-pushed on reconnect anyway.
    stopIncomplete = !stopped && _ble.isConnected;
    if (stopIncomplete) {
      DebugLog.log('WARDRIVE: BOARD MAY STILL BE SCANNING — stop not confirmed');
    }
    radioTransition = null;
    notifyListeners();

    _preSessionEngines = {};
    await _finalizeSession();
  }

  /// True when a stop was requested, the link was up, and the board did **not**
  /// confirm its engines were off. The board may still be scanning.
  bool stopIncomplete = false;

  // -- Resume window --
  //
  // See [kWardriveResumeWindow]. A session whose board has gone is ended
  // deliberately, saved and announced, rather than left showing "running"
  // over a link that is recording nothing.

  DateTime? _linkLostAt;
  Timer? _resumeTimer;

  /// When the current session lost its link, or null while the link is up.
  /// Exposed so the UI can show how long is left rather than a bare spinner.
  DateTime? get linkLostAt => _linkLostAt;
  bool get isAwaitingResume => _linkLostAt != null && state == WardriveState.running;

  void _beginResumeWindow() {
    if (_linkLostAt != null) return; // already counting; do not restart it
    _linkLostAt = DateTime.now();
    _resumeTimer?.cancel();
    _resumeTimer = Timer(kWardriveResumeWindow, _giveUpOnResume);
    DebugLog.log('WARDRIVE: link lost mid-session — '
        '${kWardriveResumeWindow.inMinutes} min to come back');
    notifyListeners();
  }

  /// Returns false when the session was ended because the window had already
  /// elapsed, so the caller should not go on to re-assert a dead session.
  bool _closeResumeWindow() {
    final lost = _linkLostAt;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    if (lost == null) return true;
    final waited = DateTime.now().difference(lost);
    if (state == WardriveState.running && resumeWindowExpired(waited)) {
      DebugLog.log('WARDRIVE: board returned after ${waited.inSeconds}s, past '
          'the resume window — ending the session it missed');
      _giveUpOnResume();
      return false;
    }
    _linkLostAt = null;
    DebugLog.log('WARDRIVE: board back after ${waited.inSeconds}s — session continues');
    notifyListeners();
    return true;
  }

  void _giveUpOnResume() {
    final lost = _linkLostAt;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _linkLostAt = null;
    if (state != WardriveState.running) return;
    final waited = lost == null ? kWardriveResumeWindow : DateTime.now().difference(lost);
    DebugLog.log('WARDRIVE: no board for ${waited.inSeconds}s — ending and saving');
    _notificationService.onWardriveEndedAfterLostLink(
      uniqueCount: uniqueMacs.length,
      waited: waited,
    );
    // stopSession saves the session and tears down what it can. With the board
    // unreachable the teardown writes fail, which it already handles — and the
    // engines are re-pushed on the next connect anyway.
    unawaited(stopSession());
  }

  /// Engines that were already running when this session started.
  ///
  /// A wardrive borrows the radios; it does not own everything it finds
  /// running. Someone who had the detector on before starting a wardrive
  /// expects it still to be on afterwards, so teardown leaves these alone.
  Set<Engine> _preSessionEngines = {};

  /// Which engines the board currently reports as running, or an empty set if
  /// it cannot be asked. Empty is the safe answer: it means teardown stops
  /// everything, which is the old behaviour.
  Future<Set<Engine>> _readRunningEngines() async {
    if (!_ble.isConnected) return {};
    final mask = await _ble
        .readActiveEngineMask()
        .timeout(const Duration(seconds: 3), onTimeout: () => -1);
    return enginesFromMask(mask);
  }

  /// Tear down, then read the board's own engine mask back to check it took.
  ///
  /// `disableEngine` returns silently when the control characteristic is
  /// missing and swallows its own write errors, so "no exception" is not
  /// evidence that anything stopped. Only the read-back is.
  Future<bool> _teardownAndVerify() async {
    await _teardownEngines().timeout(const Duration(seconds: 4));
    if (!_ble.isConnected) return false;
    final mask = await _ble.readActiveEngineMask().timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
    return teardownComplete(mask, _preSessionEngines);
  }

  Future<void> _teardownEngines() async {
    const wardriveEngines = [
      Engine.wardrive,
      Engine.flockWifi,
      Engine.axon,
      Engine.skySpy,
      Engine.detector,
      Engine.pcap,
    ];
    final toStop =
        wardriveEngines.where((e) => !_preSessionEngines.contains(e)).toList();

    // disableAllEngines is a single write and cheaper on the C5, but it is
    // indiscriminate — only usable when there is nothing to preserve.
    if (_preSessionEngines.isEmpty &&
        _ble.board.toLowerCase().contains('c5')) {
      await _ble.disableAllEngines();
      return;
    }
    for (final engine in toStop) {
      try {
        await _ble.disableEngine(engine);
      } catch (e) {
        DebugLog.log('WARDRIVE: disable $engine error: $e');
      }
    }
  }

  Future<void> _finalizeSession() async {
    final sid = sessionId;
    if (sid.isNotEmpty && startTime != null) {
      try {
        await _db.updateSession(SessionsCompanion(
          id: drift.Value(sid),
          endedAt: drift.Value(DateTime.now().millisecondsSinceEpoch),
          detectionCount: drift.Value(detections.length),
          uniqueMacCount: drift.Value(uniqueMacs.length),
          distanceKm: drift.Value(distanceKm),
        ));
      } catch (e) {
        DebugLog.log('WARDRIVE: updateSession finalize failed for $sid: $e');
      }

      await _saveCsv(sid, detections);

      DebugLog.log('WARDRIVE: saved $sid (${detections.length} det, ${uniqueMacs.length} unique, ${_flockMacs.length} flock)');

      final wl = _watchlistGetter?.call() ?? const <WatchlistEntry>[];
      _rescanSessionId = sid;
      _rescanCur = 0;
      _rescanTotal = detections.length;
      _rescanNewDetector = 0;
      _rescanNewFlock = 0;
      notifyListeners();
      unawaited(() async {
        try {
          final res = await WigleCsvRescan.rescanSession(
            _db,
            sid,
            watchlist: wl,
            onProgress: (cur, total, newDet, newFlock) {
              _rescanCur = cur;
              _rescanTotal = total;
              _rescanNewDetector = newDet;
              _rescanNewFlock = newFlock;
              notifyListeners();
            },
          );
          DebugLog.log(
              'WARDRIVE: rescan $sid scanned=${res.rowsScanned} updated=${res.rowsUpdated} det=${res.newDetectorMacs} flock=${res.newFlockMacs}');
        } catch (e) {
          DebugLog.log('WARDRIVE: rescan failed $e');
        }
        _rescanSessionId = null;
        notifyListeners();
      }());
    }

    if (sid.isNotEmpty) _lastCompletedSessionId = sid;
    notifyListeners();
  }

  Future<void> finalizeForShutdown() async {
    if (!isActive) return;
    final sid = sessionId;
    if (sid.isEmpty || startTime == null) return;
    _ble.wardriveSessionActive = false;
    try {
      await _db.updateSession(SessionsCompanion(
        id: drift.Value(sid),
        endedAt: drift.Value(DateTime.now().millisecondsSinceEpoch),
        detectionCount: drift.Value(detections.length),
        uniqueMacCount: drift.Value(uniqueMacs.length),
        distanceKm: drift.Value(distanceKm),
      ));
      DebugLog.log('WARDRIVE: finalized on shutdown $sid (${detections.length} det)');
    } catch (e) {
      DebugLog.log('WARDRIVE: shutdown finalize failed for $sid: $e');
    }
  }

  Future<void> continueAfterReconnect() async {
    pendingReconnectPrompt = false;
    _droppedWhileRunning = false;
    notifyListeners();
    await _adoptFirmwareState();
    _pushWifiBand();
  }

  Future<void> stopAfterReconnect() async {
    pendingReconnectPrompt = false;
    await stopSession();
  }

  /// Session ID of the most recently completed or loaded session.
  String? _lastCompletedSessionId;
  String? get lastCompletedSessionId => _lastCompletedSessionId;

  /// ID of the currently loaded (viewed) session on the map.
  String? get loadedSessionId => !isActive ? _lastCompletedSessionId : null;

  /// Clear the loaded session from the map (e.g., after deletion).
  void clearLoadedSession() => clearMapData();

  /// Whether we have map data from a completed/loaded session.
  bool get hasSessionData =>
      routePoints.isNotEmpty || detections.isNotEmpty;

  /// Clear map overlay from a completed/loaded session.
  void clearMapData() {
    _dedupedOrdered.clear();
    _dedupedByMac.clear();
    routePoints.clear();
    uniqueMacs.clear();
    _flockMacs.clear();
    _flockByMac.clear();
    _cachedFlockDetections = null;
    _detectorMacs.clear();
    _detectorByMac.clear();
    _cachedDetectorDetections = null;
    rawDetectionCount = 0;
    nodeWifiCounts.clear();
    nodeBleCount.clear();
    distanceKm = 0;    flockFilter = false;
    detectorFilter = false;
    _lastCompletedSessionId = null;
    sessionCenter = null;
    notifyListeners();
  }

  bool isWithinSession(double lat, double lon) {
    final c = sessionCenter;
    if (c == null) return true;
    final d = _haversineKm(c.latitude, c.longitude, lat, lon);
    return d.isFinite && d <= _sessionOutlierKm;
  }

  /// Load a previously saved wardrive session onto the map.
  Future<void> loadSession(String sid) async {
    if (isActive) return;

    final dbRows = await _db.getDetectionMapsForSession(sid);
    _dedupedOrdered.clear();
    _dedupedByMac.clear();
    _flockByMac.clear();
    _cachedFlockDetections = null;
    _detectorByMac.clear();
    _cachedDetectorDetections = null;
    _detectorMacs.clear();
    rawDetectionCount = 0;
    rawWifiCount = 0;
    rawBleCount = 0;
    geofenceSuppressed = 0;
    nodeWifiCounts.clear();
    nodeBleCount.clear();
    uniqueMacs.clear();
    _flockMacs.clear();
    routePoints.clear();
    distanceKm = 0;    lastGpsForDistance = null;
    gpsTagsRejected = 0;
    foxhuntTarget = null;

    final lats = <double>[];
    final lons = <double>[];
    for (final row in dbRows) {
      final det = _detectionFromDb(row);
      rawDetectionCount++;
      uniqueMacs.add(det.macAddress);
      final isFlock =
          det.engine == Engine.flockWifi;
      if (isFlock) {
        _flockMacs.add(det.macAddress);
        _flockByMac[det.macAddress] = det;
      }
      if (det.engine == Engine.detector) {
        _detectorMacs.add(det.macAddress);
        _detectorByMac[det.macAddress] = det;
      }

      final key = '${det.macAddress}|${det.engine.name}';
      final existing = _dedupedByMac[key];
      if (existing != null) {
        // Replay used to keep the first sighting's position while the live
        // path kept the latest, so the same device sat in two different places
        // depending on whether you were watching the run or reopening it.
        final base = sightingWinsPlot(det.latitude, det.longitude, det.rssi,
                existing.latitude, existing.longitude, existing.rssi)
            ? det
            : existing;
        _dedupedByMac[key] = base.copyWith(count: existing.count + 1);
      } else {
        _dedupedByMac[key] = det;
      }

      if (_isPlausibleCoord(det.latitude, det.longitude)) {
        lats.add(det.latitude!);
        lons.add(det.longitude!);
      }
    }

    LatLng? center;
    if (lats.isNotEmpty) {
      final ls = List<double>.from(lats)..sort();
      final os = List<double>.from(lons)..sort();
      center = LatLng(ls[ls.length ~/ 2], os[os.length ~/ 2]);
    }
    sessionCenter = center;
    const outlierKm = 200.0;
    const minRoutePointSepKm = 0.005; // ~5m
    final anchor = center;
    bool inRange(double lat, double lon) =>
        anchor == null ||
        _haversineKm(anchor.latitude, anchor.longitude, lat, lon) <= outlierKm;

    // Pass 2: build ordered detection list (no shifts) + downsampled route.
    _dedupedOrdered
      ..clear()
      ..addAll(_dedupedByMac.values.toList().reversed);

    double? lastRouteLat;
    double? lastRouteLon;
    for (final det in _dedupedByMac.values) {
      if (!_isPlausibleCoord(det.latitude, det.longitude)) continue;
      final lat = det.latitude!;
      final lon = det.longitude!;
      if (!inRange(lat, lon)) continue;
      if (lastRouteLat == null) {
        routePoints.add(LatLng(lat, lon));
        lastRouteLat = lat;
        lastRouteLon = lon;
      } else {
        final stepKm = _haversineKm(lastRouteLat, lastRouteLon!, lat, lon);
        if (stepKm.isFinite && stepKm >= minRoutePointSepKm) {
          routePoints.add(LatLng(lat, lon));
          distanceKm += stepKm;
          lastRouteLat = lat;
          lastRouteLon = lon;
        }
      }
    }
    _sessionOutlierKm = outlierKm;

    // Load session metadata for start time display.
    final sessionRow = await _db.getSessionById(sid);
    if (sessionRow != null) {
      startTime = DateTime.fromMillisecondsSinceEpoch(
        (sessionRow as dynamic).startedAt as int,
      );
    }

    sessionId = sid;
    _lastCompletedSessionId = sid;
    sessionLoadEpoch++;
    notifyListeners();
    DebugLog.log('WARDRIVE: loaded session $sid (${detections.length} det, ${routePoints.length} pts)');
  }

  /// Convert a detection map (from `getDetectionMapsForSession`) to our model.
  Detection _detectionFromDb(Map<String, dynamic> row) => detectionFromDbRow(row);

  /// Save WiGLE CSV to persistent storage.
  Future<String?> _saveCsv(String sid, List<Detection> dets) async {
    if (dets.isEmpty) return null;
    try {
      final dir = await _wardriveDir();
      final filename = await _csvFilename(sid);
      final file = File(path.join(dir.path, filename));
      final csv = WigleCsv.generate(dets, ignoreList: _ignoreList, geofenceFilter: _geofenceFilter, board: _ble.board, firmwareVersion: _ble.firmwareVersion);
      await file.writeAsString(csv);
      DebugLog.log('WARDRIVE: CSV saved ${file.path}');
      return file.path;
    } catch (e) {
      DebugLog.log('WARDRIVE: CSV save failed: $e');
      return null;
    }
  }

  Future<File?> getCsvFile(String sid) async {
    final dir = await _wardriveDir();
    final filename = await _csvFilename(sid);
    final file = File(path.join(dir.path, filename));
    final regenerated = await _regenerateCsvFromDb(sid, file);
    if (regenerated != null) return regenerated;
    // Fallback: check old UUID-named file
    final legacyFile = File(path.join(dir.path, '$sid.csv'));
    if (await legacyFile.exists()) return legacyFile;
    return null;
  }

  /// The name a session's CSV is written and uploaded under.
  Future<String> csvFilenameFor(String sid) => _csvFilename(sid);

  /// Build a human-readable CSV filename from session start time.
  Future<String> _csvFilename(String sid) async {
    final session = await _db.getSessionById(sid);
    if (session != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        (session as dynamic).startedAt as int,
      );
      final stamp = '${dt.year}${_pad(dt.month)}${_pad(dt.day)}_'
          '${_pad(dt.hour)}${_pad(dt.minute)}${_pad(dt.second)}';
      return 'ouispy_wardrive_$stamp.csv';
    }
    return 'ouispy_wardrive_$sid.csv';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// Regenerate CSV from database detections when file is missing.
  Future<File?> _regenerateCsvFromDb(String sid, File file) async {
    try {
      final dbRows = await _db.getDetectionMapsForSession(sid);
      if (dbRows.isEmpty) return null;
      final dets = dbRows.map(_detectionFromDb).toList();
      final csv = WigleCsv.generate(dets, ignoreList: _ignoreList, geofenceFilter: _geofenceFilter, board: _ble.board, firmwareVersion: _ble.firmwareVersion);
      await file.writeAsString(csv);
      DebugLog.log('WARDRIVE: CSV regenerated from DB for $sid (${dets.length} det)');
      return file;
    } catch (e) {
      DebugLog.log('WARDRIVE: CSV regeneration failed: $e');
      return null;
    }
  }

  /// List all saved CSV files.
  Future<List<File>> savedCsvFiles() async {
    final dir = await _wardriveDir();
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  static Future<Directory> _wardriveDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(path.join(docs.path, 'wardrives'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  void pauseSession() {
    state = WardriveState.paused;
    notifyListeners();
  }

  void resumeSession() {
    state = WardriveState.running;
    notifyListeners();
    _reEnableEngines();
  }

  /// Toggle flock display filter (does NOT control engines).
  void toggleDetectorFilter() {
    detectorFilter = !detectorFilter;
    notifyListeners();
  }

  void toggleFlockFilter() {
    flockFilter = !flockFilter;
    notifyListeners();
  }

  void setFoxhuntTarget(String mac, {int channel = 0}) {
    _ble.enableEngine(Engine.foxhunter);
    _ble.setFoxhunterTarget(mac, channel: channel);
    foxhuntTarget = mac;
    _updateLiveActivity();
    notifyListeners();
  }

  /// Radio bitmask for firmware config: 0x01=WiFi, 0x02=BLE, 0x03=both.
  int get radioBitmask => switch (radio) {
    WardriveRadio.wifi => 0x01,
    WardriveRadio.ble => 0x02,
    WardriveRadio.both => 0x03,
  };

  Future<void> _enableEnginesSequentially(List<Engine> engineList) async {
    if (engineList.any((e) => e.isWifi)) {
      await _ble.sendWifiBand(wifiBandMask);
      await Future.delayed(const Duration(milliseconds: 80));
    }
    for (final engine in engineList) {
      // Each engine is a round trip, so entering a zone part-way through this
      // loop would otherwise keep switching radios on behind the pause.
      if (state == WardriveState.idle || _inExclusion) return;
      if (engine == Engine.wardrive) {
        await _ble.sendEngineConfig(engine, _wardriveConfigPayload);
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (state == WardriveState.idle || _inExclusion) return;
      await _ble.enableEngine(engine, radio: radioBitmask);
      if (engine.isWifi) {
        await _awaitEngineUp(engine, const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _awaitEngineUp(Engine engine, Duration ceiling) async {
    try {
      await _ble.engineStates
          .firstWhere((s) =>
              engine.index < s.states.length &&
              s.states[engine.index] != EngineState.disabled)
          .timeout(ceiling);
    } on TimeoutException {
      DebugLog.log('WARDRIVE: ${engine.name} state not confirmed in '
          '${ceiling.inMilliseconds}ms, continuing');
    }
  }

  void _setSessionIntent(bool on) {
    if (_sessionIntent == on) return;
    _sessionIntent = on;
    SharedPreferences.getInstance()
        .then((p) => p.setBool('wd_sessionIntent', on));
  }

  Future<void> _adoptFirmwareState() async {
    await _prefsLoaded;
    if (_ble.offlineScanEnabled) {
      if (selectedTargets.remove(WardriveTarget.wigle)) {
        DebugLog.log('WARDRIVE: keep-running on — wigle chip deselected (wigle not running)');
        _savePrefs();
        notifyListeners();
      }
      try {
        await _ble.disableEngine(Engine.wardrive);
      } catch (e) {
        DebugLog.log('WARDRIVE: keep-running wardrive-disable error: $e');
      }
    }
    if (state == WardriveState.paused) return;
    if (state == WardriveState.running) {
      if (_ble.offlineScanEnabled) {
        await _reconcileTargetsToFirmware();
      } else {
        _reEnableEngines();
      }
      return;
    }

    if (!_ble.offlineScanEnabled || _userStopped) {
      await _disableStaleEngines();
      return;
    }

    if (!canAdoptSession(
      offlineScanEnabled: _ble.offlineScanEnabled,
      userStopped: _userStopped,
      sessionIntent: _sessionIntent,
    )) {
      DebugLog.log('WARDRIVE: board busy but no session was started — '
          'leaving those engines to their own tiles');
      return;
    }

    var mask = await _ble.readCommandedEngineMask();
    for (var i = 0; mask < 0 && i < 3; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      mask = await _ble.readCommandedEngineMask();
    }
    if (mask < 0) return;

    const klass = [
      Engine.flockWifi,
      Engine.axon,
      Engine.skySpy,
      Engine.detector,
    ];
    if (!klass.any((e) => (mask & e.bitmask) != 0)) {
      DebugLog.log('WARDRIVE: firmware idle — nothing to adopt');
      return;
    }
    final adopted =
        reconciledTargets(mask, selectedTargets, _ble.offlineScanEnabled);
    selectedTargets
      ..clear()
      ..addAll(adopted);
    await _ensureLoggingAttached();
    state = WardriveState.running;
    _ble.wardriveSessionActive = true;
    notifyListeners();
    DebugLog.log('WARDRIVE: adopted firmware mask 0x${mask.toRadixString(16)} -> $activeLabel');
  }

  Future<void> _reconcileTargetsToFirmware() async {
    var mask = await _ble.readCommandedEngineMask();
    for (var i = 0; mask < 0 && i < 3; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      mask = await _ble.readCommandedEngineMask();
    }
    if (mask < 0) return;
    final t =
        reconciledTargets(mask, selectedTargets, _ble.offlineScanEnabled);
    if (t.isEmpty) return;
    if (t.length == selectedTargets.length && selectedTargets.containsAll(t)) {
      return;
    }
    selectedTargets
      ..clear()
      ..addAll(t);
    _savePrefs();
    notifyListeners();
    DebugLog.log('WARDRIVE: reconciled targets to firmware mask 0x${mask.toRadixString(16)} -> $activeLabel');
  }

  Future<void> _disableStaleEngines() async {
    const stale = [
      Engine.wardrive,
      Engine.flockWifi,
      Engine.axon,
      Engine.skySpy,
      Engine.detector,
      Engine.foxhunter,
    ];
    for (final e in stale) {
      // Each disable is a round trip to the board, so this loop spans hundreds
      // of milliseconds. A session started while it runs would have its engines
      // switched off underneath it by the disables still queued here.
      if (state != WardriveState.idle) {
        DebugLog.log('WARDRIVE: stale-disable abandoned — a session started');
        return;
      }
      try {
        await _ble.disableEngine(e);
      } catch (err) {
        DebugLog.log('WARDRIVE: stale-disable $e error: $err');
      }
    }
    DebugLog.log('WARDRIVE: idle — disabled stale node engines to match UI');
  }

  bool _reEnabling = false;
  void _reEnableEngines() {
    if (_reEnabling) return;
    _reEnabling = true;
    DebugLog.log('WARDRIVE: re-enabling engines after reconnect');
    _enableEnginesSequentially(_fleetEngines).whenComplete(() {
      _reEnabling = false;
      if (foxhuntTarget != null) {
        _ble.enableEngine(Engine.foxhunter);
        _ble.setFoxhunterTarget(foxhuntTarget!);
      }
    });
  }

  Future<void> _ensureLoggingAttached() async {
    if (_detSub != null) return;
    sessionId = await _resolveSpoolSessionId();
    startTime ??= DateTime.now();
    _gps.start();
    _detSub = _ble.detections.listen(_onDetection);
    _gpsSub = _gps.positionStream.listen(_onGpsUpdate);
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    final cached = _gps.lastPosition;
    if (cached != null) currentPosition = cached;
    WakelockPlus.enable();
    _updateLiveActivity(allowStart: true);
  }

  Future<String> _resolveSpoolSessionId() async {
    if (sessionId.isNotEmpty) return sessionId;
    await _reconciled;
    final rows = await _db.getWardriveSessions();
    if (rows.isNotEmpty && rows.first.endedAt == null) return rows.first.id;
    final newId = const Uuid().v4();
    await _db.insertSession(SessionsCompanion(
      id: drift.Value(newId),
      name: drift.Value('Recovered ${DateTime.now().toIso8601String().substring(0, 16)}'),
      nodeId: const drift.Value('default'),
      startedAt: drift.Value(DateTime.now().millisecondsSinceEpoch),
      isWardrive: const drift.Value(true),
    ));
    DebugLog.log('SPOOL: created recovered session $newId');
    return newId;
  }

  /// Detections that arrived without a position and could not borrow the last
  /// known one, this session. Surfaced so a drive through a tunnel is visible
  /// rather than silently turning into bad data.
  int gpsTagsRejected = 0;

  ({double? lat, double? lon, double? acc, bool approx}) _tagGps(Detection d) {
    if (offlineGpsTag && d.latitude == null) {
      final p = _gps.lastPosition;
      if (p != null) {
        final now = DateTime.now();
        if (fixUsableAsFallback(p, now)) {
          return (lat: p.latitude, lon: p.longitude, acc: borrowedFixAccuracy(p, now), approx: true);
        }
        gpsTagsRejected++;
      }
    }
    return (lat: d.latitude, lon: d.longitude, acc: d.accuracy, approx: false);
  }

  String? _ambientSessionId;
  Future<String>? _ambientSessionFuture;

  /// Session row that holds detections captured outside a wardrive session.
  ///
  /// Flagged `isWardrive: false`, so it never appears in the wardrive session
  /// list and is never offered for WiGLE upload — the data is searchable and
  /// exportable as plain detections, but produces no WiGLE CSV.
  Future<String> _ensureAmbientSession() async {
    final existing = _ambientSessionId;
    if (existing != null) return existing;
    return _ambientSessionFuture ??= () async {
      final id = const Uuid().v4();
      await _db.insertSession(SessionsCompanion(
        id: drift.Value(id),
        name: drift.Value('Detections ${DateTime.now().toIso8601String().substring(0, 16)}'),
        nodeId: const drift.Value('default'),
        startedAt: drift.Value(DateTime.now().millisecondsSinceEpoch),
        isWardrive: const drift.Value(false),
      ));
      _ambientSessionId = id;
      return id;
    }();
  }

  /// Persist a live detection when no wardrive session is running.
  ///
  /// Deliberately does NOT touch the map list, session stats or CSV: those
  /// belong to a wardrive session. This is storage only.
  Future<void> _onAmbientDetection(Detection detection) async {
    if (state == WardriveState.running) return;   // session path owns it
    final isBle = detection.isBleDetection;
    if (_ignoreList.shouldSuppress(
      mac: detection.macAddress,
      ssid: detection.ssid.isNotEmpty ? detection.ssid : detection.deviceName,
      isBle: isBle,
    )) {
      return;
    }
    if (_geofenceFilter.isExcludedNullable(detection.latitude, detection.longitude)) {
      return;
    }
    try {
      final sid = await _ensureAmbientSession();
      final g = _tagGps(detection);
      await _db.insertDetection(DetectionsCompanion(
        sessionId: drift.Value(sid),
        nodeId: const drift.Value('default'),
        macAddress: drift.Value(detection.macAddress),
        deviceName: drift.Value(detection.deviceName),
        engine: drift.Value(detection.engine.name),
        detectionMethod: drift.Value(detection.method),
        rssi: drift.Value(detection.rssi),
        channel: drift.Value(detection.channel),
        deviceTimestampMs: drift.Value(detection.deviceTimestampMs),
        appTimestamp: drift.Value(detection.appTimestamp.millisecondsSinceEpoch),
        latitude: drift.Value(g.lat),
        longitude: drift.Value(g.lon),
        accuracy: drift.Value(g.acc),
        ssid: drift.Value(detection.ssid),
        filterDescription: drift.Value(detection.detector?.filterDescription ?? ''),
      ));
    } catch (e) {
      DebugLog.log('WARDRIVE: ambient insert failed: $e');
    }
  }

  Future<void> _onImportedDetection(Detection detection) async {
    _spoolSessionId ??= await (_spoolSessionIdFuture ??= _resolveSpoolSessionId());
    final sid = _spoolSessionId!;
    final deviceNow = _ble.importDeviceNowMs;
    final offsetMs = deviceNow - detection.deviceTimestampMs;
    final wallClock = offsetMs < 0
        ? DateTime.now()
        : DateTime.now().subtract(Duration(milliseconds: offsetMs));
    final g = _tagGps(detection);
    try {
      await _db.insertDetection(DetectionsCompanion(
        sessionId: drift.Value(sid),
        nodeId: const drift.Value('default'),
        macAddress: drift.Value(detection.macAddress),
        deviceName: drift.Value(detection.deviceName),
        engine: drift.Value(detection.engine.name),
        detectionMethod: drift.Value(detection.method),
        rssi: drift.Value(detection.rssi),
        channel: drift.Value(detection.channel),
        deviceTimestampMs: drift.Value(detection.deviceTimestampMs),
        appTimestamp: drift.Value(wallClock.millisecondsSinceEpoch),
        latitude: drift.Value(g.lat),
        longitude: drift.Value(g.lon),
        accuracy: drift.Value(g.acc),
        altitude: drift.Value(detection.altitude),
        speed: drift.Value(detection.speed),
        heading: drift.Value(detection.heading),
        satelliteCount: drift.Value(detection.satelliteCount),
        approxGps: drift.Value(g.approx),
        ssid: drift.Value(detection.ssid),
        authMode: drift.Value(detection.wardrive?.authMode ?? 0),
        uavId: drift.Value(detection.odid?.uavId),
        operatorId: drift.Value(detection.odid?.operatorId),
        droneLat: drift.Value(detection.odid?.droneLat),
        droneLon: drift.Value(detection.odid?.droneLon),
        altitudeMsl: drift.Value(detection.odid?.altitudeMsl),
        heightAgl: drift.Value(detection.odid?.heightAgl),
        droneSpeed: drift.Value(detection.odid?.droneSpeed),
        droneHeading: drift.Value(detection.odid?.droneHeading),
        pilotLat: drift.Value(detection.odid?.pilotLat),
        pilotLon: drift.Value(detection.odid?.pilotLon),
        isRaven: drift.Value(detection.flock?.isRaven),
        ravenFirmware: drift.Value(detection.flock?.ravenFirmware),
        flockSignals: drift.Value(detection.flock?.signals),
      ));
    } catch (e) {
      DebugLog.log('SPOOL: insert failed for ${detection.macAddress}: $e');
    }
    _spoolInserted++;
    DebugLog.log('SPOOL: inserted ${detection.macAddress} → session $sid wallClock=${wallClock.toIso8601String()} ($_spoolInserted/$_spoolExpectedTotal)');
    _maybeConfirmSpool();
  }

  Future<void> _onAwayLiveDetection(Detection detection) async {
    if (state == WardriveState.running) return;
    final sid = _spoolSessionId ??= await (_spoolSessionIdFuture ??= _resolveSpoolSessionId());
    final g = _tagGps(detection);
    try {
      await _db.insertDetection(DetectionsCompanion(
        sessionId: drift.Value(sid),
        nodeId: const drift.Value('default'),
        macAddress: drift.Value(detection.macAddress),
        deviceName: drift.Value(detection.deviceName),
        engine: drift.Value(detection.engine.name),
        detectionMethod: drift.Value(detection.method),
        rssi: drift.Value(detection.rssi),
        channel: drift.Value(detection.channel),
        deviceTimestampMs: drift.Value(detection.deviceTimestampMs),
        appTimestamp: drift.Value(detection.appTimestamp.millisecondsSinceEpoch),
        latitude: drift.Value(g.lat),
        longitude: drift.Value(g.lon),
        accuracy: drift.Value(g.acc),
        altitude: drift.Value(detection.altitude),
        speed: drift.Value(detection.speed),
        heading: drift.Value(detection.heading),
        satelliteCount: drift.Value(detection.satelliteCount),
        approxGps: drift.Value(g.approx),
        ssid: drift.Value(detection.ssid),
        authMode: drift.Value(detection.wardrive?.authMode ?? 0),
        uavId: drift.Value(detection.odid?.uavId),
        operatorId: drift.Value(detection.odid?.operatorId),
        droneLat: drift.Value(detection.odid?.droneLat),
        droneLon: drift.Value(detection.odid?.droneLon),
        altitudeMsl: drift.Value(detection.odid?.altitudeMsl),
        heightAgl: drift.Value(detection.odid?.heightAgl),
        droneSpeed: drift.Value(detection.odid?.droneSpeed),
        droneHeading: drift.Value(detection.odid?.droneHeading),
        pilotLat: drift.Value(detection.odid?.pilotLat),
        pilotLon: drift.Value(detection.odid?.pilotLon),
        isRaven: drift.Value(detection.flock?.isRaven),
        ravenFirmware: drift.Value(detection.flock?.ravenFirmware),
        flockSignals: drift.Value(detection.flock?.signals),
      ));
    } catch (e) {
      DebugLog.log('AWAY-LIVE: insert failed for ${detection.macAddress}: $e');
    }
    DebugLog.log('AWAY-LIVE: persisted ${detection.macAddress} → session $sid');
  }

  Future<void> _onWdLog(WdLogEvent e) async {
    if (e.aborted) {
      DebugLog.log('WDLOG: transfer abandoned at $_wdHandled/$_wdExpected — board keeps it');
      _wdExpected = -1;
      return;
    }
    if (e.isHeader) {
      _wdExpected = e.total;
      _wdHandled = 0;
      _wdSessionId = null;
      _wdSessionIsOwn = false;
      _wdLastHeardMs = 0;
      offlineLogWasFull = e.boardFull;
      DebugLog.log('WDLOG: board holds ${e.total} rows${e.boardFull ? ' (full)' : ''}');
      return;
    }
    if (e.rows.isNotEmpty) {
      if (_wdExpected < 0) return;  // rows without a header: ignore, never confirm
      final keep = <DetectionsCompanion>[];
      for (final r in e.rows) {
        final name = r.name;
        final dropped = _ignoreList.shouldSuppress(mac: r.mac, ssid: name, isBle: r.isBle) ||
            _geofenceFilter.isExcludedNullable(r.latitude, r.longitude);
        if (!dropped) {
          if (_wdSessionId == null) {
            _wdSessionIsOwn = !(isActive && sessionId.isNotEmpty);
            _wdSessionId = _wdSessionIsOwn ? await _newOfflineSession(r.time) : sessionId;
          }
          if (r.time.millisecondsSinceEpoch > _wdLastHeardMs) {
            _wdLastHeardMs = r.time.millisecondsSinceEpoch;
          }
          keep.add(DetectionsCompanion(
            sessionId: drift.Value(_wdSessionId!),
            nodeId: const drift.Value('default'),
            macAddress: drift.Value(r.mac),
            deviceName: drift.Value(r.isBle ? name : ''),
            engine: drift.Value(Engine.wardrive.name),
            detectionMethod: drift.Value(r.isBle ? 'ble_adv' : 'wifi_ap'),
            rssi: drift.Value(r.rssi),
            channel: drift.Value(r.channel),
            deviceTimestampMs: const drift.Value(0),
            appTimestamp: drift.Value(r.time.millisecondsSinceEpoch),
            latitude: drift.Value(r.latitude),
            longitude: drift.Value(r.longitude),
            altitude: drift.Value(r.altitude),
            accuracy: drift.Value(r.accuracy),
            ssid: drift.Value(r.isBle ? '' : name),
            authMode: drift.Value(r.isBle ? 0 : r.auth),
          ));
        }
      }
      try {
        if (keep.isNotEmpty) await _db.batchInsertDetections(keep);
        _wdHandled += e.rows.length;
        offlineRowsImported += keep.length;
      } catch (err) {
        // Not counted, so the transfer is never confirmed and the board keeps
        // the rows for the next connect.
        DebugLog.log('WDLOG: insert failed: $err');
      }
      return;
    }
    if (e.done) {
      DebugLog.log('WDLOG: done handled=$_wdHandled expected=$_wdExpected');
      final own = _wdSessionId;
      if (own != null && _wdSessionIsOwn) {
        // Closed, with its counts, so it lists like any finished session and
        // no later import mistakes it for an open one.
        final dets = await _db.getDetectionsForSession(own);
        await _db.updateSession(SessionsCompanion(
          id: drift.Value(own),
          endedAt: drift.Value(_wdLastHeardMs),
          detectionCount: drift.Value(dets.length),
          uniqueMacCount: drift.Value(await _db.uniqueMacCount(own)),
        ));
      }
      if (_wdExpected >= 0 && _wdHandled >= _wdExpected && _wdExpected > 0) {
        for (var attempt = 1; attempt <= 3; attempt++) {
          try {
            await _ble.confirmWdLogImported();
            break;
          } catch (err) {
            DebugLog.log('WDLOG: clear write failed (attempt $attempt): $err');
            if (attempt < 3) await Future<void>.delayed(Duration(seconds: attempt));
          }
        }
      }
      _wdExpected = -1;
      notifyListeners();
    }
  }

  /// A wardrive session for rows the board recorded while no session ran on
  /// the phone, named after when the first of them was heard.
  Future<String> _newOfflineSession(DateTime firstHeard) async {
    final id = const Uuid().v4();
    final t = firstHeard.toLocal().toIso8601String().substring(0, 16);
    await _db.insertSession(SessionsCompanion(
      id: drift.Value(id),
      name: drift.Value('Offline wardrive $t'),
      nodeId: const drift.Value('default'),
      startedAt: drift.Value(firstHeard.millisecondsSinceEpoch),
      isWardrive: const drift.Value(true),
    ));
    DebugLog.log('WDLOG: created session $id');
    return id;
  }

  void _onSpoolProgress(SpoolImportProgress p) {
    if (!p.done && !p.aborted && p.seen == 0) {
      _spoolExpectedTotal = p.total;
      _spoolInserted = 0;
      _spoolDone = false;
      _spoolConfirmed = false;
      _spoolSessionId = null;
      _spoolSessionIdFuture = null;
      DebugLog.log('SPOOL: batch header total=${p.total}');
      return;
    }
    if (p.aborted) {
      DebugLog.log('SPOOL: batch aborted seen=${p.seen} total=${p.total} — retaining spool, no confirm');
      _spoolDone = false;
      _spoolInserted = 0;
      _spoolExpectedTotal = -1;
      _spoolConfirmed = false;
      _spoolSessionId = null;
      _spoolSessionIdFuture = null;
      return;
    }
    if (p.done) {
      DebugLog.log('SPOOL: batch done seen=${p.seen} dropped=${p.dropped} inserted=$_spoolInserted expected=$_spoolExpectedTotal');
      _spoolDone = true;
      _maybeConfirmSpool();
    }
  }

  Future<void> _maybeConfirmSpool() async {
    if (_spoolDone && _spoolExpectedTotal >= 0 && _spoolInserted >= _spoolExpectedTotal && !_spoolConfirmed) {
      // Claimed before the first await so a later insert cannot start a second
      // confirm, and released in every outcome. A single failed write used to
      // be the end of it: the board kept the backlog and replayed it on the
      // next connect, which refilled a log the user had just cleared.
      _spoolConfirmed = true;
      DebugLog.log('SPOOL: confirming inserted=$_spoolInserted expected=$_spoolExpectedTotal');
      try {
        for (var attempt = 1; attempt <= 3; attempt++) {
          try {
            await _ble.confirmSpoolImported();
            DebugLog.log('SPOOL: board told to clear (attempt $attempt)');
            break;
          } catch (e) {
            DebugLog.log('SPOOL: clear write failed (attempt $attempt): $e');
            if (attempt < 3) await Future<void>.delayed(Duration(seconds: attempt));
          }
        }
      } finally {
        _spoolDone = false;
        _spoolInserted = 0;
        _spoolExpectedTotal = -1;
        _spoolConfirmed = false;
        _spoolSessionId = null;
        _spoolSessionIdFuture = null;
      }
    }
  }

  void _updateLiveActivity({bool allowStart = false}) {
    final engineNames = activeEngines.map((e) => e.name).toSet();
    if (foxhuntTarget != null) engineNames.add('foxhunter');
    if (engineNames.isEmpty) {
      if (_liveActivity.isActive) _liveActivity.end();
      return;
    }
    final mode = LiveActivityService.resolvePrimaryMode(
      engineNames,
      foxhuntTarget: foxhuntTarget,
    );
    _liveActivity.update(
      primaryMode: mode,
      allowStart: allowStart || state == WardriveState.running,
      activeLabel: _liveActivityLabel(engineNames),
      uniqueCount: uniqueMacs.length,
      wifiCount: _wifiNetworkMacs.length,
      bleCount: uniqueMacs.length - _wifiNetworkMacs.length,
      flockCount: _flockMacs.length,
      droneCount: droneCount,
      detectorHits: includesDetector ? detectorCount : 0,
      distanceKm: distanceKm,
      speedKmh: currentPosition?.speedKmh ?? 0,
      targetMac: foxhuntTarget ?? '',
      isImperial: isImperial,
    );
  }

  /// Human label listing every active radio path, e.g. "WiGLE+Flock+Drone".
  String _liveActivityLabel(Set<String> engineNames) {
    final parts = <String>[];
    if (engineNames.contains('wardrive')) parts.add('WiGLE');
    if (engineNames.contains('flockBle') || engineNames.contains('flockWifi')) {
      parts.add('Flock');
    }
    if (engineNames.contains('axon')) parts.add('Axon');
    if (engineNames.contains('skySpy')) parts.add('Drone');
    if (engineNames.contains('detector')) parts.add('Detect');
    if (engineNames.contains('foxhunter')) parts.add('Foxhunt');
    if (engineNames.contains('uniPwn')) parts.add('UniPwn');
    return parts.isEmpty ? 'Scanning' : parts.join('+');
  }

  SessionStats get currentStats {
    final duration = startTime != null
        ? DateTime.now().difference(startTime!)
        : Duration.zero;

    return SessionStats(
      duration: duration,
      distanceKm: distanceKm,
      speedKmh: currentPosition?.speedKmh ?? 0,
      totalDetections: rawDetectionCount,
      uniqueMacs: uniqueMacs.length,
      newMacs: uniqueMacs.length,
      wifiDetections: _dedupedByMac.values.where((d) => d.isWifiDetection).length,
      wifiTotal: rawWifiCount,
      bleDetections: _dedupedByMac.values.where((d) => d.isBleDetection).length,
      bleTotal: rawBleCount,
      flockCount: includesFlock ? _flockMacs.length : 0,
      droneCount: droneCount,
      detectorCount: includesDetector ? detectorCount : 0,
      detectionsPerKm: distanceKm > 0 && distanceKm.isFinite 
          ? rawDetectionCount / distanceKm 
          : 0,
      gpsAccuracy: currentPosition?.accuracy ?? 0,
      satelliteCount: currentPosition?.satelliteCount ?? 0,
    );
  }

  void _onDetection(Detection detection) {
    if (state != WardriveState.running) return;

    final isBle = detection.isBleDetection;
    if (_ignoreList.shouldSuppress(
      mac: detection.macAddress,
      ssid: detection.ssid.isNotEmpty ? detection.ssid : detection.deviceName,
      isBle: isBle,
    )) {
      return;
    }

    // Geofence exclusion: drop detections inside any wardrive-exclusion zone
    if (_geofenceFilter.isExcludedNullable(detection.latitude, detection.longitude)) {
      geofenceSuppressed++;
      if (geofenceSuppressed == 1 || geofenceSuppressed % 50 == 0) {
        DebugLog.log('WARDRIVE: $geofenceSuppressed detections dropped inside '
            'an exclusion zone');
        notifyListeners();
      }
      return;
    }

    rawDetectionCount++;
    if (isBle) { rawBleCount++; } else { rawWifiCount++; }

    // Track per-source-node WiFi/BLE counts
    final src = detection.sourceNodeId;
    if (src.isNotEmpty) {
      if (isBle) {
        nodeBleCount[src] = (nodeBleCount[src] ?? 0) + 1;
      } else {
        nodeWifiCounts[src] = (nodeWifiCounts[src] ?? 0) + 1;
      }
    }
    uniqueMacs.add(detection.macAddress);
    if (detection.engine == Engine.wardrive) {
      _wifiNetworkMacs.add(detection.macAddress);
    }
    _notificationService.onWardriveUpdate(uniqueCount: _wifiNetworkMacs.length);
    _updateLiveActivity();
    final isFlock = detection.engine == Engine.flockWifi;
    if (isFlock) {
      _flockMacs.add(detection.macAddress);
      _flockByMac[detection.macAddress] = detection;
      _cachedFlockDetections = null;
    }
    if (detection.engine == Engine.detector) {
      _detectorMacs.add(detection.macAddress);
      _detectorByMac[detection.macAddress] = detection;
      _cachedDetectorDetections = null;
    }

    final key = '${detection.macAddress}|${detection.engine.name}';
    final existing = _dedupedByMac[key];
    final threshold = detection.isBleDetection ? bleRssiRelogDb : wifiRssiRelogDb;

    if (existing != null) {
      final rssiDelta = (detection.rssi - existing.rssi).abs();
      final shouldRelog = rssiDelta >= threshold;
      WardriveExtension? mergedWardrive = detection.wardrive ?? existing.wardrive;
      if (detection.wardrive != null && existing.wardrive != null) {
        final newAuth = detection.wardrive!.authMode;
        final oldAuth = existing.wardrive!.authMode;
        mergedWardrive = detection.wardrive!.copyWith(
          authMode: newAuth > 0 ? newAuth : oldAuth,
          ssid: detection.wardrive!.ssid.isNotEmpty
              ? detection.wardrive!.ssid
              : existing.wardrive!.ssid,
          deviceName: detection.wardrive!.deviceName.isNotEmpty
              ? detection.wardrive!.deviceName
              : existing.wardrive!.deviceName,
        );
      }
      // Base the merged record on whichever sighting owns the plotted
      // position, so position and RSSI come from one sample. Taking the new
      // detection unconditionally, as this did, walked a device along the road
      // behind us as weaker and weaker sightings arrived.
      final base = sightingWinsPlot(detection.latitude, detection.longitude,
              detection.rssi, existing.latitude, existing.longitude, existing.rssi)
          ? detection
          : existing;
      final updated = base.copyWith(
        count: existing.count + 1,
        deviceName: detection.deviceName.isNotEmpty
            ? detection.deviceName
            : existing.deviceName,
        appTimestamp: detection.appTimestamp,
        wardrive: mergedWardrive,
      );
      _dedupedByMac[key] = updated;
      _dedupedOrdered.remove(existing);
      _dedupedOrdered.insert(0, updated);
      if (!shouldRelog) {
        notifyListeners();
        return;
      }
    } else {
      _dedupedByMac[key] = detection;
      _dedupedOrdered.insert(0, detection);
    }

    _db.insertDetection(DetectionsCompanion(
      sessionId: drift.Value(sessionId),
      nodeId: const drift.Value('default'),
      macAddress: drift.Value(detection.macAddress),
      deviceName: drift.Value(detection.deviceName),
      engine: drift.Value(detection.engine.name),
      detectionMethod: drift.Value(detection.method),
      rssi: drift.Value(detection.rssi),
      channel: drift.Value(detection.channel),
      deviceTimestampMs: drift.Value(detection.deviceTimestampMs),
      appTimestamp: drift.Value(detection.appTimestamp.millisecondsSinceEpoch),
      latitude: drift.Value(detection.latitude),
      longitude: drift.Value(detection.longitude),
      accuracy: drift.Value(detection.accuracy),
      altitude: drift.Value(detection.altitude),
      speed: drift.Value(detection.speed),
      heading: drift.Value(detection.heading),
      satelliteCount: drift.Value(detection.satelliteCount),
      ssid: drift.Value(detection.ssid),
      authMode: drift.Value(detection.wardrive?.authMode ?? 0),
      uavId: drift.Value(detection.odid?.uavId),
      operatorId: drift.Value(detection.odid?.operatorId),
      droneLat: drift.Value(detection.odid?.droneLat),
      droneLon: drift.Value(detection.odid?.droneLon),
      altitudeMsl: drift.Value(detection.odid?.altitudeMsl),
      heightAgl: drift.Value(detection.odid?.heightAgl),
      droneSpeed: drift.Value(detection.odid?.droneSpeed),
      droneHeading: drift.Value(detection.odid?.droneHeading),
      pilotLat: drift.Value(detection.odid?.pilotLat),
      pilotLon: drift.Value(detection.odid?.pilotLon),
      isRaven: drift.Value(detection.flock?.isRaven),
      ravenFirmware: drift.Value(detection.flock?.ravenFirmware),
      flockSignals: drift.Value(detection.flock?.signals),
    )).catchError((e) => DebugLog.log('WARDRIVE: insertDetection failed: $e'));

    notifyListeners();
  }

  void _applyExclusionGate(GpsPosition pos) {
    final excluded = _geofenceFilter.isExcludedNullable(pos.latitude, pos.longitude);
    if (excluded == _inExclusion) return;
    _inExclusion = excluded;
    if (excluded) {
      DebugLog.log('WARDRIVE: entered exclusion zone — pausing radios');
      // Disable the whole fleet rather than the set the app believes is
      // running. activeEngines is the app's picture of the board, and a zone
      // is exactly the place not to trust a picture that can be stale: an
      // engine missing from it would keep transmitting.
      for (final e in _fleetEngines) {
        _ble.disableEngine(e);
      }
      _autoPcapPausedByExclusion = _ble.latestPcapStats.autoEnabled;
      if (_autoPcapPausedByExclusion) _ble.setAutoPcap(false);
    } else {
      DebugLog.log('WARDRIVE: exited exclusion zone — restoring radios');
      _enableEnginesSequentially(_fleetEngines);
      if (_autoPcapPausedByExclusion) {
        _ble.setAutoPcap(true);
        _autoPcapPausedByExclusion = false;
      }
    }
    notifyListeners();
  }

  void _onGpsUpdate(GpsPosition pos) {
    // Validate GPS position before using
    if (!pos.latitude.isFinite || !pos.longitude.isFinite) {
      DebugLog.log('WARDRIVE: invalid GPS position, skipping');
      return;
    }

    currentPosition = pos;
    final ll = LatLng(pos.latitude, pos.longitude);

    if (state == WardriveState.running) {
      _applyExclusionGate(pos);
    }

    if (state == WardriveState.running) {
      // Guard against GPS jumps (stale restore, satellite reacquisition)
      if (routePoints.isNotEmpty) {
        final last = routePoints.last;
        final jumpKm = _haversineKm(
          last.latitude, last.longitude, pos.latitude, pos.longitude,
        );
        if (jumpKm.isFinite && jumpKm > 0.5) {
          // >500m jump — likely stale position or GPS glitch, skip route point
          DebugLog.log('WARDRIVE: GPS jump ${(jumpKm * 1000).round()}m, skipping route point');
          notifyListeners();
          return;
        }
      }

      routePoints.add(ll);
      if (lastGpsForDistance != null) {
        final km = _haversineKm(
          lastGpsForDistance!.latitude, lastGpsForDistance!.longitude,
          pos.latitude, pos.longitude,
        );
        if (km.isFinite) {
          distanceKm += km;
        }
      }
      lastGpsForDistance = pos;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _detSub?.cancel();
    _gpsSub?.cancel();
    _statsTimer?.cancel();
    _ambientDetSub?.cancel();
    _importedDetSub?.cancel();
    _awayLiveSub?.cancel();
    _spoolImportSub?.cancel();
    _wdLogSub?.cancel();
    _resumeTimer?.cancel();
    super.dispose();
  }

  static bool _isPlausibleCoord(double? lat, double? lon) {
    if (lat == null || lon == null) return false;
    if (!lat.isFinite || !lon.isFinite) return false;
    if (lat == 0.0 && lon == 0.0) return false;
    if (lat.abs() > 89.5) return false;
    return true;
  }

  static double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    final sqrtVal = math.sqrt(a.clamp(0.0, 1.0));
    return r * 2 * math.asin(sqrtVal);
  }
}

final wardriveProvider = ChangeNotifierProvider<WardriveController>((ref) {
  ref.keepAlive();
  // This is a keepAlive singleton that owns the live wardrive session, so it
  // must be built exactly once. Every dependency is therefore ref.read, never
  // ref.watch: ignoreListProvider and notificationServiceProvider are
  // ChangeNotifierProviders that notifyListeners() frequently (the latter on
  // every alert), and watching them would tear down and rebuild this
  // controller mid-session — resetting `state` to idle, flipping the wardrive
  // tile off, and orphaning the session while a fresh ambient one is spun up.
  // That rebuild storm (driven by the classifier's tracker alerts) was the
  // cause of the tile-flicker / feed-emptying / leaked-session behaviour.
  final ble = ref.read(bleManagerProvider);
  final gps = ref.read(gpsProvider);
  final db = ref.read(databaseProvider);
  final allowlist = ref.read(ignoreListProvider);
  final geofence = ref.read(geofenceFilterProvider);
  final notif = ref.read(notificationServiceProvider);
  final liveActivity = ref.read(liveActivityServiceProvider);
  final controller = WardriveController(ble, gps, db, allowlist, geofence, notif, liveActivity);
  // Let the notification service know when a wardrive is running so it can mute
  // the phone-side classifier's alerts (wardrive is a recording mode, not an
  // alerting one — see NotificationService.wardriveActiveGetter).
  notif.wardriveActiveGetter = () => controller.isActive;
  controller.setWatchlistGetter(() => ref.read(watchlistProvider).enabledEntries);
  controller.isImperial = ref.read(unitSystemProvider) == UnitSystem.imperial;
  ref.listen<UnitSystem>(unitSystemProvider, (_, next) {
    controller.isImperial = next == UnitSystem.imperial;
  });
  return controller;
});
