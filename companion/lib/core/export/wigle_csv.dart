// SPDX-License-Identifier: MIT
import 'package:intl/intl.dart';
import 'package:oui_spy/core/app_version.dart';
import 'package:oui_spy/core/geofence/geofence_filter.dart';
import 'package:oui_spy/core/ignore_list_state.dart';
import 'package:oui_spy/core/models/detection.dart';
import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/core/radio_classifier.dart';

/// WiGLE CSV v1.6 (https://api.wigle.net/csvFormat.html).
///
/// Only wardrive observations are written. A session also holds tracker,
/// deauth, camera and drone detections; written as rows they would reach
/// WiGLE as networks, some carrying the MAC of a person's phone.
class WigleCsv {
  const WigleCsv._();

  static final _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  /// RFC 4180 records end in CRLF.
  static const _eol = '\r\n';

  static bool isWardriveObservation(Detection d) =>
      d.engine == Engine.wardrive && (d.method == 'wifi_ap' || d.method == 'ble_adv');

  static String generate(
    List<Detection> detections, {
    IgnoreListState? ignoreList,
    GeofenceFilter? geofenceFilter,
    String board = '',
    String firmwareVersion = '',
  }) {
    final buffer = StringBuffer();

    final b = board.toLowerCase();
    final device = b.contains('c5') ? 'ESP32-C5'
                 : b.contains('c3') ? 'ESP32-C3'
                 : 'ESP32-S3';
    final (boardName, brand) = b.contains('devkit') ? ('DevKitC', 'Espressif')
        : b.contains('dongle') ? ('T-Dongle-S3', 'LILYGO')
        : ('XIAO', 'Seeed Studio');

    // Pre-header: release is the device's own software, the firmware here.
    buffer.write(
      'WigleWifi-1.6,'
      'appRelease=$kAppVersion,'
      'model=OUI-SNITCH,'
      'release=${firmwareVersion.isEmpty ? 'unknown' : firmwareVersion},'
      'device=$device,'
      'display=none,'
      'board=$boardName,'
      'brand=$brand,'
      'star=Sol,'
      'body=3,'
      'subBody=0$_eol',
    );

    buffer.write(
      'MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,'
      'CurrentLatitude,CurrentLongitude,AltitudeMeters,'
      'AccuracyMeters,RCOIs,MfgrId,Type$_eol',
    );

    for (final d in detections) {
      if (!isWardriveObservation(d)) continue;
      if (d.latitude == null || d.longitude == null) continue;

      final isBle = d.isBleDetection;
      if (ignoreList != null &&
          ignoreList.shouldSuppress(
            mac: d.macAddress,
            ssid: d.ssid.isNotEmpty ? d.ssid : d.deviceName,
            isBle: isBle,
          )) {
        continue;
      }
      if (geofenceFilter != null &&
          geofenceFilter.isExcludedNullable(d.latitude, d.longitude)) {
        continue;
      }

      final name = _escapeCsv(isBle ? d.deviceName : d.ssid);
      final auth = isBle ? '[LE]' : authTag(d.wardrive?.authMode);
      final firstSeen = _dateFormat.format(d.appTimestamp.toUtc());
      // Bluetooth: channel 0 and no frequency, as in the spec's own example.
      final channel = isBle ? 0 : d.channel;
      final frequency = isBle ? '' : _frequency(d.channel);
      final alt = (d.altitude ?? 0).round();
      // Accuracy is an estimate in metres; 0 would claim a perfect fix.
      final acc = d.accuracy;
      final accText = acc != null && acc > 0 ? '$acc' : '';
      final type = isBle ? 'BLE' : 'WIFI';

      buffer.write(
        '${d.macAddress},$name,$auth,$firstSeen,$channel,'
        '$frequency,${d.rssi},${d.latitude},${d.longitude},$alt,$accText,,,$type$_eol',
      );
    }

    return buffer.toString();
  }

  /// AuthMode as Android's ScanResult.capabilities writes it, which the spec
  /// names as the format (AOSP InformationElementUtil
  /// .generateCapabilitiesString). The board does not send the pairwise
  /// cipher, so the cipher segment is left out, as Android does when it has
  /// none. A code we cannot name is left blank: "[ESS]" alone would claim an
  /// open network.
  static String authTag(int? auth) => switch (auth) {
        0 => '[ESS]',
        1 => '[WEP][ESS]',
        2 => '[WPA-PSK][ESS]',
        3 => '[WPA2-PSK][RSN-PSK][ESS]',
        4 => '[WPA-PSK][WPA2-PSK][RSN-PSK][ESS]',
        5 => '[WPA2-EAP/SHA1][RSN-EAP/SHA1][ESS]',
        6 => '[RSN-SAE][ESS]',
        7 => '[WPA2-PSK][RSN-PSK+SAE][ESS]',
        8 => '[RSN-OWE][ESS]',
        9 => '[RSN-EAP_SUITE_B_192][ESS]',
        _ => '',
      };

  static String _frequency(int ch) {
    if (ch >= 1 && ch <= 13) return '${2407 + ch * 5}';
    if (ch == 14) return '2484';
    if (ch >= 36 && ch <= 177) return '${5000 + ch * 5}';
    return '';
  }

  static String _escapeCsv(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
