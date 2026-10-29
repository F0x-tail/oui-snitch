// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/wigle/wigle_api.dart';

// Shaped like TransLog in api.wigle.net/swagger.json.
final _row = {
  'transid': '20261028-00123',
  'fileName': 'ouispy_wardrive_20261028_094810.csv',
  'fileSize': 51234,
  'status': 'D',
  'discoveredGps': 12,
  'totalGps': 340,
  'btDiscoveredGps': 3,
  'btTotalGps': 80,
};

void main() {
  test('an upload record reads the counts WiGLE reports', () {
    final t = WigleTransaction.fromJson(_row);
    expect(t.transactionId, '20261028-00123');
    expect(t.newNetworks, 15);
    expect(t.totalNetworks, 420);
  });

  test('a session is found by its CSV name, with or without a prefix', () {
    final uploads = [
      WigleTransaction.fromJson(_row),
      WigleTransaction.fromJson({..._row, 'transid': 'x', 'fileName': 'uploads/ouispy_wardrive_20261027_184800.csv'}),
    ];
    expect(findUpload(uploads, 'ouispy_wardrive_20261028_094810.csv')?.transactionId, '20261028-00123');
    expect(findUpload(uploads, 'ouispy_wardrive_20261027_184800.csv')?.transactionId, 'x');
    expect(findUpload(uploads, 'ouispy_wardrive_20261026_214400.csv'), isNull);
  });

  test('missing fields do not break the list', () {
    final t = WigleTransaction.fromJson({'transid': 'y'});
    expect(t.fileName, '');
    expect(t.totalNetworks, 0);
  });
}
