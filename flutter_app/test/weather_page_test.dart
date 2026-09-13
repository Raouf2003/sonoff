import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_home_app/models/weather.dart';
import 'package:smart_home_app/screens/weather_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/auth_service.dart';

class _FakeAuth extends AuthService {
  @override
  Future<String?> getToken() async => 't';
}

Map<String, dynamic> _today({
  bool disabled = false,
  bool unavailable = false,
  bool advisory = true,
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
      'rainProbability': advisory ? 80 : 5,
      'precipitationMm': advisory ? 12 : 0,
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
          {'start': '06:00', 'end': '10:00'}
        ],
      },
    ],
    'advisories': advisory
        ? [
            {
              'type': 'overlap',
              'severity': 'HIGH',
              'scheduleId': 's1',
              'scheduleName': 'Morning',
              'channels': [1, 2],
              'scheduleStart': '06:00',
              'scheduleEnd': '10:00',
              'rainDate': '2026-09-12',
              'rainStart': '08:00',
              'rainEnd': '11:00',
              'precipitationMm': 12,
              'probability': 80,
            },
          ]
        : [],
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
  return {
    'GET /api/devices': http.Response(
        jsonEncode(devices ??
            [
              {
                'deviceId': 'D1',
                'name': 'Field North',
                'farmName': 'Field North',
                'channels': 4,
                'lat': 36.1,
                'lon': 3.5,
              },
            ]),
        200),
    'GET /api/weather/D1/today':
        http.Response(jsonEncode(today ?? _today()), todayStatus),
    'GET /api/weather/D2/today': http.Response(
        jsonEncode(_today(disabled: true)), 200),
  };
}

Future<void> _pump(WidgetTester tester, ApiService api) async {
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: WeatherPage(api: api))));
  await tester.pumpAndSettle();
}

void main() {
  test('WeatherToday parses backend shape', () {
    final w = WeatherToday.fromJson(_today());
    expect(w.advisories.length, 1);
    expect(w.hourly.length, 2);
    expect(w.schedules.first.window, contains('06:00'));
  });

  testWidgets('weather available shows forecast, hourly and advisory',
      (tester) async {
    await _pump(tester, _api(_routes()));
    expect(find.textContaining('Field North'), findsWidgets);
    expect(find.textContaining('12.0 mm'), findsWidgets);
    expect(find.text('Rain overlaps irrigation'), findsOneWidget);
    expect(find.textContaining('08:00'), findsWidgets);
  });

  testWidgets('no advisory shows positive empty state', (tester) async {
    await _pump(tester, _api(_routes(today: _today(advisory: false))));
    expect(find.textContaining('No significant rain overlap'), findsOneWidget);
  });

  testWidgets('weather disabled shows location prompt', (tester) async {
    await _pump(
        tester,
        _api(_routes(devices: [
          {'deviceId': 'D2', 'name': 'Field South', 'channels': 4},
        ], today: _today(disabled: true))));
    expect(find.text('Weather location not configured'), findsOneWidget);
    expect(find.text('Set Location'), findsOneWidget);
  });

  testWidgets('weather unavailable shows irrigation-safe message',
      (tester) async {
    await _pump(tester, _api(_routes(today: _today(unavailable: true))));
    expect(find.text('Weather temporarily unavailable'), findsOneWidget);
    expect(find.textContaining('unaffected'), findsOneWidget);
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
          200),
      'GET /api/weather/D1/today':
          http.Response(jsonEncode(_today()), 200),
      'GET /api/weather/D2/today':
          http.Response(jsonEncode(d2Today), 200),
    });
    await _pump(tester, api);
    expect(find.text('Rain overlaps irrigation'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('South').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('No significant rain overlap'), findsOneWidget);
    expect(find.text('Rain overlaps irrigation'), findsNothing);
  });
}
