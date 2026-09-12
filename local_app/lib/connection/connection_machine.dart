enum ConnectionPhase {
  idle,
  scanning,
  networksAvailable,
  connectingToAp,
  openingWifi,
  waitingWifi,
  wifiConnected,
  probing,
  verifying,
  syncingClock,
  succeeded,
  failed,
}

enum ConnectionFailure {
  scanFailed,
  wifiRejected,
  wifiTimeout,
  wrongNetwork,
  unreachable,
  notTasmota,
  macMismatch,
  badPassword,
  clockFailed,
}

class ConnectionState {
  const ConnectionState({
    this.phase = ConnectionPhase.idle,
    this.failure,
    this.failureDetail,
    this.foundMac,
    this.expectedMac,
    this.foundMacValue,
  });

  final ConnectionPhase phase;
  final ConnectionFailure? failure;
  final String? failureDetail;
  final String? foundMac;
  final String? expectedMac;
  final String? foundMacValue;

  bool get isTerminal =>
      phase == ConnectionPhase.succeeded || phase == ConnectionPhase.failed;
  bool get isActive =>
      !isTerminal && phase != ConnectionPhase.idle;

  ConnectionState copyWith({
    ConnectionPhase? phase,
    ConnectionFailure? failure,
    String? failureDetail,
    String? foundMac,
    String? expectedMac,
    String? foundMacValue,
  }) {
    return ConnectionState(
      phase: phase ?? this.phase,
      failure: failure,
      failureDetail: failureDetail,
      foundMac: foundMac ?? this.foundMac,
      expectedMac: expectedMac ?? this.expectedMac,
      foundMacValue: foundMacValue ?? this.foundMacValue,
    );
  }
}

sealed class ConnectionEvent {
  const ConnectionEvent();
}

class StartRequested extends ConnectionEvent {
  const StartRequested();
}

class WifiOpened extends ConnectionEvent {
  const WifiOpened();
}

class WifiDetected extends ConnectionEvent {
  const WifiDetected({required this.wifi, required this.matched, required this.internet});
  final bool wifi;
  final bool matched;
  final bool internet;
}

class WifiWatchTimeout extends ConnectionEvent {
  const WifiWatchTimeout();
}

class ProbeSucceeded extends ConnectionEvent {
  const ProbeSucceeded({required this.wifi});
  final bool wifi;
}

class DeviceFound extends ConnectionEvent {
  const DeviceFound(this.mac);
  final String mac;
}

class DeviceNotTasmota extends ConnectionEvent {
  const DeviceNotTasmota(this.detail);
  final String detail;
}

class MacMismatch extends ConnectionEvent {
  const MacMismatch({required this.expected, required this.found});
  final String expected;
  final String found;
}

class BadPassword extends ConnectionEvent {
  const BadPassword();
}

class IdentityVerified extends ConnectionEvent {
  const IdentityVerified();
}

class ClockSynced extends ConnectionEvent {
  const ClockSynced();
}

class ClockFailed extends ConnectionEvent {
  const ClockFailed(this.detail);
  final String detail;
}

class ScanRequested extends ConnectionEvent {
  const ScanRequested();
}

class ScanCompleted extends ConnectionEvent {
  const ScanCompleted({required this.count});
  final int count;
}

class ScanFailed extends ConnectionEvent {
  const ScanFailed(this.reason);
  final String reason;
}

class NetworkSelected extends ConnectionEvent {
  const NetworkSelected(this.ssid);
  final String ssid;
}

class ApJoinSucceeded extends ConnectionEvent {
  const ApJoinSucceeded();
}

class ApJoinFailed extends ConnectionEvent {
  const ApJoinFailed(this.kind);
  final ConnectionFailure kind;
}

class RetryRequested extends ConnectionEvent {
  const RetryRequested();
}

class Cancelled extends ConnectionEvent {
  const Cancelled();
}

ConnectionState connectionReduce(ConnectionState state, ConnectionEvent event) {
  if (event is Cancelled) return const ConnectionState();
  if (event is RetryRequested) return const ConnectionState();
  if (state.isTerminal) return state;
  switch (event) {
    case StartRequested():
      if (state.phase != ConnectionPhase.idle) return state;
      return state.copyWith(phase: ConnectionPhase.openingWifi);
    case ScanRequested():
      if (state.phase != ConnectionPhase.idle &&
          state.phase != ConnectionPhase.networksAvailable) {
        return state;
      }
      return state.copyWith(phase: ConnectionPhase.scanning);
    case ScanCompleted():
      if (state.phase != ConnectionPhase.scanning) return state;
      return state.copyWith(phase: ConnectionPhase.networksAvailable);
    case ScanFailed():
      if (state.phase != ConnectionPhase.scanning) return state;
      return state.copyWith(
        phase: ConnectionPhase.failed,
        failure: ConnectionFailure.scanFailed,
        failureDetail: event.reason,
      );
    case NetworkSelected():
      if (state.phase != ConnectionPhase.networksAvailable) return state;
      return state.copyWith(phase: ConnectionPhase.connectingToAp);
    case ApJoinSucceeded():
      if (state.phase != ConnectionPhase.connectingToAp) return state;
      return state.copyWith(phase: ConnectionPhase.wifiConnected);
    case ApJoinFailed():
      if (state.phase != ConnectionPhase.connectingToAp) return state;
      return state.copyWith(phase: ConnectionPhase.failed, failure: event.kind);
    case WifiOpened():
      if (state.phase != ConnectionPhase.openingWifi) return state;
      return state.copyWith(phase: ConnectionPhase.waitingWifi);
    case WifiDetected():
      if (state.phase != ConnectionPhase.waitingWifi &&
          state.phase != ConnectionPhase.openingWifi) {
        return state;
      }
      if (!event.wifi) return state;
      if (!event.matched) {
        return state.copyWith(
          phase: ConnectionPhase.failed,
          failure: ConnectionFailure.wrongNetwork,
        );
      }
      return state.copyWith(phase: ConnectionPhase.wifiConnected);
    case WifiWatchTimeout():
      if (state.phase != ConnectionPhase.waitingWifi) return state;
      return state.copyWith(
        phase: ConnectionPhase.failed,
        failure: ConnectionFailure.wifiTimeout,
      );
    case ProbeSucceeded():
      if (state.phase != ConnectionPhase.wifiConnected) return state;
      return state.copyWith(phase: ConnectionPhase.probing);
    case DeviceFound():
      if (state.phase != ConnectionPhase.probing &&
          state.phase != ConnectionPhase.wifiConnected) {
        return state;
      }
      return state.copyWith(phase: ConnectionPhase.verifying, foundMac: event.mac);
    case DeviceNotTasmota():
      if (state.phase != ConnectionPhase.probing &&
          state.phase != ConnectionPhase.wifiConnected) {
        return state;
      }
      return state.copyWith(
        phase: ConnectionPhase.failed,
        failure: ConnectionFailure.notTasmota,
        failureDetail: event.detail,
      );
    case MacMismatch():
      return state.copyWith(
        phase: ConnectionPhase.failed,
        failure: ConnectionFailure.macMismatch,
        failureDetail: null,
        expectedMac: event.expected,
        foundMacValue: event.found,
      );
    case BadPassword():
      return state.copyWith(
        phase: ConnectionPhase.failed,
        failure: ConnectionFailure.badPassword,
      );
    case IdentityVerified():
      if (state.phase != ConnectionPhase.verifying) return state;
      return state.copyWith(phase: ConnectionPhase.syncingClock);
    case ClockSynced():
      if (state.phase != ConnectionPhase.syncingClock) return state;
      return state.copyWith(phase: ConnectionPhase.succeeded);
    case ClockFailed():
      if (state.phase != ConnectionPhase.syncingClock) return state;
      return state.copyWith(
        phase: ConnectionPhase.failed,
        failure: ConnectionFailure.clockFailed,
        failureDetail: event.detail,
      );
    case RetryRequested():
    case Cancelled():
      return state;
  }
}

String failureMessage(ConnectionState state) {
  switch (state.failure) {
    case ConnectionFailure.scanFailed:
      return 'Wi-Fi scan unavailable${state.failureDetail != null ? ': ${state.failureDetail}' : '.'}';
    case ConnectionFailure.wifiRejected:
      return 'Wi-Fi connection was rejected.';
    case ConnectionFailure.wifiTimeout:
      return 'Wi-Fi connection timed out. Select the Tasmota access point and try again.';
    case ConnectionFailure.wrongNetwork:
      return 'Tasmota AP not selected. Join the network starting with Tasmota-.';
    case ConnectionFailure.unreachable:
      return 'Connected to Wi-Fi, but the Tasmota device could not be reached at 192.168.4.1.';
    case ConnectionFailure.notTasmota:
      return 'Not a Tasmota device${state.failureDetail != null ? ': ${state.failureDetail}' : '.'}';
    case ConnectionFailure.macMismatch:
      return 'DEVICE CHANGED — the connected Tasmota is not the paired device.';
    case ConnectionFailure.badPassword:
      return 'Invalid WebPassword. Update it in Settings after pairing an open device, or clear it here.';
    case ConnectionFailure.clockFailed:
      return 'Clock synchronization failed${state.failureDetail != null ? ': ${state.failureDetail}' : '.'} Schedules stay paused.';
    case null:
      return '';
  }
}
