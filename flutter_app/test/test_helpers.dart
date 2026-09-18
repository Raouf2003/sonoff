import 'package:flutter/material.dart';
import 'package:smart_home_app/l10n/gen/app_localizations.dart';

/// Test-only MaterialApp with the app's real localization delegates.
///
/// Widget tests must pump this (instead of a bare [MaterialApp]) because
/// every screen reads `AppLocalizations.of(context)!`. Defaults to English;
/// pass `locale` to exercise Arabic (RTL) or French.
Widget testApp(Widget home, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: home,
  );
}

/// Localization delegates shortcut for tests that build their own
/// [MaterialApp] with extra configuration (routes, scaffolds, …).
const testDelegates = AppLocalizations.localizationsDelegates;
const testLocales = AppLocalizations.supportedLocales;
