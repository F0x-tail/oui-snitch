import 'dart:math' as math;

import 'observation.dart';
import 'signature_engine.dart';

double geoMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dp = rad(lat2 - lat1);
  final dl = rad(lon2 - lon1);
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double geoPathLengthM(List<GpsSample> s) {
  var sum = 0.0;
  for (var i = 1; i < s.length; i++) {
    sum += geoMeters(s[i - 1].lat, s[i - 1].lon, s[i].lat, s[i].lon);
  }
  return sum;
}

double _bboxSpanM(List<GpsSample> s) {
  var minLat = s[0].lat, maxLat = s[0].lat, minLon = s[0].lon, maxLon = s[0].lon;
  for (final p in s) {
    minLat = math.min(minLat, p.lat);
    maxLat = math.max(maxLat, p.lat);
    minLon = math.min(minLon, p.lon);
    maxLon = math.max(maxLon, p.lon);
  }
  return geoMeters(minLat, minLon, maxLat, maxLon);
}

class CoTravelCtx {
  final double pathLengthM;
  final int durationMs;
  final GpsSample? here;
  final bool ready;
  const CoTravelCtx(this.pathLengthM, this.durationMs, this.here, this.ready);

  static const none = CoTravelCtx(0, 0, null, false);

  static CoTravelCtx of(List<GpsSample> path) {
    if (path.length < 2) return none;
    final len = geoPathLengthM(path);
    final dur = math.max(0, path.last.atMs - path.first.atMs);
    return CoTravelCtx(len, dur, path.last, len >= CoTravel.moveM);
  }
}

class CoTravel {
  static const moveM = 45.0;
  static const nearM = 50.0;
  static const heardMs = 90000;
  static const trailLoudDbm = -75;

  static bool withYou(Observation device, CoTravelCtx ctx, int now) {
    final here = ctx.here;
    if (device.kind == RadioKind.wifi || !ctx.ready || here == null) return false;
    if (now - device.lastSeenMs > heardMs) return false;
    if (device.rssi < trailLoudDbm) return false;
    final trail = device.gpsTrail;
    if (trail.length < 2) return false;
    if (_bboxSpanM(trail) < moveM * 0.6) return false;
    final loud = trail.where((s) => s.rssi >= trailLoudDbm).length;
    if (loud < (trail.length * 2 + 2) ~/ 3) return false;
    if (geoPathLengthM(trail) < moveM * 0.6) return false;
    final last = trail.last;
    final moved = geoMeters(here.lat, here.lon, last.lat, last.lon);
    final speed = (ctx.pathLengthM / math.max(1.0, ctx.durationMs / 1000.0)).clamp(0.0, 40.0);
    return moved <= math.max(nearM, speed * 15.0) + 25.0;
  }
}

enum TrackerKind { finder, beacon, wearable }

class TrackerMatch {
  static const _finder = [
    'airtag',
    'smarttag',
    'tile',
    'chipolo',
    'pebblebee',
    'moto tag',
    'find my',
    'find hub',
    'dult',
  ];
  static const _beacon = ['ibeacon', 'minew', 'estimote', 'kontakt'];
  static const _wearable = ['garmin', 'fitbit', 'oura'];

  static bool _hits(List<String> names, List<String> tokens) => names.any((n) => tokens.any(n.toLowerCase().contains));

  static bool _carriedApple(Observation d, List<String> names) {
    if (d.kind != RadioKind.ble) return false;
    if (d.rssiMax < -55 || d.rssiMin < -70) return false;
    if (_hits(names, _beacon)) return false;
    if (d.mfgRecords.any((r) => r.companyId == 0x004C)) return true;
    return names.any((n) => n.toLowerCase().contains('apple'));
  }

  static TrackerKind? kind(Observation d, List<String> signatureNames) {
    if (_hits(signatureNames, _finder) || isFindMyPayload(d)) return TrackerKind.finder;
    if (_hits(signatureNames, _beacon)) return TrackerKind.beacon;
    if (_hits(signatureNames, _wearable)) return TrackerKind.wearable;
    if (_carriedApple(d, signatureNames)) return TrackerKind.finder;
    return null;
  }
}
