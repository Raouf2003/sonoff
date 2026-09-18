import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/l10n/locale_controller.dart';
import 'package:smart_home_app/screens/add_device_screen.dart';
import 'package:smart_home_app/screens/add_sensor_screen.dart';
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/screens/login_screen.dart';
import 'package:smart_home_app/screens/main_shell.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/screens/rule_form_screen.dart';
import 'package:smart_home_app/screens/rules_page.dart';
import 'package:smart_home_app/screens/schedule_form_screen.dart';
import 'package:smart_home_app/screens/schedule_list_screen.dart';
import 'package:smart_home_app/screens/schedules_page.dart';
import 'package:smart_home_app/screens/sensor_rules_screen.dart';
import 'package:smart_home_app/screens/sensors_page.dart';
import 'package:smart_home_app/screens/signup_screen.dart';
import 'package:smart_home_app/screens/weather_location_picker_page.dart';
import 'package:smart_home_app/screens/weather_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';

import 'test_helpers.dart';

/// Production-readiness overflow audit: every reachable screen/state is pumped
/// at 320/360/375 CSS px in English, French (longest strings) and Arabic
/// (RTL) and must produce zero layout exceptions (e.g. RenderFlex overflow).
///
/// French is the primary overflow risk (expansion vs English); Arabic asserts
/// RTL correctness alongside overflow-freedom.
const _widths = [320.0, 360.0, 375.0];
const _locales = [
  Locale('en'),
  Locale('fr'),
  Locale('ar'),
];

void _mockSecureStorage(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );
}

class _SchedulesApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() async => [
        {
          'deviceId': 'dev1',
          'name': 'Very Long Device Name For Overflow Testing Purposes',
          'channels': 4,
        },
      ];

  @override
  Future<List<dynamic>> getSchedules() async => [
        {
          '_id': 's1',
          'deviceId': 'dev1',
          'name': 'An Exceptionally Long Schedule Name For Layout Stress',
          'channels': [1, 2, 3, 4],
          'enabled': true,
          'recurrence': {
            'type': 'custom',
            'daysOfWeek': [0, 1, 2, 3, 4, 5, 6],
          },
          'timeRanges': [
            {'start': '06:00', 'end': '06:30'},
            {'start': '12:00', 'end': '14:45'},
            {'start': '20:00', 'end': '21:15'},
          ],
        },
        {
          '_id': 's2',
          'deviceId': 'dev1',
          'name': 'Morning',
          'channels': [1],
          'enabled': false,
          'recurrence': {'type': 'daily', 'daysOfWeek': []},
          'timeRanges': [
            {'start': '05:00', 'end': '05:30'},
          ],
        },
      ];

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async =>
      {'online': false};

  @override
  Future<Map<String, dynamic>> toggleSchedule(String id) async => {};

  @override
  Future<Map<String, dynamic>> deleteSchedule(String id) async => {};
}

class _RulesApi extends ApiService {
  @override
  Future<List<dynamic>> getRules() async => [
        {
          '_id': 'r1',
          'name': 'An Exceptionally Long Rule Name For Layout Stress Testing',
          'sensorId': 'soil_1',
          'channels': [1, 2],
          'condition': 'below',
          'threshold': 30,
          'action': 'ON',
          'enabled': true,
        },
      ];

  @override
  Future<List<dynamic>> getSensors() async => [
        {'sensorId': 'soil_1', 'name': 'Greenhouse Soil Moisture Sensor'},
        {'sensorId': 'soil_2', 'name': 'Second Sensor'},
      ];

  @override
  Future<Map<String, dynamic>> toggleRule(String id) async => {};

  @override
  Future<void> deleteRule(String id) async {}
}

class _WeatherApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() async => [
        {
          'deviceId': 'D1',
          'name': 'Field North With A Very Long Farm Name For Testing',
          'farmName': 'Field North With A Very Long Farm Name For Testing',
          'channels': 4,
          'lat': 36.1,
          'lon': 3.5,
        },
      ];

  @override
  Future<Map<String, dynamic>> getWeatherToday(String deviceId) async => {
        'deviceId': 'D1',
        'timezone': 'Africa/Algiers',
        'location': {'farmName': 'Field North', 'lat': 36.1, 'lon': 3.5},
        'fetchedAt': '2026-09-12T10:00:00.000Z',
        'forecast': {
          'temperature': 22,
          'rainProbability': 80,
          'precipitationMm': 12,
        },
        'hourly': [
          {
            'localTime': '2026-09-12T08:00',
            'temperature': 21,
            'precipitationMm': 3.2,
            'precipitationProbability': 75,
          },
          {
            'localTime': '2026-09-12T09:00',
            'temperature': 22,
            'precipitationMm': 5.1,
            'precipitationProbability': 80,
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
        'advisories': [
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
            'overlapMinutes': 135,
            'precipitationMm': 12,
            'probability': 80,
          },
          {
            'type': 'adjacent',
            'severity': 'MEDIUM',
            'scheduleId': 's1',
            'scheduleName': 'Morning',
            'channels': [1],
            'scheduleStart': '06:00',
            'scheduleEnd': '10:00',
            'rainDate': '2026-09-12',
            'rainStart': '11:30',
            'rainEnd': '12:00',
            'precipitationMm': 1.5,
            'probability': 40,
          },
        ],
      };
}

class _DevicesRepo extends DeviceRepositoryService {
  @override
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {}

  @override
  Future<List<Map<String, dynamic>>> getDevices() async => const [
        {
          'deviceId': '34987AC30304',
          'name': 'Controller With A Very Long Name For Stress',
          'channels': 4
        },
      ];

  @override
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    return RelayStatusResult(
      online: true,
      channels: {for (var i = 1; i <= 4; i++) i: const ChannelReport('OFF')},
      source: DeviceTransportSource.cloud,
      seq: 1,
    );
  }
}

class _FakeSocket implements io.Socket {
  @override
  Function() on(String event, dynamic handler) => () {};
  @override
  io.Socket connect() => this;
  @override
  io.Socket disconnect() => this;
  @override
  void dispose() {}
  @override
  void noSuchMethod(Invocation invocation) {}
}

class _ProvisionApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() async => [];
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    // Bypass the Firebase-backed notification handoff in widget tests.
    WeatherPage.pendingDeviceReader = () => null;
  });
  tearDownAll(() {
    WeatherPage.pendingDeviceReader = null;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Pumps [page] at [width] px in [locale], settles animations that can
  /// settle, then fails on ANY layout/runtime exception (overflow, etc.).
  /// Error details print synchronously so the offending widget chain keeps
  /// attribution (deferred printing reports DISPOSED objects).
  Future<void> pumpChecked(
    WidgetTester tester,
    Widget page, {
    required double width,
    required Locale locale,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    _mockSecureStorage(tester);
    final tag = '${locale.languageCode}@${width.toInt()}';
    final prevOnError = FlutterError.onError;
    // Chain (do NOT swallow): the framework must still record the error so
    // takeException() observes it; we only add logging of the widget chain.
    // Printed synchronously: deferred printing loses attribution (DISPOSED).
    FlutterError.onError = (details) {
      // ignore: avoid_print
      print('OVERFLOW-DETAILS $tag: ${details.exceptionAsString()}');
      for (final line in details.toString().split('\n').take(14)) {
        // ignore: avoid_print
        print('  | $line');
      }
      prevOnError?.call(details);
    };
    try {
      // Scaffold mirrors production (pages render inside MainShell's Scaffold).
      await tester.pumpWidget(testApp(Scaffold(body: page), locale: locale));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 2));
    } finally {
      FlutterError.onError = prevOnError;
    }
    expect(
      tester.takeException(),
      isNull,
      reason:
          'layout/runtime exception at ${width.toInt()}px in ${locale.languageCode}',
    );
  }

  Future<void> pumpMatrix(
    WidgetTester tester,
    Widget Function() build,
  ) async {
    for (final locale in _locales) {
      for (final width in _widths) {
        await pumpChecked(tester, build(), width: width, locale: locale);
        await tester.pumpWidget(const SizedBox());
      }
    }
  }

  group('auth + entry screens', () {
    testWidgets('login', (tester) async {
      await pumpMatrix(
          tester, () => LoginScreen(localeController: LocaleController()));
    });
    testWidgets('signup', (tester) async {
      await pumpMatrix(
          tester, () => SignupScreen(localeController: LocaleController()));
    });
    testWidgets('add device', (tester) async {
      await pumpMatrix(tester, () => const AddDeviceScreen());
    });
    testWidgets('add sensor', (tester) async {
      await pumpMatrix(tester, () => const AddSensorScreen());
    });
    testWidgets('sensors tab (empty + error keep layout)', (tester) async {
      await pumpMatrix(
          tester, () => SensorsPage(onNavigateToTab: (_) {}));
    });
  });

  group('schedules + rules', () {
    testWidgets('schedules page (banner, multi-window tiles)', (tester) async {
      await pumpMatrix(tester, () => SchedulesPage(api: _SchedulesApi()));
    });
    testWidgets('schedule form (new)', (tester) async {
      await pumpMatrix(
        tester,
        () => const ScheduleFormScreen(
          deviceId: 'dev1',
          deviceName: 'Very Long Device Name For Overflow Testing Purposes',
        ),
      );
    });
    testWidgets('schedule form (edit, 3 windows, custom days)',
        (tester) async {
      await pumpMatrix(
        tester,
        () => ScheduleFormScreen(
          deviceId: 'dev1',
          deviceName: 'dev1',
          existing: {
            '_id': 's1',
            'deviceId': 'dev1',
            'name': 'An Exceptionally Long Schedule Name For Layout Stress',
            'channels': [1, 2, 3, 4],
            'enabled': true,
            'recurrence': {
              'type': 'custom',
              'daysOfWeek': [0, 1, 2, 3, 4, 5, 6],
            },
            'timeRanges': [
              {'start': '06:00', 'end': '06:30'},
              {'start': '12:00', 'end': '14:45'},
              {'start': '20:00', 'end': '21:15'},
            ],
          },
        ),
      );
    });
    testWidgets('legacy schedule list', (tester) async {
      await pumpMatrix(tester, () => const ScheduleListScreen());
    });
    testWidgets('rules page', (tester) async {
      await pumpMatrix(tester, () => const RulesPage());
    });
    testWidgets('rule form (new + edit)', (tester) async {
      await pumpMatrix(
        tester,
        () => const RuleFormScreen(
          sensorId: 'soil_1',
          sensorName: 'Greenhouse Soil Moisture Sensor With Long Name',
        ),
      );
      await pumpMatrix(
        tester,
        () => const RuleFormScreen(
          sensorId: 'soil_1',
          sensorName: 'soil_1',
          existing: {
            '_id': 'r1',
            'name': 'Dry rule',
            'channels': [1, 2],
            'condition': 'below',
            'threshold': 30,
            'action': 'ON',
          },
        ),
      );
    });
    testWidgets('sensor rules screen', (tester) async {
      await pumpMatrix(
        tester,
        () => const SensorRulesScreen(
          sensorId: 'soil_1',
          sensorName: 'Greenhouse Soil Moisture Sensor With Long Name',
        ),
      );
    });
  });

  group('devices + weather', () {
    testWidgets('devices page (hero + relay grid)', (tester) async {
      await pumpMatrix(
        tester,
        () => DevicesPage.test(
          onNavigateToTab: (_) {},
          testRepository: _DevicesRepo(),
          testSocketFactory: (url, opts) => _FakeSocket(),
          testHealthCheck: () async => true,
          testApi: _ProvisionApi(),
        ),
      );
    });
    testWidgets('weather page (conditions + advisories)', (tester) async {
      var tag = '';
      final collected = <FlutterErrorDetails>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        collected.add(details);
        // ignore: avoid_print
        print('OVERFLOW-DETAILS $tag: ${details.exceptionAsString()}');
        for (final line in details.toString().split('\n').take(25)) {
          // ignore: avoid_print
          print('  | $line');
        }
        prevOnError?.call(details);
      };
      try {
        for (final locale in _locales) {
          for (final width in _widths) {
            tag = '${locale.languageCode}@${width.toInt()}';
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            _mockSecureStorage(tester);
            await tester.pumpWidget(testApp(
                Scaffold(body: WeatherPage(api: _WeatherApi())),
                locale: locale));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            // Scroll through lazily-built cards so every section lays out.
            final list = find.byType(ListView);
            if (list.evaluate().isNotEmpty) {
              for (var i = 0; i < 6; i++) {
                await tester.drag(list.at(0), const Offset(0, -500));
                await tester.pump(const Duration(milliseconds: 300));
              }
            }
            collected.clear();
            expect(
              tester.takeException(),
              isNull,
              reason:
                  'weather layout exception at ${width.toInt()}px in ${locale.languageCode}',
            );
            await tester.pumpWidget(const SizedBox());
          }
        }
      } finally {
        FlutterError.onError = prevOnError;
      }
    });
    testWidgets('weather location picker', (tester) async {
      await pumpMatrix(
        tester,
        () => WeatherLocationPickerPage(
          devices: const [
            {
              'deviceId': 'D1',
              'name': 'Sonoff 01 With A Very Long Name For Testing',
              'farmName': 'Field North',
              'channels': 4,
              'lat': 36.1,
              'lon': 3.5,
            },
          ],
          initialDeviceId: 'D1',
          api: _ProvisionApi(),
          reverseGeocode: (_, _) async => null,
          mapBuilder: (_, _) => const SizedBox(height: 300),
        ),
      );
    });
  });

  group('provisioning wizard', () {
    testWidgets('connect step', (tester) async {
      await pumpMatrix(
        tester,
        () => ProvisionDeviceScreen.forTest(
          testApi: _ProvisionApi(),
          testWarmUp: (_) async {},
        ),
      );
    });
    testWidgets('waiting terminal (duplicate) state', (tester) async {
      await pumpMatrix(
        tester,
        () => ProvisionDeviceScreen.forTest(
          testApi: _ProvisionApi(),
          testDeviceId: '34987AC30304',
          testFailureCode: 'DEVICE_ALREADY_EXISTS',
          testWarmUp: (_) async {},
        ),
      );
    });
  });

  group('dialogs + sheets (fr/ar, 320px)', () {    testWidgets('schedule delete dialog', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      _mockSecureStorage(tester);
      await tester.pumpWidget(testApp(
        Scaffold(body: SchedulesPage(api: _SchedulesApi())),
        locale: const Locale('fr'),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('Supprimer').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rule sensor picker sheet', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      _mockSecureStorage(tester);
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        // ignore: avoid_print
        print('OVERFLOW-DETAILS sheet: ${details.exceptionAsString()}');
        for (final line in details.toString().split('\n').take(14)) {
          // ignore: avoid_print
          print('  | $line');
        }
        prevOnError?.call(details);
      };
      try {
        await tester.pumpWidget(testApp(
          Scaffold(body: RulesPage(api: _RulesApi())),
          locale: const Locale('ar'),
        ));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        // Two sensors -> Add Rule opens the sensor chooser bottom sheet.
        await tester.tap(find.text('إضافة قاعدة'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        FlutterError.onError = prevOnError;
      }
    });
  });

  group('main shell header + nav (fr/ar, 320px)', () {
    testWidgets('header language menu and bottom nav', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      _mockSecureStorage(tester);
      final lc = LocaleController();
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: lc,
          builder: (context, _) => MaterialApp(
            locale: lc.locale,
            supportedLocales: testLocales,
            localizationsDelegates: testDelegates,
            home: MainShell(localeController: lc),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Header shows brand + language + theme + logout controls.
      expect(find.byIcon(Icons.language_outlined), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      // Open the language menu: all three languages offered by name.
      await tester.tap(find.byIcon(Icons.language_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('English'), findsOneWidget);
      expect(find.text('العربية'), findsOneWidget);
      expect(find.text('Français'), findsOneWidget);
      // Switch to Arabic from the header menu.
      await tester.tap(find.text('العربية'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('الأجهزة'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
