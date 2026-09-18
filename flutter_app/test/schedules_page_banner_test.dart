import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'test_helpers.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_home_app/screens/schedules_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/auth_service.dart';

class _FakeAuth extends AuthService {
  @override
  Future<String?> getToken() async => 'test-token';
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Map<String, dynamic> scheduleRow() => {
    '_id': 's1',
    'deviceId': 'dev1',
    'name': 'Morning',
    'channels': [1],
    'enabled': true,
    'recurrence': {'type': 'daily', 'daysOfWeek': []},
    'timeRanges': [
      {'start': '06:00', 'end': '06:30'},
    ],
  };

  ApiService apiWith({
    required bool online,
    required List<Map<String, dynamic>> schedules,
  }) {
    final client = MockClient((http.Request request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/devices') {
        return http.Response(
          jsonEncode([
            {'deviceId': 'dev1', 'name': 'Pump', 'channels': 4},
          ]),
          200,
        );
      }
      if (request.method == 'GET' && path == '/api/schedules') {
        return http.Response(jsonEncode(schedules), 200);
      }
      if (request.method == 'GET' && path == '/api/status') {
        return http.Response(jsonEncode({'online': online}), 200);
      }
      if (request.method == 'DELETE' && path == '/api/schedules/s1') {
        return http.Response(jsonEncode({'ok': true, 'deferred': true}), 200);
      }
      return http.Response('not found', 404);
    });
    return ApiService(auth: _FakeAuth(), client: client);
  }

  Future<void> pumpPage(WidgetTester tester, ApiService api) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        home: Scaffold(body: SchedulesPage(api: api)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('online device: no banner, normal card, no sync chips', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, apiWith(online: true, schedules: [scheduleRow()]));

    expect(find.text(kOfflineBannerText), findsNothing);
    // Card keeps its normal content: header time, Enabled toggle, Active tag.
    expect(find.text('06:00–06:30'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    // Old per-card sync UI is gone entirely.
    expect(find.text('Syncing to device…'), findsNothing);
    expect(find.text('Updating…'), findsNothing);
    expect(find.text('UPDATING…'), findsNothing);
    expect(find.text('OFFLINE'), findsNothing);
  });

  testWidgets('offline device: single top banner, card not dimmed', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, apiWith(online: false, schedules: [scheduleRow()]));

    expect(find.text(kOfflineBannerText), findsOneWidget);
    // The card itself stays fully rendered — no dimming, no per-item chips.
    expect(find.text('06:00–06:30'), findsOneWidget);
    expect(find.text('Syncing to device…'), findsNothing);
    expect(find.text('UPDATING…'), findsNothing);
    expect(find.text('OFFLINE'), findsNothing);
  });

  testWidgets('banner disappears once the device reports online again', (
    WidgetTester tester,
  ) async {
    var online = false;
    final client = MockClient((http.Request request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/devices') {
        return http.Response(
          jsonEncode([
            {'deviceId': 'dev1', 'name': 'Pump', 'channels': 4},
          ]),
          200,
        );
      }
      if (request.method == 'GET' && path == '/api/schedules') {
        return http.Response(jsonEncode([scheduleRow()]), 200);
      }
      if (request.method == 'GET' && path == '/api/status') {
        return http.Response(jsonEncode({'online': online}), 200);
      }
      return http.Response('not found', 404);
    });
    final live = ApiService(auth: _FakeAuth(), client: client);

    await pumpPage(tester, live);
    expect(find.text(kOfflineBannerText), findsOneWidget);

    // Device reconnects; the next page-level poll clears the banner without
    // any grace delay.
    online = true;
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.text(kOfflineBannerText), findsNothing);
  });

  testWidgets('delete shows a toast and no dimmed pending card', (
    WidgetTester tester,
  ) async {
    final schedules = [scheduleRow()];
    final client = MockClient((http.Request request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/devices') {
        return http.Response(
          jsonEncode([
            {'deviceId': 'dev1', 'name': 'Pump', 'channels': 4},
          ]),
          200,
        );
      }
      if (request.method == 'GET' && path == '/api/schedules') {
        return http.Response(jsonEncode(schedules), 200);
      }
      if (request.method == 'GET' && path == '/api/status') {
        return http.Response(jsonEncode({'online': false}), 200);
      }
      if (request.method == 'DELETE' && path == '/api/schedules/s1') {
        schedules.clear();
        return http.Response(jsonEncode({'ok': true, 'deferred': true}), 200);
      }
      return http.Response('not found', 404);
    });
    final api = ApiService(auth: _FakeAuth(), client: client);

    await pumpPage(tester, api);
    expect(find.text('06:00–06:30'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Schedule deleted'), findsOneWidget);
    expect(find.text('06:00–06:30'), findsNothing);
    // Offline banner may show, but never a per-card pending/dimmed state.
    expect(find.text('Removing…'), findsNothing);
  });
}
