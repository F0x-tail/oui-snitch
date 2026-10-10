import 'package:oui_spy/core/classify/device_explain.dart';
import 'package:oui_spy/core/classify/device_registry.dart';
import 'package:oui_spy/core/classify/signature_engine.dart';

enum ClassAlert {
  cameras('Surveillance cameras', {SignatureClass.surveillance, SignatureClass.camera}, {'camera'}),
  lawEnforcement('Law enforcement / body cams', {SignatureClass.lawEnforcement}, {'radio', 'law-enforcement', 'bodyworn'}),
  drones('Drones', {SignatureClass.drone}, {'drone'}),
  glasses('Smart glasses', {SignatureClass.glasses}, {'glasses'}),
  trackers('Tracker tags', {SignatureClass.finder}, {'tag'});

  const ClassAlert(this.label, this.kinds, this.buckets);
  final String label;
  final Set<SignatureClass> kinds;
  final Set<String> buckets;

  static ClassAlert? of(ClassifiedDevice d) {
    for (final s in d.signatures) {
      for (final a in values) {
        if (a.kinds.contains(s.kind)) return a;
      }
    }
    final g = d.guess;
    if (g.confidence == Confidence.low) return null;
    for (final a in values) {
      if (a.buckets.contains(g.bucket)) return a;
    }
    return null;
  }
}
