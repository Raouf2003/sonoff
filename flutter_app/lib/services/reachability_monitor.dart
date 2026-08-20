import 'dart:async';
import 'package:flutter/foundation.dart';
import 'device_repository_service.dart';
import 'device_transport.dart';

/// How long to wait after a network-change event before re-probing same-WiFi
/// detection. OS/radio events fire in bursts during a real transition
/// (WiFi ↔ cellular ↔ different WiFi), so probing immediately would hammer the
/// local-IP check repeatedly against a half-settled interface. One debounced
/// probe after the burst settles is enough.
const Duration kNetworkTransitionSettle = Duration(milliseconds: 400);

/// Live routing facts for the currently selected device, maintained
/// CONTINUOUSLY in the background so a relay tap reads a fresh value with ZERO
/// probe latency instead of racing a fresh probe against the tap.
@immutable
class ReachabilityState {
  const ReachabilityState({
    this.sameWifi = false,
    this.cloudSocketReady = true,
    this.lastCheckedAt,
  });

  /// True when the device answered on the phone's current network (a fast
  /// identity probe, or a status read that reached the device over the LAN).
  /// Ambiguous → false (the safe cloud default). Only meaningful for the device
  /// the monitor last observed.
  final bool sameWifi;

  /// True when the Socket.IO cloud connection is connected and deliverable.
  /// Folded in from the page's existing socket connect/disconnect events.
  final bool cloudSocketReady;

  /// When `sameWifi` was last (re)confirmed by a probe/status read. `null`
  /// before the first check — the state is then unknown and routes with safe
  /// defaults.
  final DateTime? lastCheckedAt;

  bool get isUnknown => lastCheckedAt == null;

  ReachabilityState copyWith({
    bool? sameWifi,
    bool? cloudSocketReady,
    DateTime? lastCheckedAt,
  }) {
    return ReachabilityState(
      sameWifi: sameWifi ?? this.sameWifi,
      cloudSocketReady: cloudSocketReady ?? this.cloudSocketReady,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }
}

/// Background same-WiFi + cloud-socket readiness monitor. Owns the single
/// source of truth for routing ([state]); the page feeds it socket events,
/// status-read outcomes, and network-change notifications, and reads it at tap
/// time.
///
/// The monitor NEVER opens a competing timer or probe loop of its own: the
/// periodic re-check piggybacks on the page's existing 15s status poll (each
/// result's local/cloud source is a free same-WiFi signal). A dedicated fast
/// probe runs only after a network-change event, debounced to [settle], once
/// the transition has settled.
class ReachabilityMonitor {
  ReachabilityMonitor(this._repository);

  final DeviceRepositoryService _repository;
  final ValueNotifier<ReachabilityState> _state =
      ValueNotifier(const ReachabilityState());

  /// The device the current [state] describes. `null` before the first check.
  String? deviceId;

  Timer? _networkDebounce;
  bool _refreshing = false;
  bool _pendingRefresh = false;
  bool _disposed = false;

  /// Observable current routing facts. Listen to it (or just read `.value`) for
  /// badge reactivity without waiting for a tap.
  ValueNotifier<ReachabilityState> get state => _state;

  /// Folds a socket connect/disconnect fact into the state. Called from the
  /// page's existing socket handlers / cloud-monitor funnel.
  void setCloudSocketReady(bool ready) {
    if (_disposed) return;
    _state.value = _state.value.copyWith(cloudSocketReady: ready);
  }

  /// Called when the selected device changes: forget the previous device's
  /// verdict so a tap before the next read defaults safely instead of using a
  /// stale same-WiFi result from another device.
  void selectDevice(String deviceId) {
    if (_disposed) return;
    this.deviceId = deviceId;
    _state.value = _state.value.copyWith(sameWifi: false, lastCheckedAt: null);
  }

  /// Feeds the monitor from an existing status read with ZERO extra probes. A
  /// LOCAL source proves the device is reachable on the current network; a
  /// CLOUD source means the LAN could not reach it. Called from the page's
  /// status apply path (initial load, 15s poll, reconnect, post-tap reconcile).
  void noteStatusResult(String deviceId, DeviceTransportSource source) {
    if (_disposed) return;
    this.deviceId = deviceId;
    _state.value = _state.value.copyWith(
      sameWifi: source == DeviceTransportSource.local,
      lastCheckedAt: DateTime.now(),
    );
  }

  /// Debounced re-probe after a network-change event (WiFi SSID / connectivity
  /// type change, socket reconnect, lifecycle resume). OS events arrive in
  /// bursts during a transition; the trailing edge settles first so the probe
  /// runs exactly once against a settled network.
  void notifyNetworkChanged(String? deviceId) {
    if (_disposed || deviceId == null) return;
    _networkDebounce?.cancel();
    _networkDebounce = Timer(kNetworkTransitionSettle, () {
      _networkDebounce = null;
      unawaited(_refresh(deviceId));
    });
  }

  Future<void> _refresh(String deviceId) async {
    if (_disposed) return;
    if (_refreshing) {
      _pendingRefresh = true;
      return;
    }
    _refreshing = true;
    try {
      final sameWifi = await _repository.isDeviceOnSameNetwork(deviceId);
      if (_disposed) return;
      this.deviceId = deviceId;
      _state.value = _state.value.copyWith(
        sameWifi: sameWifi,
        lastCheckedAt: DateTime.now(),
      );
    } catch (_) {
      // A failed probe is not evidence: keep the previous sameWifi verdict and
      // just stamp the check time so the state is never permanently unknown.
      if (_disposed) return;
      this.deviceId = deviceId;
      _state.value = _state.value.copyWith(lastCheckedAt: DateTime.now());
    } finally {
      _refreshing = false;
      if (_pendingRefresh) {
        _pendingRefresh = false;
        unawaited(_refresh(deviceId));
      }
    }
  }

  void dispose() {
    _disposed = true;
    _networkDebounce?.cancel();
    _networkDebounce = null;
    _state.dispose();
  }
}