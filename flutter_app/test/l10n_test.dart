import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/l10n/gen/app_localizations.dart';
import 'package:smart_home_app/l10n/l10n_helpers.dart';
import 'package:smart_home_app/l10n/locale_controller.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

import 'test_helpers.dart';

AppLocalizations _l10n(String code) =>
    lookupAppLocalizations(Locale(code));

/// Phase 7/8 verification for the en/ar/fr localization:
/// key parity, display, RTL, switching, persistence, plurals/parameters.
void main() {
  setUpAll(() async {
    // intl weekday/month names need explicit symbol data in tests.
    await initializeDateFormatting('ar');
    await initializeDateFormatting('fr');
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ARB key parity (no missing translations)', () {
    Map<String, dynamic> arb(String code) {
      final file = File('lib/l10n/app_$code.arb');
      expect(file.existsSync(), isTrue, reason: 'app_$code.arb missing');
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }

    Set<String> keys(Map<String, dynamic> m) => m.keys
        .where((k) => !k.startsWith('@'))
        .toSet();

    test('en, ar and fr define the exact same key set', () {
      final en = keys(arb('en'));
      final ar = keys(arb('ar'));
      final fr = keys(arb('fr'));
      expect(en.isNotEmpty, isTrue);
      expect(ar, en, reason: 'Arabic is missing keys: ${en.difference(ar)}');
      expect(fr, en, reason: 'French is missing keys: ${en.difference(fr)}');
    });

    test('no empty translations and no TODO placeholders', () {
      for (final code in ['en', 'ar', 'fr']) {
        for (final e in keys(arb(code)).map((k) => MapEntry(k, arb(code)[k]))) {
          final v = e.value as String;
          expect(v.trim().isNotEmpty, isTrue,
              reason: '$code:${e.key} is empty');
          expect(v.toLowerCase().contains('todo'), isFalse,
              reason: '$code:${e.key} looks like a placeholder');
          expect(v.contains('Arabic translation'), isFalse,
              reason: '$code:${e.key} looks machine-generated');
        }
      }
    });

    test('every supported locale resolves through the delegate', () async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = await AppLocalizations.delegate.load(locale);
        expect(l10n.navDevices.isNotEmpty, isTrue);
      }
      expect(
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
        {'en', 'ar', 'fr'},
      );
    });
  });

  group('LocaleController (single source of truth)', () {
    test('defaults to English and rejects unsupported locales', () async {
      final c = LocaleController();
      expect(c.locale, const Locale('en'));
      await c.setLocale(const Locale('de'));
      expect(c.locale, const Locale('en'));
      await c.setLocale(const Locale('ar'));
      expect(c.locale, const Locale('ar'));
      expect(c.isRtl, isTrue);
      await c.setLocale(const Locale('fr'));
      expect(c.isRtl, isFalse);
    });

    test('notifies listeners on change only', () async {
      final c = LocaleController();
      var calls = 0;
      c.addListener(() => calls++);
      await c.setLocale(const Locale('ar'));
      expect(calls, 1);
      await c.setLocale(const Locale('ar'));
      expect(calls, 1, reason: 'same locale must be a no-op');
    });

    test('persists across restarts', () async {
      final c = LocaleController();
      await c.setLocale(const Locale('ar'));
      final fresh = LocaleController();
      await fresh.load();
      expect(fresh.locale, const Locale('ar'));
    });

    test('corrupt stored value falls back to English', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'xx'});
      final c = LocaleController();
      await c.load();
      expect(c.locale, const Locale('en'));
    });
  });

  group('localized content (no silent English fallback)', () {
    test('nav labels differ per language', () {
      expect(_l10n('en').navDevices, 'Devices');
      expect(_l10n('ar').navDevices, isNot('Devices'));
      expect(_l10n('fr').navDevices, isNot('Devices'));
      expect(_l10n('ar').navDevices, 'الأجهزة');
      expect(_l10n('fr').navDevices, 'Appareils');
    });

    test('plurals: schedule count', () {
      final en = _l10n('en');
      expect(en.sharedScheduleCount('CH1–CH4', 1), contains('1 schedule'));
      expect(en.sharedScheduleCount('CH1–CH4', 3), contains('3 schedules'));
      final ar = _l10n('ar');
      expect(ar.sharedScheduleCount('CH1–CH4', 1), contains('جدول واحد'));
      expect(ar.sharedScheduleCount('CH1–CH4', 2), contains('جدولان'));
      expect(ar.sharedScheduleCount('CH1–CH4', 5), contains('5'));
      final fr = _l10n('fr');
      expect(fr.sharedScheduleCount('CH1–CH4', 1), contains('1 programme'));
      expect(fr.sharedScheduleCount('CH1–CH4', 4), contains('4 programmes'));
    });

    test('plurals: more overlaps', () {
      expect(_l10n('en').wMoreOverlaps(1), contains('1 more overlap'));
      expect(_l10n('en').wMoreOverlaps(2), contains('2 more overlaps'));
      expect(_l10n('fr').wMoreOverlaps(1), contains('1 autre chevauchement'));
      expect(_l10n('ar').wMoreOverlaps(3), contains('3'));
    });

    test('parameterized messages interpolate in all languages', () {
      for (final code in ['en', 'ar', 'fr']) {
        final l10n = _l10n(code);
        expect(l10n.schDeleteConfirm('Morning'), contains('Morning'));
        expect(l10n.ruleDeleteConfirm('Dry rule'), contains('Dry rule'));
        expect(l10n.wDirectOverlapWith('~45 min'), contains('~45 min'));
        expect(
            l10n.pvConnectingTo('tasmota-1234', 7), contains('tasmota-1234'));
        expect(l10n.pvApLost('tasmota-1'), contains('tasmota-1'));
        expect(l10n.zoneName(2), contains('2'));
        expect(l10n.channelCode(3), contains('3'));
        expect(l10n.schRangeInvalid(2), contains('2'));
      }
    });

    test('provision state labels cover every state in every language', () {
      for (final code in ['en', 'ar', 'fr']) {
        final l10n = _l10n(code);
        for (final s in ProvisionState.values) {
          expect(provisionUserLabelL10n(s, l10n).isNotEmpty, isTrue,
              reason: '$code:$s');
        }
        for (final r in WifiTestResult.values) {
          expect(wifiTestMessageL10n(r, l10n).isNotEmpty, isTrue,
              reason: '$code:$r');
        }
      }
    });

    test('weekday/month names resolve in every language', () {
      for (final code in ['en', 'ar', 'fr']) {
        for (var i = 0; i < 7; i++) {
          expect(weekdayLabel(i, code).isNotEmpty, isTrue);
        }
        for (var m = 1; m <= 12; m++) {
          expect(monthLabel(m, code).isNotEmpty, isTrue);
        }
      }
      expect(weekdayLabel(0, 'en'), 'Mon');
      expect(monthLabel(1, 'en'), 'Jan');
      expect(weekdayLabel(0, 'ar'), isNot('Mon'));
      expect(monthLabel(1, 'fr'), isNot('Jan'));
    });

    test('friendlyError localizes known fallbacks, passes server text through',
        () {
      final ar = _l10n('ar');
      expect(
        friendlyError(
            const ApiException('Failed to fetch devices'), ar),
        ar.apiFetchDevices,
      );
      expect(
        friendlyError(const ApiException('x', code: 'TIMEOUT'), ar),
        ar.apiTimeout,
      );
      expect(
        friendlyError(const ApiException('x', code: 'NETWORK_ERROR'), ar),
        ar.apiUnreachable,
      );
      // Server-generated content is returned verbatim (documented limit).
      expect(
        friendlyError(
            const ApiException('Irrigation valve stuck', code: 'VALVE_FAULT'),
            ar),
        'Irrigation valve stuck',
      );
      // Non-API errors never leak internals.
      expect(friendlyError(StateError('boom'), ar), ar.sharedSomethingWrong);
    });

    test('local setup diagnostics localize by kind', () {
      final fr = _l10n('fr');
      expect(
        localSetupErrorMessage(null, null, fr, 'fallback'),
        'fallback',
      );
    });
  });

  group('widgets: locale display, RTL and switching', () {
    testWidgets('Arabic pumps with RTL directionality', (tester) async {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context)!;
                return Column(
                  children: [
                    Text(l10n.navDevices),
                    Text(l10n.schSaved),
                  ],
                );
              },
            ),
          ),
          locale: const Locale('ar'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('الأجهزة'), findsOneWidget);
      final dir = tester.widget<Directionality>(
        find.byType(Directionality).first,
      );
      expect(dir.textDirection, TextDirection.rtl);
    });

    testWidgets('French pumps with LTR directionality', (tester) async {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Builder(
              builder: (context) =>
                  Text(AppLocalizations.of(context)!.navDevices),
            ),
          ),
          locale: const Locale('fr'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Appareils'), findsOneWidget);
      final dir = tester.widget<Directionality>(
        find.byType(Directionality).first,
      );
      expect(dir.textDirection, TextDirection.ltr);
    });

    testWidgets('controller-driven switch rebuilds UI in place', (
      tester,
    ) async {
      final lc = LocaleController();
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: lc,
          builder: (context, _) => MaterialApp(
            locale: lc.locale,
            supportedLocales: testLocales,
            localizationsDelegates: testDelegates,
            home: Scaffold(
              body: Builder(
                builder: (context) => Text(
                  AppLocalizations.of(context)!.navDevices,
                  key: const ValueKey('nav'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Devices'), findsOneWidget);

      await lc.setLocale(const Locale('ar'));
      await tester.pumpAndSettle();
      expect(find.text('الأجهزة'), findsOneWidget);
      expect(
        tester
            .widget<Directionality>(find.byType(Directionality).first)
            .textDirection,
        TextDirection.rtl,
      );

      await lc.setLocale(const Locale('fr'));
      await tester.pumpAndSettle();
      expect(find.text('Appareils'), findsOneWidget);
    });

    testWidgets('switching locale preserves form input', (tester) async {
      final lc = LocaleController();
      final field = TextEditingController(text: 'My Device');
      addTearDown(field.dispose);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: lc,
          builder: (context, _) => MaterialApp(
            locale: lc.locale,
            supportedLocales: testLocales,
            localizationsDelegates: testDelegates,
            home: Scaffold(
              body: Column(
                children: [
                  TextField(controller: field),
                  Builder(
                    builder: (context) => Text(
                      AppLocalizations.of(context)!.navDevices,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Greenhouse 1');
      await lc.setLocale(const Locale('ar'));
      await tester.pumpAndSettle();
      expect(find.text('الأجهزة'), findsOneWidget);
      expect(field.text, 'Greenhouse 1');
    });

    group('layout robustness (no overflow in ar/fr on narrow screens)', () {
      testWidgets('login screen fits 320px wide in Arabic', (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          testApp(
            const _LoginProbe(),
            locale: const Locale('ar'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('تسجيل الدخول'), findsOneWidget);
      });

      testWidgets('error/empty states fit 320px wide in Arabic and French',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        for (final code in ['ar', 'fr']) {
          await tester.pumpWidget(
            testApp(
              const _StateProbe(),
              locale: Locale(code),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'overflow in $code error/empty states',
          );
        }
      });
    });
  });
}

class _LoginProbe extends StatelessWidget {
  const _LoginProbe();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Text(l10n.appTitle),
            Text(l10n.appTagline),
            Text(l10n.authUsername),
            Text(l10n.authPassword),
            Text(l10n.authSignIn),
            Text('${l10n.authNoAccount}${l10n.authSignUp}'),
          ],
        ),
      ),
    );
  }
}

class _StateProbe extends StatelessWidget {
  const _StateProbe();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            Text(l10n.schOfflineBanner),
            Text(l10n.pvLocalAddedHint),
            Text(l10n.devDeleteConfirm),
            Text(l10n.pvRecoverySteps),
            Text(l10n.ruleEmptyHint(l10n.ruleAdd)),
            Text(l10n.sharedScheduleCount(l10n.sharedChannelRange(4), 12)),
          ],
        ),
      ),
    );
  }
}
