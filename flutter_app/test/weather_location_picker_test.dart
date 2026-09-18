import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'test_helpers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:smart_home_app/screens/weather_location_picker_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/auth_service.dart';

class _FakeAuth extends AuthService {
  @override
  Future<String?> getToken() async => 't';
}

const _devices = [
  {
    'deviceId': 'D1',
    'name': 'Sonoff 01',
    'farmName': 'Field North',
    'channels': 4,
  },
  {
    'deviceId': 'D2',
    'name': 'Sonoff 02',
    'channels': 4,
    'lat': 35.0,
    'lon': 4.0,
  },
];

Widget _stubMap(LatLng? picked, ValueChanged<LatLng> onPick) {
  return Column(
    children: [
      if (picked != null)
        Text(
          '${picked.latitude.toStringAsFixed(4)},'
          ' ${picked.longitude.toStringAsFixed(4)}',
        ),
      ElevatedButton(
        onPressed: () => onPick(const LatLng(35.2, 4.18)),
        child: const Text('stub-pick'),
      ),
    ],
  );
}

void main() {
  test('buildLocationSave uses typed name, falls back to place', () {
    final named = buildLocationSave(
      deviceId: 'D1',
      name: '  Farm North ',
      placeName: 'Bou Saada',
      lat: 35.2,
      lon: 4.18,
    );
    expect(named.farmName, 'Farm North');
    expect(named.lat, 35.2);
    expect(named.timezone, 'Africa/Algiers');

    final fallback = buildLocationSave(
      deviceId: 'D1',
      name: '   ',
      placeName: 'Bou Saada',
      lat: 35.2,
      lon: 4.18,
    );
    expect(fallback.farmName, 'Bou Saada');
  });

  testWidgets('map pick saves with auto farmName from place', (tester) async {
    Map<String, dynamic>? patched;
    String? patchedPath;
    final client = MockClient((req) async {
      if (req.method == 'PATCH') {
        patchedPath = req.url.path;
        patched = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'deviceId': 'D1', 'farmName': 'Bou Saada'}),
          200,
        );
      }
      return http.Response('Not found', 404);
    });
    final api = ApiService(auth: _FakeAuth(), client: client);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        home: Scaffold(
          body: WeatherLocationPickerPage(
            devices: _devices,
            initialDeviceId: 'D1',
            api: api,
            reverseGeocode: (_, _) async => 'Bou Saada, Algeria',
            mapBuilder: _stubMap,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('stub-pick'));
    await tester.pumpAndSettle();
    expect(find.textContaining('35.2000'), findsWidgets);
    expect(find.textContaining('Bou Saada'), findsWidgets);

    await tester.tap(find.text('Confirm Location'));
    await tester.pumpAndSettle();

    expect(patchedPath, '/api/devices/D1/location');
    expect(patched?['lat'], 35.2);
    expect(patched?['lon'], 4.18);
    expect(patched?['farmName'], 'Bou Saada');
    expect(patched?['timezone'], 'Africa/Algiers');
  });

  testWidgets('remove location sends null PATCH for selected device', (
    tester,
  ) async {
    String? patchedPath;
    Map<String, dynamic>? patched;
    final client = MockClient((req) async {
      if (req.method == 'PATCH') {
        patchedPath = req.url.path;
        patched = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'deviceId': 'D2'}), 200);
      }
      return http.Response('Not found', 404);
    });
    final api = ApiService(auth: _FakeAuth(), client: client);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        home: Scaffold(
          body: WeatherLocationPickerPage(
            devices: _devices,
            initialDeviceId: 'D2',
            api: api,
            reverseGeocode: (_, _) async => null,
            mapBuilder: (_, _) =>
                const SizedBox(height: 400, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(patchedPath, '/api/devices/D2/location');
    expect(patched?['lat'], isNull);
    expect(patched?['lon'], isNull);
  });

  testWidgets('dropdown shows device name only, not location', (tester) async {
    final api = ApiService(
      auth: _FakeAuth(),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        home: Scaffold(
          body: WeatherLocationPickerPage(
            devices: const [
              {
                'deviceId': 'D1',
                'name': 'Sonoff 01',
                'farmName': 'Field North',
                'channels': 4,
              },
              {'deviceId': 'D2', 'name': 'Sonoff 02', 'channels': 4},
            ],
            initialDeviceId: 'D1',
            api: api,
            reverseGeocode: (_, _) async => null,
            mapBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sonoff 01'), findsOneWidget);
    expect(find.textContaining('Field North'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Sonoff 02'), findsWidgets);
  });

  testWidgets('save blocked without map pick', (tester) async {
    final api = ApiService(
      auth: _FakeAuth(),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: testDelegates,
        supportedLocales: testLocales,
        home: Scaffold(
          body: WeatherLocationPickerPage(
            devices: _devices,
            api: api,
            reverseGeocode: (_, _) async => null,
            mapBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Confirm Location'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Confirm Location'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
