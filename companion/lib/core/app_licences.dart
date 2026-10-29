// SPDX-License-Identifier: MIT
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds this project's own licence and the bundled fonts' to the licence page.
/// Flutter lists the packages the app depends on by itself; these are files
/// in this repository it cannot see. The MIT licence of the project this one
/// builds on requires its notice to ship with the app, and `LICENSE` carries
/// it.
void registerAppLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['OUI-SNITCH'],
      await rootBundle.loadString('assets/licenses/LICENSE'),
    );
    yield LicenseEntryWithLineBreaks(
      ['Atkinson Hyperlegible'],
      await rootBundle.loadString('assets/fonts/OFL-AtkinsonHyperlegible.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      ['Atkinson Hyperlegible Mono'],
      await rootBundle.loadString('assets/fonts/OFL-AtkinsonHyperlegibleMono.txt'),
    );
  });
}
