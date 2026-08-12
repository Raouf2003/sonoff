import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/provisioning_service.dart';
import 'package:smart_home_app/theme/app_theme.dart';

/// A controllable [ApiService] for exercising the provisioning wizard's
/// "Remove Device" flow without touching the real backend. Overrides only the
/// calls the duplicate-removal path uses.
class _FakeApi extends ApiService {
  int deleteCalls = 0;
  Object? deleteError;
  Completer<void>? deleteGate;
  bool provisionSucceeds = false;

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
    if (!provisionSucceeds) {
      throw const ApiException(
        'This device is already in your account.',
        statusCode: 409,
        code: 'DEVICE_ALREADY_EXISTS',
      );
    }
    return <String, dynamic>{'ok': true};
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
  group('Remove Device visibility (terminal duplicates)', () {
    testWidgets('DEVICE_ALREADY_EXISTS shows the Remove Device button',
        (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_EXISTS');

      expect(find.text('Remove Device'), findsOneWidget);
    });

    testWidgets('DEVICE_ALREADY_REGISTERED does NOT show Remove Device',
        (tester) async {
      await _pumpWizard(tester, _FakeApi(), code: 'DEVICE_ALREADY_REGISTERED');

      expect(find.text('Remove Device'), findsNothing);
      expect(find.text('Remove device?'), findsNothing);
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
    });

    testWidgets('confirmation calls DELETE exactly once', (tester) async {
      final api = _FakeApi();
      await _pumpWizard(tester, api, code: 'DEVICE_ALREADY_EXISTS');

      await tester.tap(find.text('Remove Device'));
      await tester.pumpAndSettle();
      await tapDialogRemoveDevice(tester);

      // The provision re-request fails with the duplicate again, so the wizard
      // returns to the failed state - but exactly one DELETE must have fired.
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
      // Re-registration succeeded, so the wizard closed (popped) - the duplicate
      // state is gone.
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
      // Treated as already removed: retry proceeds and the wizard closes.
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
      // State is preserved: the Remove Device button is still present.
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
  });
}
