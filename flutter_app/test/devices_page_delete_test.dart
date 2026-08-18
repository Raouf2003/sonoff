import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// Controllable ApiService: records DELETE calls and can fail them so the
/// Devices-page delete flow is exercised without the real backend.
class _DeleteApi extends ApiService {
  _DeleteApi({this.failWith});
  Object? failWith;
  int deleteCalls = 0;
  String? lastDeletedDeviceId;

  @override
  Future<void> deleteDevice(String deviceId) async {
    deleteCalls++;
    lastDeletedDeviceId = deviceId;
    final err = failWith;
    if (err != null) throw err;
  }
}

/// Repository serving one fixed registered device; status reads are inert so
/// the page renders a selectable device card.
class _FakeRepo extends DeviceRepositoryService {
  @override
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {}

  @override
  Future<List<Map<String, dynamic>>> getDevices() async => const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
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
  required _DeleteApi api,
  DeviceRepositoryService? repo,
}) async {
  _mockSecureStorage(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: DevicesPage.test(
          onNavigateToTab: (_) {},
          testRepository: repo ?? _FakeRepo(),
          testSocketFactory: (url, opts) => _FakeSocket(),
          testHealthCheck: () async => true,
          testApi: api,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the page so the status poll / cloud health timers are cancelled,
/// leaving no pending timers behind.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pump(); // Ensure dispose() runs and cancels timers
}

void main() {
  setUp(() {
    // The delete flow clears the Local Mode cache entry; give SharedPreferences
    // a mocked store so that never touches a real platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('hero card exposes a Delete Device control', (tester) async {
    final api = _DeleteApi();
    await _pumpDevicesPage(tester, api: api);

    expect(find.byTooltip('Delete Device'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('cancel leaves the device in place and calls nothing',
      (tester) async {
    final api = _DeleteApi();
    await _pumpDevicesPage(tester, api: api);

    await tester.tap(find.byTooltip('Delete Device'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Device'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 0);
    expect(find.text('Controller'), findsOneWidget);
    expect(find.byTooltip('Delete Device'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('confirm deletes, drops the device, and shows the empty state',
      (tester) async {
    final api = _DeleteApi();
    await _pumpDevicesPage(tester, api: api);

    await tester.tap(find.byTooltip('Delete Device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 1);
    expect(api.lastDeletedDeviceId, _deviceId);
    expect(find.text('Device deleted.'), findsOneWidget);
    // The only device is gone: the page falls back to the empty state and no
    // delete control (or hero card) remains.
    expect(find.text('No devices yet'), findsOneWidget);
    expect(find.byTooltip('Delete Device'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('network failure keeps the device and shows an error',
      (tester) async {
    final api = _DeleteApi()
      ..failWith = const ApiException(
        'Could not reach the server',
        code: 'NETWORK_ERROR',
      );
    await _pumpDevicesPage(tester, api: api);

    await tester.tap(find.byTooltip('Delete Device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 1);
    // Device stays; the delete control is functional again for a retry.
    expect(find.text('Controller'), findsOneWidget);
    expect(find.byTooltip('Delete Device'), findsOneWidget);
    expect(
      find.textContaining('Could not delete the device'),
      findsOneWidget,
    );

    await _unmount(tester);
  });
}