import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ble/ble_protocol.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';

List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

void main() {
  test('S3 capture (v3_app_controlled_ie_e2e): watchlist hit notification titled by description', () {
    final det = BleProtocol.decodeDetection(
      _hex('0040486e8bd31aa9064a1a0000010000000000004e6f6b696120726f757465720000000000000000000000000000000000000000'),
      sessionId: 's',
      nodeId: 'n',
      appTimestamp: DateTime(2026),
    );
    final (title, body, channel) = NotificationService.detectionNotificationText(det);
    expect(title, 'Nokia router');
    expect(body, contains('40:48:6E:8B:D3:1A'));
    expect(body, contains('Signal -87 dBm'));
    expect(body, contains('Matched by Watchlist'));
    expect(channel, NotifChannel.detector);
  });

  test('S3 capture: probe-SSID detector record titled by its description', () {
    final det = BleProtocol.decodeDetection(
      _hex('005cfce1006a24a706212100000500000000000056696c6c6173656e6f7200000000000000000000000000000000000000000000'),
      sessionId: 's',
      nodeId: 'n',
      appTimestamp: DateTime(2026),
    );
    expect(NotificationService.detectionNotificationText(det).$1, 'Probe request for "Villasenor"');
    expect(NotificationService.detectionNotificationText(det).$2, contains('Probe request'));
  });
}
