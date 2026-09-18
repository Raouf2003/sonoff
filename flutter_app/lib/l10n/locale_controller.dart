import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Central, single source of truth for the app's [Locale].
///
/// Mirrors [ThemeController]'s design on purpose:
/// - Loads the persisted preference at startup (English by default).
/// - Exposes [locale] and notifies listeners on change.
/// - Persists the choice so it survives app restarts.
///
/// There is deliberately no other locale state anywhere else in the app:
/// widgets observe this controller (via [ListenableBuilder]) instead of
/// keeping per-screen locale variables.
class LocaleController extends ChangeNotifier {
  static const _prefKey = 'app_locale';

  /// Language codes the app ships translations for.
  static const supportedLanguageCodes = <String>['en', 'ar', 'fr'];

  LocaleController({Locale initial = const Locale('en')}) : _locale = initial;

  Locale _locale;

  Locale get locale => _locale;

  bool get isRtl => _locale.languageCode == 'ar';

  /// Restores the saved preference. Defaults to English on first launch or
  /// when the stored value is not a supported language.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null && supportedLanguageCodes.contains(saved)) {
        _locale = Locale(saved);
      }
    } catch (_) {
      // Storage unavailable: fall back to the default (English).
      _locale = const Locale('en');
    }
    notifyListeners();
  }

  /// Switches the app language. No-op when the language is already active
  /// or unsupported. Never throws: persistence failure still applies the
  /// in-memory locale.
  Future<void> setLocale(Locale locale) async {
    final code = locale.languageCode;
    if (!supportedLanguageCodes.contains(code)) return;
    if (_locale.languageCode == code) return;
    _locale = Locale(code);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, code);
    } catch (_) {
      // Persistence failure is non-fatal; in-memory locale still applies.
    }
  }
}
