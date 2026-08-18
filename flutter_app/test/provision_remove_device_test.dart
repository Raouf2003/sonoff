import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/provisioning_service.dart';
import 'package:smart_home_app/theme/app_theme.dart';

/// A controllable [ApiService] for exercising the provisioning wizard's
/// duplicate / pre-flight flows without the real backend.
class _FakeApi extends ApiService {
  bool provisionSucceeds = false;
  int provisionCalls = 0;

  // Whether the device is observed on MQTT right after the claim's wait phase.
  bool deviceSeen = true;
  int deviceSeenCalls = 0;

  DeviceDuplicateStatus preflightStatus = DeviceDuplicateStatus.notFound;
  Object? preflightError;
  int preflightCalls = 0;

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
/// real navigator so the terminal state can be exercised in isolation.
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
                    testLocalSetup: (_, {lastIp}) async {},
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

void main() {
  setUp(() {
    // The wizard best-effort-writes the Local Mode device cache on provision;
    // give SharedPreferences a mocked store so that never touches a real
    // platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  group('terminal duplicate states', () {
    testWidgets(
        'existing device in YOUR account: already-exists message, no '
        'delete/re-claim option', (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_EXISTS');

      expect(find.textContaining('already exists'), findsOneWidget);
      expect(
        find.textContaining('delete it before claiming it again'),
        findsOneWidget,
      );
      // Re-claiming inside the wizard is unsupported: no removal control must
      // ever appear in the claiming flow.
      expect(find.text('Remove Device'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Delete Device'), findsNothing);
      expect(find.text('Remove device?'), findsNothing);
    });

    testWidgets('registered to another account also shows no delete option',
        (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_REGISTERED');

      expect(find.text('Remove Device'), findsNothing);
      expect(find.text('Delete'), findsNothing);
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
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.text('Remove Device'), findsNothing);
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
      expect(find.textContaining('already exists'), findsOneWidget);
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
      expect(find.textContaining('already exists'), findsOneWidget);
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
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.textContaining('Connecting device to MQTT'), findsNothing);
      expect(api.provisionCalls, 0);
    });
  });

  group('pure decision logic', () {
    test('classifyDeleteOutcome clears on success and 404, keeps otherwise', () {
      expect(classifyDeleteOutcome(succeeded: true), DeleteOutcome.cleared);
      expect(classifyDeleteOutcome(statusCode: 200), DeleteOutcome.cleared);
      expect(classifyDeleteOutcome(statusCode: 404), DeleteOutcome.cleared);
      expect(classifyDeleteOutcome(statusCode: 401), DeleteOutcome.kept);
      expect(classifyDeleteOutcome(statusCode: 500), DeleteOutcome.kept);
      expect(classifyDeleteOutcome(), DeleteOutcome.kept);
    });

    test('decidePreflight: same-account duplicate stops the claim', () {
      expect(decidePreflight(DeviceDuplicateStatus.mine),
          PreflightDecision.stopMine);
    });

    test('decidePreflight: other-account duplicate stops without removal', () {
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