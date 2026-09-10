import 'package:flutter_test/flutter_test.dart';
import 'package:stees_local/connection/connection_machine.dart';

ConnectionState _happyPath() {
  var s = const ConnectionState();
  s = connectionReduce(s, const StartRequested());
  s = connectionReduce(s, const WifiOpened());
  s = connectionReduce(
      s, const WifiDetected(wifi: true, matched: true, internet: false));
  s = connectionReduce(s, const ProbeSucceeded(wifi: true));
  s = connectionReduce(s, const DeviceFound('AA'));
  s = connectionReduce(s, const IdentityVerified());
  s = connectionReduce(s, const ClockSynced());
  return s;
}

void main() {
  test('happy path reaches succeeded', () {
    final s = _happyPath();
    expect(s.phase, ConnectionPhase.succeeded);
    expect(s.isTerminal, isTrue);
  });

  test('terminal states ignore further events', () {
    var s = _happyPath();
    s = connectionReduce(s, const WifiDetected(wifi: true, matched: true, internet: false));
    expect(s.phase, ConnectionPhase.succeeded);
  });

  test('duplicate start is ignored (single-flight at reducer level)', () {
    var s = connectionReduce(const ConnectionState(), const StartRequested());
    s = connectionReduce(s, const StartRequested());
    expect(s.phase, ConnectionPhase.openingWifi);
  });

  test('out-of-order events are ignored', () {
    var s = connectionReduce(const ConnectionState(), const ClockSynced());
    expect(s.phase, ConnectionPhase.idle);
    s = connectionReduce(s, const DeviceFound('AA'));
    expect(s.phase, ConnectionPhase.idle);
  });

  test('internet capability never rejects the network', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const StartRequested());
    s = connectionReduce(s, const WifiOpened());
    s = connectionReduce(
        s, const WifiDetected(wifi: true, matched: true, internet: true));
    expect(s.phase, ConnectionPhase.wifiConnected);
    expect(s.failure, isNull);
  });

  test('no-internet AP network proceeds to probing', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const StartRequested());
    s = connectionReduce(s, const WifiOpened());
    s = connectionReduce(
        s, const WifiDetected(wifi: true, matched: true, internet: false));
    expect(s.phase, ConnectionPhase.wifiConnected);
  });

  test('unmatched network fails as wrongNetwork', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const StartRequested());
    s = connectionReduce(s, const WifiOpened());
    s = connectionReduce(
        s, const WifiDetected(wifi: true, matched: false, internet: false));
    expect(s.failure, ConnectionFailure.wrongNetwork);
  });

  test('watch timeout fails while waiting', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const StartRequested());
    s = connectionReduce(s, const WifiOpened());
    s = connectionReduce(s, const WifiWatchTimeout());
    expect(s.phase, ConnectionPhase.failed);
    expect(s.failure, ConnectionFailure.wifiTimeout);
  });

  test('mac mismatch carries both identities', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const StartRequested());
    s = connectionReduce(s, const WifiOpened());
    s = connectionReduce(
        s, const WifiDetected(wifi: true, matched: true, internet: false));
    s = connectionReduce(s, const ProbeSucceeded(wifi: true));
    s = connectionReduce(s, const DeviceFound('BB'));
    s = connectionReduce(s, const MacMismatch(expected: 'AA', found: 'BB'));
    expect(s.phase, ConnectionPhase.failed);
    expect(s.failure, ConnectionFailure.macMismatch);
    expect(s.expectedMac, 'AA');
    expect(s.foundMacValue, 'BB');
    expect(failureMessage(s), contains('DEVICE CHANGED'));
  });

  test('not-tasmota, bad password and clock failure messages', () {
    var s = connectionReduce(
        const ConnectionState().copyWith(phase: ConnectionPhase.probing),
        const DeviceNotTasmota('empty'));
    expect(s.failure, ConnectionFailure.notTasmota);

    s = connectionReduce(const ConnectionState(), const BadPassword());
    expect(s.failure, ConnectionFailure.badPassword);
    expect(failureMessage(s), contains('WebPassword'));

    s = connectionReduce(
        const ConnectionState().copyWith(phase: ConnectionPhase.syncingClock),
        const ClockFailed('boom'));
    expect(s.failure, ConnectionFailure.clockFailed);
  });

  test('retry and cancel reset to idle', () {
    var s = _happyPath();
    s = connectionReduce(s, const RetryRequested());
    expect(s.phase, ConnectionPhase.idle);
    s = connectionReduce(s, const StartRequested());
    s = connectionReduce(s, const Cancelled());
    expect(s.phase, ConnectionPhase.idle);
    expect(s.isActive, isFalse);
  });

  test('scan to network list to join to wifi', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const ScanRequested());
    expect(s.phase, ConnectionPhase.scanning);
    s = connectionReduce(s, const ScanCompleted(count: 3));
    expect(s.phase, ConnectionPhase.networksAvailable);
    s = connectionReduce(s, const NetworkSelected('tasmota-AB'));
    expect(s.phase, ConnectionPhase.connectingToAp);
    s = connectionReduce(s, const ApJoinSucceeded());
    expect(s.phase, ConnectionPhase.wifiConnected);
  });

  test('scan failure and join failure map to specific errors', () {
    var s = const ConnectionState();
    s = connectionReduce(s, const ScanRequested());
    s = connectionReduce(s, const ScanFailed('denied'));
    expect(s.phase, ConnectionPhase.failed);
    expect(s.failure, ConnectionFailure.scanFailed);

    s = connectionReduce(s, const RetryRequested());
    s = connectionReduce(s, const ScanRequested());
    s = connectionReduce(s, const ScanCompleted(count: 1));
    s = connectionReduce(s, const NetworkSelected('tasmota-AB'));
    s = connectionReduce(s, const ApJoinFailed(ConnectionFailure.wifiTimeout));
    expect(s.failure, ConnectionFailure.wifiTimeout);
  });

  test('select outside the list state is ignored', () {
    var s = connectionReduce(const ConnectionState(), const NetworkSelected('x'));
    expect(s.phase, ConnectionPhase.idle);
  });

  test('isActive tracks in-flight flow', () {
    var s = const ConnectionState();
    expect(s.isActive, isFalse);
    s = connectionReduce(s, const StartRequested());
    expect(s.isActive, isTrue);
  });
}
