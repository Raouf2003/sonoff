import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'test_helpers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_home_app/models/weather.dart';
import 'package:smart_home_app/screens/weather_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/auth_service.dart';
import 'package:smart_home_app/widgets/stees_widgets.dart';

class _FakeAuth extends AuthService {
  @override
  Future<String?> getToken() async => 't';
}

Map<String, dynamic> _advisory({
  String type = 'overlap',
  String scheduleId = 's1',
  String scheduleName = 'Morning',
  int overlapMinutes = 0,
}) {
  return {
    'type': type,
    'severity': type == 'overlap' ? 'HIGH' : 'MEDIUM',
    'scheduleId': scheduleId,
    'scheduleName': scheduleName,
    'channels': [1, 2],
    'scheduleStart': '06:00',
    'scheduleEnd': '10:00',
    'rainDate': '2026-09-12',
    'rainStart': '08:00',
    'rainEnd': '11:00',
    if (overlapMinutes > 0) 'overlapMinutes': overlapMinutes,
    'precipitationMm': 12,
    'probability': 80,
  };
}

Map<String, dynamic> _today({
  bool disabled = false,
  bool unavailable = false,
  bool advisory = true,
  String advisoryType = 'overlap',
  String scheduleName = 'Morning',
  int overlapMinutes = 0,
  List<Map<String, dynamic>>? advisories,
  double? precipMm,
  int? precipProb,
}) {
  return {
    'deviceId': 'D1',
    'timezone': 'Africa/Algiers',
    'location': {'farmName': 'Field North', 'lat': 36.1, 'lon': 3.5},
    if (disabled) 'weatherDisabled': true,
    if (unavailable) 'weatherUnavailable': true,
    'fetchedAt': '2026-09-12T10:00:00.000Z',
    'forecast': {
      'temperature': 22,
      'rainProbability': precipProb ?? (advisory ? 80 : 5),
      'precipitationMm': precipMm ?? (advisory ? 12 : 0),
    },
    'hourly': [
      {
        'localTime': '2026-09-12T08:00',
        'temperature': 21,
        'precipitationMm': advisory ? 3.2 : 0,
        'precipitationProbability': advisory ? 75 : 5,
      },
      {
        'localTime': '2026-09-12T09:00',
        'temperature': 22,
        'precipitationMm': advisory ? 5.1 : 0,
        'precipitationProbability': advisory ? 80 : 5,
      },
    ],
    'schedules': [
      {
        'scheduleId': 's1',
        'channels': [1, 2],
        'timeRanges': [
          {'start': '06:00', 'end': '10:00'},
        ],
      },
    ],
    'advisories':
        advisories ??
        (advisory
            ? [
                _advisory(
                  type: advisoryType,
                  scheduleName: scheduleName,
                  overlapMinutes: overlapMinutes,
                ),
              ]
            : []),
  };
}

ApiService _api(Map<String, http.Response> routes) {
  final client = MockClient((req) async {
    final key = '${req.method} ${req.url.path}';
    return routes[key] ?? http.Response('Not found', 404);
  });
  return ApiService(auth: _FakeAuth(), client: client);
}

Map<String, http.Response> _routes({
  List<Map<String, dynamic>>? devices,
  Map<String, dynamic>? today,
  int todayStatus = 200,
}) {
  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json'},
  );
  return {
    'GET /api/devices': json(
      devices ??
          [
            {
              'deviceId': 'D1',
              'name': 'Field North',
              'farmName': 'Field North',
              'channels': 4,
              'lat': 36.1,
              'lon': 3.5,
            },
          ],
    ),
    'GET /api/weather/D1/today': todayStatus == 200
        ? json(today ?? _today())
        : http.Response('error', todayStatus),
    'GET /api/weather/D2/today': json(_today(disabled: true)),
  };
}

Future<void> _pump(WidgetTester tester, ApiService api) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: testDelegates,
      supportedLocales: testLocales,
      home: Scaffold(body: WeatherPage(api: api)),
    ),
  );
  await tester.pumpAndSettle();
}

/// Drags the page list until [target] is built, then settles.
Future<void> scrollPageTo(WidgetTester tester, Finder target) async {
  final list = find.byType(ListView).at(0);
  for (var i = 0; i < 8 && target.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(() {
    // Bypass the Firebase-backed notification handoff in widget tests.
    WeatherPage.pendingDeviceReader = () => null;
  });

  tearDownAll(() {
    WeatherPage.pendingDeviceReader = null;
  });

  test('WeatherToday parses backend shape', () {
    final w = WeatherToday.fromJson(_today());
    expect(w.advisories.length, 1);
    expect(w.hourly.length, 2);
    expect(w.schedules.first.window, contains('06:00'));
  });

  testWidgets('weather available shows forecast, hourly and advisory', (
    tester,
  ) async {
    await _pump(tester, _api(_routes()));
    expect(find.textContaining('Field North'), findsWidgets);
    expect(find.textContaining('12.0 mm'), findsWidgets);
    await scrollPageTo(tester, find.text('Rain during irrigation'));
    expect(find.text('Rain during irrigation'), findsOneWidget);
    expect(find.textContaining('08:00'), findsWidgets);
  });

  testWidgets(
    'CURRENT CONDITIONS card comes first, before forecast and irrigation',
    (tester) async {
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await _pump(tester, _api(_routes()));
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      final currentIdx = texts.indexOf('CURRENT CONDITIONS');
      final forecastIdx = texts.indexOf('FORECAST');
      final conflictIdx = texts.indexOf('Rain during irrigation');
      final irrigationIdx = texts.indexOf('TODAY\u2019S IRRIGATION');
      expect(currentIdx, isNot(-1));
      expect(forecastIdx, isNot(-1));
      expect(conflictIdx, isNot(-1));
      expect(irrigationIdx, isNot(-1));
      expect(currentIdx, lessThan(forecastIdx));
      expect(forecastIdx, lessThan(conflictIdx));
      expect(conflictIdx, lessThan(irrigationIdx));
    },
  );

  testWidgets('current card does NOT show precipitation probability', (
    tester,
  ) async {
    await _pump(tester, _api(_routes()));
    expect(find.textContaining('% chance'), findsWidgets); // hourly does
    // The current card must not contain probability text.
    final currentCards = find.ancestor(
      of: find.text('CURRENT CONDITIONS'),
      matching: find.byType(SteesCard),
    );
    expect(
      find.descendant(of: currentCards, matching: find.textContaining('%')),
      findsNothing,
    );
    // Also ensure misleading significant wording is gone.
    expect(find.text('Significant rain right now'), findsNothing);
    expect(find.text('No significant rain right now'), findsNothing);
  });

  testWidgets('future hourly forecast DOES show precipitation probability', (
    tester,
  ) async {
    await _pump(tester, _api(_routes()));
    await scrollPageTo(tester, find.text('FORECAST'));
    // Future cells show rain probability as forecast qualifier.
    expect(find.textContaining('%'), findsWidgets);
    // At least one future cell should show a percentage (from hourly 75%/80%).
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
  });

  testWidgets(
    'current precipitation is displayed with semantically correct wording',
    (tester) async {
      await _pump(
        tester,
        _api(_routes(today: _today(precipMm: 2.4, advisory: false))),
      );
      expect(find.text('CURRENT CONDITIONS'), findsOneWidget);
      expect(find.text('2.4 mm'), findsOneWidget);
      expect(find.textContaining('Last hour'), findsOneWidget);
      // Temperature is dominant and present inside the current card.
      final currentCards = find.ancestor(
        of: find.text('CURRENT CONDITIONS'),
        matching: find.byType(SteesCard),
      );
      expect(
        find.descendant(of: currentCards, matching: find.text('22°')),
        findsOneWidget,
      );
      expect(find.text('Temperature'), findsOneWidget);
      // No probability inside current card.
      expect(
        find.descendant(
          of: currentCards,
          matching: find.textContaining('chance'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('no advisory shows current card and no conflict cards', (
    tester,
  ) async {
    await _pump(tester, _api(_routes(today: _today(advisory: false))));
    expect(find.text('CURRENT CONDITIONS'), findsOneWidget);
    expect(find.text('Rain during irrigation'), findsNothing);
    expect(find.text('Rain near irrigation'), findsNothing);
  });

  testWidgets('MEDIUM conflict renders without overlap wording', (
    tester,
  ) async {
    await _pump(tester, _api(_routes(today: _today(advisoryType: 'adjacent'))));
    expect(find.text('Rain near irrigation'), findsOneWidget);
    expect(find.text('Rain during irrigation'), findsNothing);
    expect(find.text('Close to irrigation window'), findsOneWidget);
  });

  testWidgets('overlap and adjacent groups render their own cards', (
    tester,
  ) async {
    await _pump(
      tester,
      _api(
        _routes(
          today: _today(
            advisories: [
              _advisory(type: 'adjacent', scheduleId: 's2'),
              _advisory(type: 'overlap'),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Rain during irrigation'), findsOneWidget);
    expect(find.text('Rain near irrigation'), findsOneWidget);
  });

  testWidgets('HIGH overlap advisory remains visible', (tester) async {
    await _pump(tester, _api(_routes(today: _today(advisoryType: 'overlap'))));
    expect(find.text('Rain during irrigation'), findsOneWidget);
    expect(find.textContaining('Direct overlap'), findsOneWidget);
  });

  testWidgets('SAFE state remains correct (no advisories, no impact cards)', (
    tester,
  ) async {
    await _pump(tester, _api(_routes(today: _today(advisory: false))));
    expect(find.text('CURRENT CONDITIONS'), findsOneWidget);
    expect(find.text('FORECAST'), findsOneWidget);
    expect(find.text('TODAY\u2019S IRRIGATION'), findsOneWidget);
    expect(find.text('Rain during irrigation'), findsNothing);
    expect(find.text('Rain near irrigation'), findsNothing);
    // Current card is still present and honest.
    expect(find.textContaining('Last hour'), findsOneWidget);
  });

  testWidgets('Review Schedule action navigates to Schedules tab', (
    tester,
  ) async {
    var navigatedTo = -1;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        home: Scaffold(
          body: WeatherPage(
            api: _api(_routes()),
            onNavigateToTab: (i) => navigatedTo = i,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Review Schedule'), findsWidgets);
    await tester.tap(find.text('Review Schedule').first);
    await tester.pumpAndSettle();
    expect(navigatedTo, 2);
  });

  testWidgets('duplicate schedule name is hidden', (tester) async {
    await _pump(
      tester,
      _api(_routes(today: _today(scheduleName: '06:00–10:00'))),
    );
    // Advisory card should show window+channels but not duplicate name.
    expect(find.text('06:00–10:00 · CH1 · CH2'), findsOneWidget);
    expect(find.textContaining('06:00–10:00 · 06:00–10:00'), findsNothing);
  });

  testWidgets('genuinely different schedule name is kept', (tester) async {
    await _pump(tester, _api(_routes()));
    expect(find.text('Morning'), findsOneWidget);
  });

  testWidgets('overlap duration is displayed when available', (tester) async {
    Future<void> repump(Map<String, dynamic> today) async {
      // Force a fresh State (same-type pumpWidget would preserve it).
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          home: Scaffold(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          home: Scaffold(
            body: WeatherPage(api: _api(_routes(today: today))),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await repump(_today(overlapMinutes: 45));
    expect(find.text('Direct overlap · ~45 min'), findsOneWidget);
    await repump(_today(overlapMinutes: 135));
    expect(find.text('Direct overlap · ~2 h 15 min'), findsOneWidget);
  });

  testWidgets('day pills use real dates, never Day +2', (tester) async {
    await _pump(tester, _api(_routes()));
    await scrollPageTo(tester, find.text('FORECAST'));
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = DateTime.now().add(const Duration(days: 2));
    expect(find.text('${months[d.month - 1]} ${d.day}'), findsOneWidget);
    expect(find.text('Day +2'), findsNothing);
    expect(
      find.text('Significant rain: ≥2 mm with ≥50% chance'),
      findsOneWidget,
    );
  });

  testWidgets('current hour cell is marked NOW and without probability', (
    tester,
  ) async {
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    final prefix = '${now.year}-${pad(now.month)}-${pad(now.day)}';
    final today = _today(advisory: false);
    today['hourly'] = [
      {
        'localTime': '${prefix}T${pad(now.hour)}:00',
        'temperature': 20,
        'precipitationMm': 3.0,
        'precipitationProbability': 70,
      },
      {
        'localTime': '${prefix}T${pad((now.hour + 1) % 24)}:00',
        'temperature': 21,
        'precipitationMm': 4.6,
        'precipitationProbability': 92,
      },
    ];
    await _pump(tester, _api(_routes(today: today)));
    await scrollPageTo(tester, find.text('FORECAST'));
    // Current hour cell is highlighted with NOW and does not show probability.
    expect(find.text('NOW'), findsOneWidget);
    // Future cell still shows probability.
    expect(find.text('92%'), findsOneWidget);
  });

  testWidgets('no devices shows empty state', (tester) async {
    await _pump(tester, _api(_routes(devices: [])));
    expect(find.text('No devices yet'), findsOneWidget);
  });

  testWidgets('weather disabled shows location prompt', (tester) async {
    await _pump(
      tester,
      _api(
        _routes(
          devices: [
            {'deviceId': 'D2', 'name': 'Field South', 'channels': 4},
          ],
          today: _today(disabled: true),
        ),
      ),
    );
    expect(find.text('Weather location not configured'), findsOneWidget);
    expect(find.text('Set Location'), findsOneWidget);
  });

  testWidgets('weather unavailable shows irrigation-safe message', (
    tester,
  ) async {
    await _pump(tester, _api(_routes(today: _today(unavailable: true))));
    expect(find.text('Forecast unavailable'), findsOneWidget);
    expect(find.textContaining('unaffected'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // Irrigation schedules stay visible even without a forecast.
    expect(find.text('TODAY\u2019S IRRIGATION'), findsOneWidget);
    expect(find.textContaining('06:00'), findsWidgets);
  });

  testWidgets('api failure does not crash', (tester) async {
    await _pump(tester, _api(_routes(todayStatus: 500)));
    expect(find.text('Could not load weather'), findsOneWidget);
  });

  testWidgets('switching device reloads that device weather', (tester) async {
    final d2Today = _today();
    d2Today['advisories'] = [];
    final api = _api({
      'GET /api/devices': http.Response(
        jsonEncode([
          {
            'deviceId': 'D1',
            'name': 'North',
            'farmName': 'Field North',
            'channels': 4,
            'lat': 36.1,
            'lon': 3.5,
          },
          {
            'deviceId': 'D2',
            'name': 'South',
            'farmName': 'Field South',
            'channels': 4,
            'lat': 35.0,
            'lon': 4.0,
          },
        ]),
        200,
      ),
      'GET /api/weather/D1/today': http.Response(jsonEncode(_today()), 200),
      'GET /api/weather/D2/today': http.Response(jsonEncode(d2Today), 200),
    });
    await _pump(tester, api);
    expect(find.text('Rain during irrigation'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('South · D2').last);
    await tester.pumpAndSettle();
    expect(find.text('CURRENT CONDITIONS'), findsOneWidget);
    expect(find.text('Rain during irrigation'), findsNothing);
  });

  test('WeatherToday parses backend shape and API contract unchanged', () {
    final raw = _today();
    final w = WeatherToday.fromJson(raw);
    // Contract: these fields are already served and still parsed.
    expect(w.temperature, isA<double?>());
    expect(w.precipitationMm, isA<double>());
    expect(w.rainProbability, isA<int>());
    expect(w.hourly.first.precipitationMm, isA<double>());
    expect(w.hourly.first.precipitationProbability, isA<int>());
    expect(w.advisories.first.precipitationMm, isA<double>());
    expect(w.advisories.first.probability, isA<int>());
    expect(w.advisories.first.overlapMinutes, isA<int>());
  });
}
