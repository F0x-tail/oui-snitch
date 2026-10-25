// SPDX-License-Identifier: MIT
import 'package:oui_spy/core/classify/device_explain.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/signature_engine.dart';

final alertableClasses = [
  for (final c in SignatureClass.values)
    if (c != SignatureClass.bodyworn) c,
];

const defaultAlertClasses = {
  SignatureClass.finder,
  SignatureClass.surveillance,
  SignatureClass.camera,
  SignatureClass.drone,
  SignatureClass.lawEnforcement,
  SignatureClass.glasses,
};

const _guessBuckets = {
  'camera': SignatureClass.camera,
  'drone': SignatureClass.drone,
  'glasses': SignatureClass.glasses,
  'tag': SignatureClass.finder,
  'radio': SignatureClass.lawEnforcement,
  'law-enforcement': SignatureClass.lawEnforcement,
  'bodyworn': SignatureClass.lawEnforcement,
};

SignatureClass? alertClassOf(ClassifiedDevice d, Set<SignatureClass> enabled) {
  for (final s in d.signatures) {
    if (enabled.contains(s.kind.folded)) return s.kind.folded;
  }
  if (d.signatures.isNotEmpty) return null;
  final g = d.guess;
  if (g.confidence == Confidence.low) return null;
  final c = _guessBuckets[g.bucket];
  return c != null && enabled.contains(c) ? c : null;
}
