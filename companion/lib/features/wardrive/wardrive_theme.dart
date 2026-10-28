// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';

import 'package:oui_spy/core/models/engine.dart';
import 'package:oui_spy/theme/app_theme.dart';

/// Colours the wardrive map draws with.
class WardriveThemeData {
  const WardriveThemeData({
    required this.routeColor,
    required this.currentPosColor,
  });

  final Color routeColor;
  final Color currentPosColor;

  Color engineColor(Engine e) => e.mapColor;
}

/// A function, not a constant, so the position dot follows light and dark.
WardriveThemeData wardriveTheme() => WardriveThemeData(
      routeColor: const Color(0xFFFFFFFF),
      currentPosColor: AppTheme.accent,
    );
