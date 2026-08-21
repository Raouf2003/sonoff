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

/// UI-only settle delay for the LAN/ONLINE badge. Longer than
/// [kNetworkTransitionSettle] so the debounced same-WiFi probe (which lands at
/// +400ms after a network event) is folded into the same visible window:
/// rapid successive ReachabilityState writes during a transition collapse into
/// ONE badge render instead of a flicker per write. This delays ONLY the
/// badge's visual representation — routingPolicy/_toggle keep reading the live,
/// un-debounced [ReachabilityMonitor.state] at tap time.
const Duration kBadgeSettleDelay = Duration(milliseconds: 500);

/// Consecutive NEGATIVE same-WiFi observations (a cloud-sourced status read or
/// a failed fast probe) required before `sameWifi` may flip true→false. A
/// single transient local-read failure or probe miss must never downgrade the
/// routing verdict — mirrors the health monitor's
/// `_cloudHealthConfirmFailures = 2` pattern (devices_page.dart). Upgrades
/// stay instant: only downgrades need confirmation (fast to trust good news,
/// slow to trust bad news).
const int kSameWifiDowngradeConfirmations = 2;

/// How long a confirmed `sameWifi=true` verdict stays sticky before the
/// downgrade counter starts accumulating. Shorter than the shared
/// [kLocalReportHold] (60s) which protects local-evidence freshness for
/// rollback/evidence semantics — the badge downgrade path only needs to
/// absorb brief LAN blips (e.g. device reboots), so 10s is sufficient.
/// The [kSameWifiDowngradeConfirmations] = 2 still absorbs single
/// transient cloud reads.
const Duration kDowngradeStickyWindow = Duration(seconds: 10);

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

  /// Value equality (not identity): `ValueNotifier` skips notifying listeners
  /// for no-op `copyWith` writes that leave every field unchanged, so the badge
  /// listener is not re-armed on writes that carry no new information.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ReachabilityState) return false;
    return other.sameWifi == sameWifi &&
        other.cloudSocketReady == cloudSocketReady &&
        other.lastCheckedAt == lastCheckedAt;
  }

  @override
  int get hashCode => Object.hash(sameWifi, cloudSocketReady, lastCheckedAt);
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

  /// Consecutive negative same-WiFi observations since the last local
  /// confirmation. Reset to 0 by any positive signal (local-sourced status
  /// read or successful probe); `sameWifi` only downgrades to false once this
  /// reaches [kSameWifiDowngradeConfirmations].
  int _consecutiveCloudReads = 0;

  /// Time source. Injectable for tests so the [kLocalReportHold] sticky window
  /// and the downgrade counter can be driven deterministically.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

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
    // Forget the previous device's confirmation streak too: the downgrade
    // counter is per-device evidence, never carried across a selection.
    _consecutiveCloudReads = 0;
    _state.value = _state.value.copyWith(sameWifi: false, lastCheckedAt: null);
  }

  /// Feeds the monitor from an existing status read with ZERO extra probes. A
  /// LOCAL source proves the device is reachable on the current network (an
  /// instant upgrade); a CLOUD source is a negative signal subject to the
  /// consecutive-confirmation hysteresis — a single transient cloud fallback
  /// never downgrades the verdict. Called from the page's status apply path
  /// (initial load, 15s poll, reconnect, post-tap reconcile).
  void noteStatusResult(String deviceId, DeviceTransportSource source) {
    if (_disposed) return;
    this.deviceId = deviceId;
    if (source == DeviceTransportSource.local) {
      _applyPositiveSignal();
    } else {
      _applyNegativeSignal();
    }
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
      if (sameWifi) {
        // Positive probe: trust instantly and reset the downgrade counter.
        _applyPositiveSignal();
      } else {
        // A failed probe is a negative signal subject to the SAME
        // consecutive-confirmation hysteresis as a cloud-sourced status read —
        // one fast-probe miss never downgrades the routing verdict.
        _applyNegativeSignal();
      }
    } catch (_) {
      // A failed probe is not evidence: keep the previous sameWifi verdict and
      // just stamp the check time so the state is never permanently unknown.
      if (_disposed) return;
      this.deviceId = deviceId;
      _state.value = _state.value.copyWith(lastCheckedAt: now());
    } finally {
      _refreshing = false;
      if (_pendingRefresh) {
        _pendingRefresh = false;
        unawaited(_refresh(deviceId));
      }
    }
  }

  /// Positive same-WiFi confirmation (a local-sourced status read or a
  /// successful probe). Trusted instantly, exactly like the codebase's
  /// asymmetric trust pattern: fast to trust good news. Resets the downgrade
  /// counter so any cloud reads before the next local confirmation start over.
  void _applyPositiveSignal() {
    _consecutiveCloudReads = 0;
    _state.value = _state.value.copyWith(
      sameWifi: true,
      lastCheckedAt: now(),
    );
  }

/// Negative same-WiFi signal (a cloud-sourced status read or a failed fast
/// probe). A confirmed `sameWifi=true` verdict is sticky for
/// [kDowngradeStickyWindow] — a stray negative signal inside that window is
/// ignored entirely and does not even count toward the downgrade. Otherwise
/// the verdict only downgrades to false after
/// [kSameWifiDowngradeConfirmations] consecutive negative signals with no
/// local confirmation in between.
  void _applyNegativeSignal() {
    final currentNow = now();
    final current = _state.value;
    final sticky = current.sameWifi &&
        current.lastCheckedAt != null &&
        currentNow.difference(current.lastCheckedAt!) < kDowngradeStickyWindow;
    if (sticky) return;
    _consecutiveCloudReads++;
    if (!current.sameWifi) {
      // Already downgraded. Only a first read that moves an UNKNOWN state to a
      // confirmed cloud verdict needs to publish (stamps lastCheckedAt so
      // `isUnknown` reflects that a check has happened); no-op negative reads
      // do not re-arm the badge listener.
      if (current.lastCheckedAt == null) {
        _state.value = current.copyWith(lastCheckedAt: currentNow);
      }
      return;
    }
    if (_consecutiveCloudReads >= kSameWifiDowngradeConfirmations) {
      _state.value = current.copyWith(sameWifi: false, lastCheckedAt: currentNow);
    }
  }

  void dispose() {
    _disposed = true;
    _networkDebounce?.cancel();
    _networkDebounce = null;
    _state.dispose();
  }
}