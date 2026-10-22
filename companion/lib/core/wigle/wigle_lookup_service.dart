import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WiGLE BSSID lookup, used to corroborate a suspected evil twin.
///
/// Always user-triggered. WiGLE's free tier is small (new accounts have been
/// reported as low as a handful of queries a day), the ceiling is behavioural
/// rather than published, and `search` and `detail` have separate buckets that
/// reset at 00:00 US/Pacific. So this queries the `detail` endpoint by BSSID —
/// one exact result, no pagination — and caches every answer, including the
/// misses, since "not in WiGLE" is itself a useful verdict.
///
/// Credentials are the user's own. Nothing is shipped with the app.
final wigleLookupProvider = ChangeNotifierProvider<WigleLookupService>((ref) {
  return WigleLookupService();
});

enum WigleVerdict {
  /// Known to WiGLE at roughly where we are seeing it.
  knownHere,

  /// Known to WiGLE, but recorded far from here — it moved.
  knownElsewhere,

  /// Not in WiGLE at all.
  unknown,

  /// Known, but we have no position to compare against.
  knownNoLocalFix,
}

class WigleResult {
  const WigleResult({
    required this.bssid,
    required this.verdict,
    this.ssid,
    this.latitude,
    this.longitude,
    this.distanceKm,
    this.firstSeen,
    this.lastSeen,
    this.country,
  });

  final String bssid;
  final WigleVerdict verdict;
  final String? ssid;
  final double? latitude;
  final double? longitude;
  final double? distanceKm;
  final String? firstSeen;
  final String? lastSeen;
  final String? country;

  bool get hasPosition => latitude != null && longitude != null;

  String get headline => switch (verdict) {
        WigleVerdict.knownHere => 'Known here',
        WigleVerdict.knownElsewhere =>
          'Known ${distanceKm!.toStringAsFixed(0)} km away',
        WigleVerdict.unknown => 'Not in WiGLE',
        WigleVerdict.knownNoLocalFix => 'Known to WiGLE',
      };

  /// What this says about an evil-twin suspicion.
  String get interpretation => switch (verdict) {
        WigleVerdict.knownHere =>
          'This BSSID is recorded at this location, which is what a legitimate '
              'access point looks like.',
        WigleVerdict.knownElsewhere =>
          'This BSSID is recorded far from here, so the hardware has moved. '
              'Expected for a mobile hotspot; suspicious for a fixed network.',
        WigleVerdict.unknown =>
          'No record of this BSSID. A new or never-surveyed access point '
              'broadcasting an established network name is consistent with an '
              'evil twin — though it equally fits newly installed kit.',
        WigleVerdict.knownNoLocalFix =>
          'Recorded in WiGLE, but there is no GPS fix here to compare against.',
      };

  Map<String, dynamic> toJson() => {
        'bssid': bssid,
        'verdict': verdict.name,
        'ssid': ssid,
        'lat': latitude,
        'lon': longitude,
        'first': firstSeen,
        'last': lastSeen,
        'country': country,
      };

  static WigleResult fromJson(Map<String, dynamic> j, {double? distanceKm}) =>
      WigleResult(
        bssid: j['bssid'] as String,
        verdict: WigleVerdict.values.firstWhere(
          (v) => v.name == j['verdict'],
          orElse: () => WigleVerdict.unknown,
        ),
        ssid: j['ssid'] as String?,
        latitude: (j['lat'] as num?)?.toDouble(),
        longitude: (j['lon'] as num?)?.toDouble(),
        distanceKm: distanceKm,
        firstSeen: j['first'] as String?,
        lastSeen: j['last'] as String?,
        country: j['country'] as String?,
      );
}

class WigleLookupService extends ChangeNotifier {
  WigleLookupService() {
    _load();
  }

  /// Shared with WigleProvider, which owns the login. Lookups reuse whatever
  /// account the user already signed in with for uploads — one set of
  /// credentials, one place to enter them.
  static const _storage = FlutterSecureStorage();
  static const _kApiName = 'wigle_api_name';
  static const _kApiToken = 'wigle_api_token';
  static const _kCache = 'wigle_cache_v1';
  static const _kUsedToday = 'wigle_used_today';
  static const _kUsedDate = 'wigle_used_date';
  static const _kObservedCeiling = 'wigle_observed_ceiling';
  static const _kExhaustedUntil = 'wigle_exhausted_until';

  /// Beyond this, an access point has plainly moved rather than drifted.
  static const _samePlaceKm = 2.0;

  /// Keep answers for a quarter; an access point's location rarely changes.
  static const _cacheTtl = Duration(days: 90);

  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'https://api.wigle.net',
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 500,
  ));

  String _apiName = '';
  String _apiToken = '';
  int _usedToday = 0;
  String _usedDate = '';
  int? _observedCeiling;
  DateTime? _exhaustedUntil;
  final Map<String, _CacheEntry> _cache = {};
  final Map<String, Future<WigleResult?>> _inFlight = {};

  bool get hasCredentials => _apiName.isNotEmpty && _apiToken.isNotEmpty;
  int get usedToday => _usedToday;
  int? get observedCeiling => _observedCeiling;
  int get cachedCount => _cache.length;

  /// True once WiGLE has refused a query today; cleared at the next reset.
  bool get exhausted =>
      _exhaustedUntil != null && DateTime.now().isBefore(_exhaustedUntil!);

  String get budgetLabel {
    if (exhausted) return 'Daily limit reached — resets 00:00 US/Pacific';
    if (_observedCeiling != null) return '$_usedToday of ~$_observedCeiling used today';
    return '$_usedToday used today';
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    await _readCredentials();
    _usedToday = p.getInt(_kUsedToday) ?? 0;
    _usedDate = p.getString(_kUsedDate) ?? '';
    _observedCeiling = p.getInt(_kObservedCeiling);
    final ex = p.getInt(_kExhaustedUntil);
    _exhaustedUntil = ex == null ? null : DateTime.fromMillisecondsSinceEpoch(ex);

    final raw = p.getString(_kCache);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          final entry = _CacheEntry.fromJson(e.value as Map<String, dynamic>);
          if (DateTime.now().difference(entry.at) < _cacheTtl) {
            _cache[e.key] = entry;
          }
        }
      } catch (_) {
        // A malformed cache is not worth failing over; start clean.
      }
    }

    _rolloverIfNeeded();
    notifyListeners();
  }

  Future<void> _readCredentials() async {
    try {
      _apiName = await _storage.read(key: _kApiName) ?? '';
      _apiToken = await _storage.read(key: _kApiToken) ?? '';
    } catch (_) {
      // Secure storage can be unavailable on a locked device; treat it as
      // "not signed in" rather than failing the screen.
      _apiName = '';
      _apiToken = '';
    }
  }

  /// Re-read credentials after the user signs in through the WiGLE settings.
  Future<void> refreshCredentials() async {
    await _readCredentials();
    notifyListeners();
  }

  Future<void> clearCache() async {
    _cache.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kCache);
    notifyListeners();
  }

  /// WiGLE resets at midnight US/Pacific, which is UTC-8 (or -7 in DST). Using
  /// the standard offset means we may wait an hour longer than strictly needed
  /// during DST — the safe direction, since retrying into a 429 is the
  /// behaviour that gets accounts suspended.
  DateTime _nextPacificMidnight() {
    final nowPacific = DateTime.now().toUtc().subtract(const Duration(hours: 8));
    final nextMidnight =
        DateTime.utc(nowPacific.year, nowPacific.month, nowPacific.day)
            .add(const Duration(days: 1));
    return nextMidnight.add(const Duration(hours: 8));
  }

  String _pacificDateKey() {
    final p = DateTime.now().toUtc().subtract(const Duration(hours: 8));
    return '${p.year}-${p.month}-${p.day}';
  }

  void _rolloverIfNeeded() {
    final today = _pacificDateKey();
    if (_usedDate != today) {
      _usedDate = today;
      _usedToday = 0;
      _exhaustedUntil = null;
    }
  }

  Future<void> _persistBudget() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kUsedToday, _usedToday);
    await p.setString(_kUsedDate, _usedDate);
    if (_observedCeiling != null) {
      await p.setInt(_kObservedCeiling, _observedCeiling!);
    }
    if (_exhaustedUntil != null) {
      await p.setInt(_kExhaustedUntil, _exhaustedUntil!.millisecondsSinceEpoch);
    } else {
      await p.remove(_kExhaustedUntil);
    }
  }

  Future<void> _persistCache() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kCache,
      jsonEncode(_cache.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  /// A cached answer for this BSSID, if one is still fresh.
  WigleResult? cached(String bssid, {double? lat, double? lon}) {
    final key = bssid.toUpperCase();
    final e = _cache[key];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) >= _cacheTtl) return null;
    return _withDistance(e.result, lat, lon);
  }

  /// Look up one BSSID. Returns null when it could not be asked — no
  /// credentials, or the daily budget is spent.
  ///
  /// [lat]/[lon] are the observer's position; without them a known network
  /// cannot be judged near or far.
  Future<WigleResult?> lookup(String bssid, {double? lat, double? lon}) async {
    final key = bssid.toUpperCase();

    final hit = cached(key, lat: lat, lon: lon);
    if (hit != null) return hit;

    if (!hasCredentials) return null;
    _rolloverIfNeeded();
    if (exhausted) return null;

    // Two taps on the same row should cost one query, not two.
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _fetch(key, lat, lon);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<WigleResult?> _fetch(String bssid, double? lat, double? lon) async {
    final auth = base64Encode(utf8.encode('$_apiName:$_apiToken'));
    try {
      final resp = await _dio.get(
        '/api/v2/network/detail',
        queryParameters: {'netid': bssid},
        options: Options(headers: {'Authorization': 'Basic $auth'}),
      );

      if (resp.statusCode == 429) {
        // Budget spent. Record where the ceiling fell so the UI can show it,
        // and refuse further calls until the reset.
        _observedCeiling = _usedToday;
        _exhaustedUntil = _nextPacificMidnight();
        await _persistBudget();
        notifyListeners();
        return null;
      }

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        _lastError = 'WiGLE rejected the credentials.';
        notifyListeners();
        return null;
      }

      // The query counted against the budget whatever it returned.
      _usedToday++;
      await _persistBudget();

      final data = resp.data;
      final results = (data is Map && data['results'] is List)
          ? data['results'] as List
          : const [];

      late WigleResult result;
      if (results.isEmpty) {
        result = WigleResult(bssid: bssid, verdict: WigleVerdict.unknown);
      } else {
        final r = results.first as Map<String, dynamic>;
        final netLat = (r['trilat'] as num?)?.toDouble();
        final netLon = (r['trilong'] as num?)?.toDouble();
        result = WigleResult(
          bssid: bssid,
          verdict: WigleVerdict.knownNoLocalFix,
          ssid: r['ssid'] as String?,
          latitude: netLat,
          longitude: netLon,
          firstSeen: r['firsttime'] as String?,
          lastSeen: r['lasttime'] as String?,
          country: r['country'] as String?,
        );
      }

      _cache[bssid] = _CacheEntry(result: result, at: DateTime.now());
      await _persistCache();
      _lastError = null;
      notifyListeners();
      return _withDistance(result, lat, lon);
    } on DioException catch (e) {
      _lastError = 'Lookup failed: ${e.type.name}';
      notifyListeners();
      return null;
    }
  }

  String? _lastError;
  String? get lastError => _lastError;

  /// Resolve near-vs-far at read time, so a cached answer stays usable from a
  /// different place than where it was first fetched.
  static WigleResult? _withDistance(WigleResult r, double? lat, double? lon) {
    if (r.verdict == WigleVerdict.unknown) return r;
    if (lat == null || lon == null || !r.hasPosition) {
      return WigleResult(
        bssid: r.bssid,
        verdict: WigleVerdict.knownNoLocalFix,
        ssid: r.ssid,
        latitude: r.latitude,
        longitude: r.longitude,
        firstSeen: r.firstSeen,
        lastSeen: r.lastSeen,
        country: r.country,
      );
    }
    final km = _haversineKm(lat, lon, r.latitude!, r.longitude!);
    return WigleResult(
      bssid: r.bssid,
      verdict: km <= _samePlaceKm
          ? WigleVerdict.knownHere
          : WigleVerdict.knownElsewhere,
      ssid: r.ssid,
      latitude: r.latitude,
      longitude: r.longitude,
      distanceKm: km,
      firstSeen: r.firstSeen,
      lastSeen: r.lastSeen,
      country: r.country,
    );
  }

  static double _haversineKm(double la1, double lo1, double la2, double lo2) {
    const earthRadiusKm = 6371.0;
    double rad(double d) => d * math.pi / 180.0;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = (1 - math.cos(dLat)) / 2 +
        math.cos(rad(la1)) * math.cos(rad(la2)) * (1 - math.cos(dLon)) / 2;
    return 2 * earthRadiusKm * math.asin(math.sqrt(a));
  }
}

class _CacheEntry {
  const _CacheEntry({required this.result, required this.at});

  final WigleResult result;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'r': result.toJson(),
        'at': at.millisecondsSinceEpoch,
      };

  static _CacheEntry fromJson(Map<String, dynamic> j) => _CacheEntry(
        result: WigleResult.fromJson(j['r'] as Map<String, dynamic>),
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
      );
}
