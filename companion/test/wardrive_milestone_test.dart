// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/notifications/notification_service.dart';

void main() {
  group('wardriveMilestoneFor', () {
    test('stays quiet below the first milestone', () {
      expect(wardriveMilestoneFor(0), 0);
      expect(wardriveMilestoneFor(999), 0);
    });

    test('reports the highest milestone passed, not the nearest', () {
      expect(wardriveMilestoneFor(1000), 1000);
      expect(wardriveMilestoneFor(4999), 1000);
      expect(wardriveMilestoneFor(5000), 5000);
      expect(wardriveMilestoneFor(24999), 10000);
      expect(wardriveMilestoneFor(50000), 50000);
    });

    test('a dense real session raises two alerts, not seven', () {
      // The 81-minute session in the exported data: 7,167 unique networks.
      // Under the old flat every-1000 rule that was seven notifications.
      final fired = <int>{};
      var last = 0;
      for (var n = 1; n <= 7167; n++) {
        final m = wardriveMilestoneFor(n);
        if (m > last) {
          last = m;
          fired.add(m);
        }
      }
      expect(fired, {1000, 5000});
    });

    test('never goes backwards as the count climbs', () {
      var prev = 0;
      for (var n = 0; n <= 120000; n += 37) {
        final m = wardriveMilestoneFor(n);
        expect(m, greaterThanOrEqualTo(prev));
        prev = m;
      }
    });

    test('past the ladder it settles into a fixed step', () {
      expect(wardriveMilestoneFor(100000), 100000);
      expect(wardriveMilestoneFor(199999), 100000);
      expect(wardriveMilestoneFor(200000), 200000);
    });
  });
}
