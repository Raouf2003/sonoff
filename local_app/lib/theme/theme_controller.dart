import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Central, single source of truth for the app's [ThemeMode].
///
/// - Loads the persisted preference at startup (Light by default).
/// - Exposes [themeMode] and notifies listeners on change.
/// - Persists the choice so it survives app restarts.
///
/// There is deliberately no global mutable state anywhere else in the app:
/// widgets observe this controller (via [ListenableBuilder]) instead.
class ThemeController extends ChangeNotifier {
  static const _prefKey = 'theme_mode';

  ThemeController({ThemeMode initial = ThemeMode.light})
      : _themeMode = initial;

  ThemeMode _themeMode;

  ThemeMode get themeMode => _themeMode;

  bool get isDark => _themeMode == ThemeMode.dark;

  /// Restores the saved preference. Defaults to Light Mode on first launch.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null) {
        _themeMode = saved == 'dark' ? ThemeMode.dark : ThemeMode.light;
      }
    } catch (_) {
      // Storage unavailable: fall back to the default (Light).
      _themeMode = ThemeMode.light;
    }
    notifyListeners();
  }

  Future<void> setDark(bool dark) async {
    if (dark == isDark) return;
    _themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, _themeMode == ThemeMode.dark ? 'dark' : 'light');
    } catch (_) {
      // Persistence failure is non-fatal; in-memory mode still applies.
    }
  }

  /// Toggles between Light and Dark.
  Future<void> toggle() => setDark(!isDark);
}