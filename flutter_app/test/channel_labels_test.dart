import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/l10n/gen/app_localizations.dart';
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';

import 'test_helpers.dart';

AppLocalizations _l10n(String code) => lookupAppLocalizations(Locale(code));

class _LabelsRepo extends DeviceRepositoryService {
  @override
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {}

  @override
  Future<List<Map<String, dynamic>>> getDevices() async => const [
    {'deviceId': 'sonoff4ch', 'name': 'Irrigation', 'channels': 4},
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

class _LabelsApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() async => [];
}

void _mockSecureStorage(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('pump/valve label strings', () {
    test('exact translations', () {
      expect(_l10n('en').channelPumpValve, 'Pump / Solenoid Valve');
      expect(_l10n('ar').channelPumpValve, 'مضخة / صمام كهربائي');
      expect(_l10n('fr').channelPumpValve, 'Pompe / Électrovanne');
    });
  });

  group('channel cards (320/360/375, en/fr/ar)', () {
    const widths = [320.0, 360.0, 375.0];
    const cases = {
      'en': ('Pump / Solenoid Valve', 'CHANNEL'),
      'fr': ('Pompe / Électrovanne', 'CANAL'),
      'ar': ('مضخة / صمام كهربائي', 'القناة'),
    };

    for (final entry in cases.entries) {
      for (final width in widths) {
        testWidgets(
          '${entry.key} @ ${width.toInt()}px shows full labels, no overflow',
          (tester) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            _mockSecureStorage(tester);

            await tester.pumpWidget(
              testApp(
                Scaffold(
                  body: DevicesPage.test(
                    onNavigateToTab: (_) {},
                    testRepository: _LabelsRepo(),
                    testSocketFactory: (url, opts) => _FakeSocket(),
                    testHealthCheck: () async => true,
                    testApi: _LabelsApi(),
                  ),
                ),
                locale: Locale(entry.key),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump(const Duration(seconds: 2));

            expect(
              tester.takeException(),
              isNull,
              reason:
                  'layout exception at ${width.toInt()}px '
                  'in ${entry.key} (RenderFlex overflow?)',
            );

            // The full general label on all four cards — never truncated.
            expect(find.text(entry.value.$1), findsNWidgets(4));

            // Physical relay identifiers stay visible per channel.
            for (var i = 1; i <= 4; i++) {
              expect(find.text('${entry.value.$2} $i'), findsOneWidget);
            }

            // No legacy Zone wording remains on the cards.
            expect(find.textContaining(RegExp('Zone [0-9]')), findsNothing);

            if (entry.key == 'ar') {
              final direction = tester
                  .widget<Directionality>(find.byType(Directionality).first)
                  .textDirection;
              expect(direction, TextDirection.rtl);
            }
          },
        );
      }
    }
  });
}
