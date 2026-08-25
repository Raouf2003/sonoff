import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/theme/app_theme.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

/// Widget-level tests for the offline Connect phase of the provisioning wizard.
///
/// The Connect step must work WITHOUT any backend call or provisioning session:
/// "Open Wi-Fi Settings" must be available immediately (no session-preparation
/// gate, no "Preparing device setup…" card), and no cloud/session state may be
/// part of the Connect UI.
void main() {
  setUp(() {
    // Best-effort local cache writes/reads on claim use SharedPreferences.
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpWizard(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: ProvisionDeviceScreen.forTest(
        // The wizard's broker-info pre-fetch (backed by a real ApiService)
        // would open a real HTTP request that can never resolve under
        // FakeAsync — inject a deterministic backend so the Connect step is
        // actually reachable offline and no probe/timer leaks past the test.
        testApi: _ConnectFakeApi(),
        testWarmUp: (_) async {},
      ),
    ));
    await tester.pump();
  }

  group('Connect step (offline, no session)', () {
    testWidgets('renders immediately with Open Wi-Fi Settings available',
        (tester) async {
      await pumpWizard(tester);

      // The instructions render as a numbered checklist under the phase
      // header; the manual path names Wi-Fi Settings in step 2.
      expect(find.text('Join the device network'), findsOneWidget);
      expect(
          find.textContaining('Open Wi-Fi Settings and join that network.'),
          findsOneWidget);
      expect(find.text('Open Wi-Fi Settings'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('Open Wi-Fi Settings button is enabled from the start',
        (tester) async {
      await pumpWizard(tester);

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Open Wi-Fi Settings'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNotNull,
          reason: 'Wi-Fi Settings must be reachable with no session gate');
    });

    testWidgets('no session-preparation UI is shown', (tester) async {
      await pumpWizard(tester);

      expect(find.text('Preparing device setup…'), findsNothing);
      expect(find.text("Couldn't prepare device setup"), findsNothing);
    });

    testWidgets('three-step progress bar shows Connect as the active step',
        (tester) async {
      await pumpWizard(tester);

      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Configure'), findsOneWidget);
      expect(find.text('Wait'), findsOneWidget);
    });
  });

  group('provisioning state machine has no session-prep state', () {
    test('creatingSession was removed from ProvisionState', () {
      final labels = <String>[
        for (final s in ProvisionState.values) provisionUserLabel(s),
      ];
      expect(labels.contains('Preparing device'), isFalse,
          reason: 'the wizard must never prepare a backend session');
      expect(labels.contains('Preparing device setup…'), isFalse);
    });
  });
}

/// Deterministic backend for the Connect-step tests: the broker-info pre-fetch
/// resolves immediately and the account device snapshot is empty. This keeps
/// the wizard fully offline-capable in tests (no real HTTP, no leaks) while
/// still proving the Connect UI itself performs no backend/session prep.
class _ConnectFakeApi extends ApiService {
  @override
  Future<MqttBrokerInfo> getMqttBrokerInfo() async {
    return const MqttBrokerInfo(host: 'mqtt.stees.test', port: 1883);
  }

  @override
  Future<List<dynamic>> getDevices() async => const [];
}
