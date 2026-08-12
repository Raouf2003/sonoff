import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/theme/app_theme.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

/// Widget-level tests for the offline Connect phase of the provisioning wizard.
///
/// The Connect step must work WITHOUT any backend call or provisioning session:
/// "Open Wi-Fi Settings" must be available immediately (no session-preparation
/// gate, no "Preparing device setup…" card), and no cloud/session state may be
/// part of the Connect UI.
void main() {
  Future<void> pumpWizard(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const ProvisionDeviceScreen(),
    ));
    await tester.pump();
  }

  group('Connect step (offline, no session)', () {
    testWidgets('renders immediately with Open Wi-Fi Settings available',
        (tester) async {
      await pumpWizard(tester);

      expect(
          find.textContaining('Connect your phone to the device Wi-Fi.'),
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
