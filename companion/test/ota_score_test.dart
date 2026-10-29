// SPDX-License-Identifier: MIT
import 'package:flutter_test/flutter_test.dart';
import 'package:oui_spy/core/ota/ota_service.dart';

void main() {
  // Names as release.yml publishes them.
  test('the firmware image for this board and role is picked', () {
    expect(OtaService.scoreAsset('oui-snitch-node-xiao_s3-v0.7.0.bin', 'xiao_s3', 'node'), greaterThan(0));
  });

  test('flash helpers and other boards are never picked', () {
    for (final n in [
      'oui-snitch-node-xiao_s3-v0.7.0-bootloader.bin',
      'oui-snitch-node-xiao_s3-v0.7.0-partitions.bin',
      'oui-snitch-node-xiao_s3-v0.7.0-boot_app0.bin',
      'oui-snitch-node-s3_devkitc-v0.7.0.bin',
      'oui-snitch-v0.7.0-arm64.apk',
    ]) {
      expect(OtaService.scoreAsset(n, 'xiao_s3', 'node'), -1, reason: n);
    }
  });

  test('another project\'s images are not ours', () {
    // Regression: the matcher still required "oui-spy", so no release of
    // this project could ever be found.
    expect(OtaService.scoreAsset('oui-spy-node-xiao_s3-v0.7.0.bin', 'xiao_s3', 'node'), -1);
  });

  test('the check points at this repository', () {
    expect(OtaService.githubOwner, 'F0x-tail');
    expect(OtaService.githubRepo, 'oui-snitch');
    expect(OtaService.remoteOtaEnabled, isFalse, reason: 'unsigned images must not install');
  });
}
