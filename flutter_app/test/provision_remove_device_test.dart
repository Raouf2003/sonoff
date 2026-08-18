import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/provisioning_service.dart';
import 'package:smart_home_app/theme/app_theme.dart';

/// A controllable [ApiService] for exercising the provisioning wizard's
/// duplicate / "Remove Device" / pre-flight flows without the real backend.
class _FakeApi extends ApiService {
  int deleteCalls = 0;
  Object? deleteError;
  Completer<void>? deleteGate;

  bool provisionSucceeds = false;
  int provisionCalls = 0;

  // Post-delete re-wait: whether the device is observed on MQTT right away.
  bool deviceSeen = true;
  int deviceSeenCalls = 0;

  DeviceDuplicateStatus preflightStatus = DeviceDuplicateStatus.notFound;
  Object? preflightError;
  int preflightCalls = 0;

  @override
  Future<void> deleteDevice(String deviceId) async {
    deleteCalls++;
    final gate = deleteGate;
    if (gate != null) await gate.future;
    final err = deleteError;
    if (err != null) throw err;
  }

  @override
  Future<Map<String, dynamic>> provisionDevice({
    required String deviceId,
    required String name,
    required int channels,
  }) async {
    provisionCalls++;
    if (!provisionSucceeds) {
      throw const ApiException(
        'This device is already in your account.',
        statusCode: 409,
        code: 'DEVICE_ALREADY_EXISTS',
      );
    }
    return <String, dynamic>{'ok': true};
  }

  @override
  Future<Map<String, dynamic>> getDeviceSeen(String deviceId) async {
    deviceSeenCalls++;
    return {'seen': deviceSeen};
  }

  @override
  Future<DeviceDuplicateStatus> preflightDeviceCheck(String deviceId) async {
    preflightCalls++;
    final err = preflightError;
    if (err != null) throw err;
    return preflightStatus;
  }
}

/// Pushes the wizard (seeded directly into a terminal duplicate failure) onto a
/// real navigator so a successful re-registration can pop it cleanly.
Future<void> _pumpWizard(
  WidgetTester tester,
  _FakeApi api, {
  String? code = 'DEVICE_ALREADY_EXISTS',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProvisionDeviceScreen.forTest(
                    testApi: api,
                    testDeviceId: '34987AC30304',
                    testFailureCode: code,
                    testWarmUp: (_) async {},
                    testLocalSetup: (_) async {},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The screen's Remove Device button is a [FilledButton], while the
/// confirmation dialog's "Remove Device" action is a [TextButton]. This targets
/// only the dialog action to avoid ambiguity from the duplicate label.
Future<void> tapDialogRemoveDevice(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Remove Device'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // The wizard best-effort-writes the Local Mode device cache on provision /
    // removal; give SharedPreferences a mocked store so that never touches a
    // real platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  group('Remove Device visibility (terminal duplicates)', () {
    testWidgets('DEVICE_ALREADY_EXISTS enters terminal state with button',
        (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_EXISTS');

      expect(find.textContaining('already in your account'), findsOneWidget);
      expect(find.text('Remove Device'), findsOneWidget);
    });

    testWidgets('DEVICE_ALREADY_REGISTERED does NOT show Remove Device',
        (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_REGISTERED');

      expect(find.text('Remove Device'), findsNothing);
      expect(find.text('Remove device?'), findsNothing);
      expect(find.textContaining('another account'), findsWidgets);
    });

    testWidgets('duplicate terminal state survives repeated rebuilds',
        (tester) async {
      final api = _FakeApi();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Never flickers back to a loading / "Connecting device to MQTT" state.
      expect(find.textContaining('Connecting device to MQTT'), findsNothing);
      expect(find.textContaining('already in your account'), findsOneWidget);
      expect(find.text('Remove Device'), findsOneWidget);
    });
  });

  group('terminal freeze blocks async mutators', () {
    testWidgets('no polling and no provisioning while duplicate is terminal',
        (tester) async {
      final api = _FakeApi();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      // Advance well past the stage-advance (25s) and poll (3s) intervals. If
      // any polling/retry timer or delayed future were active it would either
      // call the backend or flicker the state.
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      expect(api.deviceSeenCalls, 0,
          reason: 'polling must stop once the duplicate state is terminal');
      expect(api.provisionCalls, 0,
          reason: 'no automatic provisioning retry in a terminal state');
      expect(find.text('Remove Device'), findsOneWidget);
    });

    testWidgets('lifecycle resume cannot restart polling in terminal state',
        (tester) async {
      final api = _FakeApi();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');
      expect(api.deviceSeenCalls, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(api.deviceSeenCalls, 0,
          reason: 'resume must not re-poll once the state is terminal');
      expect(find.text('Remove Device'), findsOneWidget);
    });

    testWidgets('polling / retry timers cannot clear the terminal state',
        (tester) async {
      final api = _FakeApi()
        ..deviceSeen = true
        ..provisionSucceeds = false;
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      // Simulate the passage of all wait-stage and poll durations twice over.
      await tester.pump(const Duration(seconds: 60));

      // The duplicate UI must remain, never a spinner / waiting state.
      expect(find.text('Remove Device'), findsOneWidget);
      expect(find.textContaining('Connecting device to MQTT'), findsNothing);
      expect(api.provisionCalls, 0);
    });
  });

  group('confirmation dialog', () {
    testWidgets('confirmation dialog appears', (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();

      expect(find.text('Remove device?'), findsOneWidget);
      expect(
        find.text(
          'This will remove this device from your account. You can add it '
          'again later.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('Cancel does NOT call DELETE', (tester) async {
      final api = _FakeApi();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 0);
      expect(find.text('Remove device?'), findsNothing);
      // State preserved.
      expect(find.text('Remove Device'), findsOneWidget);
    });

    testWidgets('confirmation calls DELETE exactly once', (tester) async {
      final api = _FakeApi();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tapDialogRemoveDevice(tester);

      expect(api.deleteCalls, 1);
    });

    testWidgets('double tap cannot create multiple DELETE requests',
        (tester) async {
      final api = _FakeApi()..deleteGate = Completer<void>();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove Device'));
      await tester.pump();
      // Deletion is in flight; the button must be disabled to block a second tap.
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Remove Device'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull,
          reason: 'Remove Device must be disabled while deletion runs');

      api.deleteGate!.complete();
      await tester.pumpAndSettle();
      expect(api.deleteCalls, 1);
    });
  });

  group('delete outcomes', () {
    testWidgets('successful DELETE clears the duplicate state', (tester) async {
      final api = _FakeApi()..provisionSucceeds = true;
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tapDialogRemoveDevice(tester);

      expect(api.deleteCalls, 1);
      // Deletion + re-registration succeeded, so the wizard closes (popped).
      expect(find.text('Remove Device'), findsNothing);
    });

    testWidgets('404 is handled as already removed', (tester) async {
      final api = _FakeApi()
        ..deleteError = const ApiException(
          'Not found',
          statusCode: 404,
          code: 'INVALID_MAC',
        )
        ..provisionSucceeds = true;
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tapDialogRemoveDevice(tester);

      expect(api.deleteCalls, 1);
      expect(find.text('Remove Device'), findsNothing);
    });

    testWidgets('network failure keeps duplicate state and shows an error',
        (tester) async {
      final api = _FakeApi()
        ..deleteError = const ApiException(
          'Could not reach the server.',
          code: 'NETWORK_ERROR',
        );
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tapDialogRemoveDevice(tester);

      expect(api.deleteCalls, 1);
      // State preserved: the Remove Device button is still present.
      expect(find.text('Remove Device'), findsOneWidget);
      expect(
        find.textContaining('Could not remove the device'),
        findsOneWidget,
      );
    });
  });

  group('pure decision logic', () {
    test('shouldShowRemoveDevice is true only for DEVICE_ALREADY_EXISTS', () {
      expect(shouldShowRemoveDevice('DEVICE_ALREADY_EXISTS'), isTrue);
      expect(shouldShowRemoveDevice('DEVICE_ALREADY_REGISTERED'), isFalse);
      expect(shouldShowRemoveDevice('DEVICE_NOT_SEEN'), isFalse);
      expect(shouldShowRemoveDevice('TIMEOUT'), isFalse);
      expect(shouldShowRemoveDevice('NETWORK_ERROR'), isFalse);
      expect(shouldShowRemoveDevice(null), isFalse);
    });

    test('classifyDeleteOutcome clears on success and 404, keeps otherwise', () {
      expect(classifyDeleteOutcome(succeeded: true), DeleteOutcome.cleared);
      expect(classifyDeleteOutcome(statusCode: 200), DeleteOutcome.cleared);
      expect(classifyDeleteOutcome(statusCode: 404), DeleteOutcome.cleared);
      expect(classifyDeleteOutcome(statusCode: 401), DeleteOutcome.kept);
      expect(classifyDeleteOutcome(statusCode: 500), DeleteOutcome.kept);
      expect(classifyDeleteOutcome(), DeleteOutcome.kept);
    });

    test('decidePreflight: same-account stops and offers removal', () {
      expect(decidePreflight(DeviceDuplicateStatus.mine),
          PreflightDecision.stopMine);
    });

    test('decidePreflight: other-account stops without removal', () {
      expect(decidePreflight(DeviceDuplicateStatus.others),
          PreflightDecision.stopOthers);
    });

    test('decidePreflight: not found continues provisioning', () {
      expect(decidePreflight(DeviceDuplicateStatus.notFound),
          PreflightDecision.continueProvisioning);
    });

    test('decidePreflight: unreachable/timeout never blocks provisioning', () {
      expect(decidePreflight(null), PreflightDecision.continueProvisioning);
    });
  });
}
