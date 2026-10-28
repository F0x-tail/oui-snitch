// SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theme mode state — persisted to SharedPreferences. Follows the phone's
/// light/dark setting until the user picks one.
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  static const _key = 'theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = switch (prefs.getString(_key)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});


enum UnitSystem { metric, imperial }

class UnitSystemNotifier extends StateNotifier<UnitSystem> {
  UnitSystemNotifier() : super(UnitSystem.metric) {
    _load();
  }

  static const _key = 'unit_system';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value == 'imperial') {
      state = UnitSystem.imperial;
    }
  }

  Future<void> toggle() async {
    state = state == UnitSystem.metric ? UnitSystem.imperial : UnitSystem.metric;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, state == UnitSystem.imperial ? 'imperial' : 'metric');
  }

  Future<void> setSystem(UnitSystem system) async {
    state = system;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, system == UnitSystem.imperial ? 'imperial' : 'metric');
  }
}

final unitSystemProvider =
    StateNotifierProvider<UnitSystemNotifier, UnitSystem>((ref) {
  return UnitSystemNotifier();
});

/// Helper to format distances and speeds respecting unit preference.
class UnitFormatter {
  const UnitFormatter._();

  static String distance(double km, UnitSystem units) {
    if (units == UnitSystem.imperial) {
      final mi = km * 0.621371;
      return '${mi.toStringAsFixed(1)} mi';
    }
    return '${km.toStringAsFixed(1)} km';
  }

  static String distanceShort(double km, UnitSystem units) {
    if (units == UnitSystem.imperial) {
      return (km * 0.621371).toStringAsFixed(1);
    }
    return km.toStringAsFixed(1);
  }

  static String distanceLabel(UnitSystem units) {
    return units == UnitSystem.imperial ? 'MI' : 'KM';
  }

  static String speed(double kmh, UnitSystem units) {
    if (units == UnitSystem.imperial) {
      final mph = kmh * 0.621371;
      return '${mph.toStringAsFixed(0)} mph';
    }
    return '${kmh.toStringAsFixed(0)} km/h';
  }

  static String speedShort(double kmh, UnitSystem units) {
    if (units == UnitSystem.imperial) {
      return (kmh * 0.621371).toStringAsFixed(0);
    }
    return kmh.toStringAsFixed(0);
  }

  static String speedLabel(UnitSystem units) {
    return units == UnitSystem.imperial ? 'MPH' : 'KM/H';
  }

  static String altitude(double meters, UnitSystem units) {
    if (units == UnitSystem.imperial) {
      return '${(meters * 3.28084).toStringAsFixed(0)}ft';
    }
    return '${meters.toStringAsFixed(0)}m';
  }

  static String detPerDist(double detsPerKm, UnitSystem units) {
    if (units == UnitSystem.imperial) {
      return (detsPerKm * 1.60934).toStringAsFixed(0);
    }
    return detsPerKm.toStringAsFixed(0);
  }

  static String detPerDistLabel(UnitSystem units) {
    return units == UnitSystem.imperial ? 'DET/MI' : 'DET/KM';
  }
}



const String _esriRest =
    'https://services.arcgisonline.com/ArcGIS/rest/services';
const String _cartoGl = 'https://basemaps.cartocdn.com/gl';

const String _osm = '© OpenStreetMap';
const String _carto = '© CARTO, © OpenStreetMap';
const String _esriImagery = '© Esri, Maxar, Earthstar Geographics';
const String _esriTopo = '© Esri, HERE, Garmin, USGS, OpenStreetMap';

enum MapStyle {
  cartoDark('Carto Dark', '$_cartoGl/dark-matter-gl-style/style.json',
      attribution: _carto, isVector: true, isDark: true),
  cartoLight('Positron', '$_cartoGl/positron-gl-style/style.json',
      attribution: _carto, isVector: true),
  cartoVoyager('Voyager', '$_cartoGl/voyager-gl-style/style.json',
      attribution: _carto, isVector: true),
  satellite('Satellite', '$_esriRest/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      attribution: _esriImagery, isDark: true),
  osm('OpenStreetMap', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      attribution: _osm),
  openTopo('Topo', 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
      attribution: '$_osm, SRTM, OpenTopoMap (CC-BY-SA)'),
  terrain('Terrain', '$_esriRest/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
      attribution: _esriTopo),
  ;

  const MapStyle(
    this.label,
    this.url, {
    required this.attribution,
    this.isVector = false,
    this.isDark = false,
  });

  final String label;
  final String url;
  final String attribution;
  final bool isVector;
  final bool isDark;
}

class MapStyleNotifier extends StateNotifier<MapStyle> {
  MapStyleNotifier() : super(MapStyle.cartoDark) {
    _load();
  }

  static const _key = 'map_style';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value != null) {
      final match = MapStyle.values.where((s) => s.name == value);
      if (match.isNotEmpty) state = match.first;
    }
  }

  Future<void> setStyle(MapStyle style) async {
    state = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, style.name);
  }
}

final mapStyleProvider =
    StateNotifierProvider<MapStyleNotifier, MapStyle>((ref) {
  return MapStyleNotifier();
});

class AppTheme {
  const AppTheme._();

  /// Status and accent colours differ between light and dark so text in them
  /// keeps at least 4.5:1 contrast on either background. They read the
  /// brightness the app last built with, which [syncBrightness] keeps current.
  static Brightness _brightness = Brightness.dark;
  static bool get _light => _brightness == Brightness.light;

  /// Called from the app's root builder. Widgets that read these colours
  /// without depending on the theme would keep the old ones after the phone
  /// switches between light and dark, so a change marks the whole tree for
  /// one rebuild.
  static void syncBrightness(BuildContext context) {
    final b = Theme.of(context).brightness;
    if (b == _brightness) return;
    _brightness = b;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void mark(Element e) {
        e.markNeedsBuild();
        e.visitChildren(mark);
      }
      WidgetsBinding.instance.rootElement?.visitChildren(mark);
    });
  }

  static const background = Color(0xFF15171A);
  static const surface = Color(0xFF1C1F23);
  static const surfaceLight = Color(0xFF252A2F);
  static const border = Color(0xFF33383F);
  static const textPrimary = Color(0xFFECEAE6);
  static const textSecondary = Color(0xFFBAB8B2);
  static const textDim = Color(0xFF96948E);

  static Color get accent => _light ? const Color(0xFF3D6B66) : const Color(0xFF8DBDB5);
  static Color get success => _light ? const Color(0xFF1A7155) : const Color(0xFF6CC4A4);
  static Color get warning => _light ? const Color(0xFF8A5A00) : const Color(0xFFE2B65E);
  static Color get error => _light ? const Color(0xFFB5441E) : const Color(0xFFF08C6E);
  static Color get info => _light ? const Color(0xFF2B6497) : const Color(0xFF8DB4DE);

  /// Text and icons drawn on an [accent] fill.
  static Color get onAccent => _light ? Colors.white : background;

  // Engines share one tint and are told apart by their icons. The map is the
  // exception: there colour is the only cue, so it uses [Engine.mapColor].
  static Color get detector => accent;
  static Color get axon => accent;
  /// Slot 1's colour under its former name, kept for the call sites that use
  /// it as a generic "this row is BLE" colour rather than as an engine colour.
  static Color get flockBle => accent;
  static Color get flockWifi => accent;
  static Color get foxhunter => accent;
  static Color get skySpy => accent;
  static Color get uniPwn => accent;
  static Color get wardrive => accent;

  // Upload targets
  static Color get wigle => accent;
  static Color get wdgwars => accent;
  static Color get wdgwarsAlt => info;

  // GPS quality colors
  static Color get gpsGood => success;
  static Color get gpsFair => warning;
  static Color get gpsPoor => error;
  static Color get gpsNone => _light ? _lightTextDim : textDim;

  static const _lightBackground = Color(0xFFF7F6F3);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightSurfaceLight = Color(0xFFECEBE6);
  static const _lightBorder = Color(0xFFCFCDC7);
  static const _lightTextPrimary = Color(0xFF1E2022);
  static const _lightTextSecondary = Color(0xFF474A4F);
  static const _lightTextDim = Color(0xFF5E6166);

  static const fontFamily = 'AtkinsonHyperlegible';
  static const monoFamily = 'AtkinsonHyperlegibleMono';

  static ResolvedTheme of(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.light
        ? const ResolvedTheme(
            background: _lightBackground,
            surface: _lightSurface,
            surfaceLight: _lightSurfaceLight,
            border: _lightBorder,
            textPrimary: _lightTextPrimary,
            textSecondary: _lightTextSecondary,
            textDim: _lightTextDim,
          )
        : const ResolvedTheme(
            background: background,
            surface: surface,
            surfaceLight: surfaceLight,
            border: border,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            textDim: textDim,
          );
  }

  static ThemeData get darkTheme => _buildTheme(Brightness.dark);
  static ThemeData get lightTheme => _buildTheme(Brightness.light);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final bg = isDark ? background : _lightBackground;
    final sf = isDark ? surface : _lightSurface;
    final sfLight = isDark ? surfaceLight : _lightSurfaceLight;
    final bd = isDark ? border : _lightBorder;
    final tp = isDark ? textPrimary : _lightTextPrimary;
    final ts = isDark ? textSecondary : _lightTextSecondary;
    final td = isDark ? textDim : _lightTextDim;

    // Built for one fixed brightness, so it spells out the colours instead of
    // using the getters, which follow whichever brightness is current.
    final ac = isDark ? const Color(0xFF8DBDB5) : const Color(0xFF3D6B66);
    final err = isDark ? const Color(0xFFF08C6E) : const Color(0xFFB5441E);
    final onAc = isDark ? bg : Colors.white;

    return ThemeData(
      brightness: brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        surface: sf,
        onSurface: tp,
        primary: ac,
        onPrimary: onAc,
        secondary: ts,
        onSecondary: tp,
        error: err,
        onError: onAc,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: tp,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: tp,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: sf,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          side: BorderSide(color: bd, width: 0.5),
        ),
        margin: EdgeInsets.zero,
      ),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          color: tp, fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: TextStyle(
          color: tp, fontSize: 20, fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          color: tp, fontSize: 16, fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(
          color: tp, fontSize: 14, fontWeight: FontWeight.w400,
        ),
        bodyMedium: TextStyle(
          color: ts, fontSize: 13, fontWeight: FontWeight.w400,
        ),
        bodySmall: TextStyle(
          color: td, fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        labelLarge: TextStyle(
          color: tp, fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: TextStyle(
          color: ts, fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconTheme: IconThemeData(color: ts, size: 20),
      dividerTheme: DividerThemeData(
        color: bd, thickness: 0.5, space: 0,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return ac;
          return td;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return ac.withValues(alpha: 0.3);
          }
          return bd;
        }),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? ac.withValues(alpha: 0.18) : sf,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? ac : ts,
          ),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(color: s.contains(WidgetState.selected) ? ac : bd),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? bg : sf,
        selectedItemColor: ac,
        unselectedItemColor: td,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedLabelStyle:
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sfLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: bd),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: bd),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: ac),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: TextStyle(color: td, fontSize: 14),
        labelStyle: TextStyle(color: ts, fontSize: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ac,
          foregroundColor: onAc,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: tp,
          side: BorderSide(color: bd),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
    );
  }
}

/// Resolved palette for the current brightness. Use [AppTheme.of(context)].
class ResolvedTheme {
  const ResolvedTheme({
    required this.background,
    required this.surface,
    required this.surfaceLight,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDim,
  });

  final Color background;
  final Color surface;
  final Color surfaceLight;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDim;
}
