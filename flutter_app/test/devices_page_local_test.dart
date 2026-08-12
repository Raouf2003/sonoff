import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/theme/app_theme.dart';

const _deviceId = '34987AC30304';

/// Secure storage on the test host is unregistered; a token read must simply
/// return null so `_connectSocketAsync` cannot throw unexpectedly.
void _mockSecureStorage(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );
}

class _FakeApi extends ApiService {
  final List<Map<String, dynamic>> devices;
  _FakeApi({this.devices = const []});

  @override
  Future<List<dynamic>> getDevices() async => devices;
}

/// Scriptable repository: records relay calls, can hold them in flight or
/// report the last transport source (for the LAN indicator).
class _FakeRepo extends DeviceRepositoryService {
  _FakeRepo({
    this.gateControl = false,
    this.reportLocalAfterControl = false,
  });

  final bool gateControl;
  final bool reportLocalAfterControl;
  final Completer<void> releaseControl = Completer<void>();
  int controlCalls = 0;
  DeviceTransportSource? transportSource = DeviceTransportSource.cloud;
  bool _lastControlResult = false;

  @override
  DeviceTransportSource? get lastSource =>
      _lastControlResult == true
          ? (reportLocalAfterControl
              ? DeviceTransportSource.local
              : DeviceTransportSource.cloud)
          : transportSource;

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  ) async {
    controlCalls++;
    if (gateControl) {
      // Hold in flight so the busy state and the double-tap guard can be
      // exercised. The test releases the gate explicitly.
      await releaseControl.future;
    }
    _lastControlResult = true;
    return {'online': true, 'POWER$channel': state};
  }

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    return {
      'online': true,
      'POWER1': 'OFF',
      'POWER2': 'OFF',
      'POWER3': 'OFF',
      'POWER4': 'OFF',
    };
  }
}

/// Socket-io client without a server: all calls are no-ops so the page wiring
/// can be exercised in isolation.
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

Future<void> _pumpDevicesPage(
  WidgetTester tester, {
  required DeviceRepositoryService repo,
}) async {
  _mockSecureStorage(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: DevicesPage.test(
        onNavigateToTab: (_) {},
        testApi: _FakeApi(devices: [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
        ]),
        testRepository: repo,
        testSocketFactory: (url, opts) => _FakeSocket(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the page so the 15s status poll timer is cancelled, leaving no
/// pending timers behind.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('relay taps drive the repository and keep state in sync',
      (tester) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    // Card rendered and the relay tap routes through the repository.
    expect(find.text('CHANNEL 1'), findsOneWidget);
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    // While the (gated) command is in flight the busy state is visible and
    // exactly one relay call has been dispatched.
    expect(repo.controlCalls, 1);
    expect(find.text('FLOWING'), findsWidgets);

    // Release the command: the page re-syncs channels from the fresh status.
    repo.releaseControl.complete();
    await tester.pumpAndSettle();
    expect(repo.controlCalls, 1);
    expect(find.text('DRY'), findsNWidgets(4));

    await _unmount(tester);
  });

  testWidgets('double-tap while a relay command is in flight sends it once',
      (tester) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();
    // Second tap lands while the first command is still pending (channel
    // loading). The _pendingRelays guard + loading state must block it.
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    expect(repo.controlCalls, 1,
        reason: 'a pending relay must not be re-sent on a second tap');

    await _unmount(tester);
  });

  testWidgets('successful local operation shows the subtle LAN indicator',
      (tester) async {
    final repo = _FakeRepo(reportLocalAfterControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    await tester.tap(find.text('CHANNEL 1'));
    await tester.pumpAndSettle();

    expect(find.text('LAN'), findsOneWidget,
        reason: 'Local Mode is shown implicitly, never via a mode dialog');
    expect(find.text('Online'), findsNothing);

    await _unmount(tester);
  });
}