import 'package:flutter/foundation.dart';
import 'device_transport.dart';

/// Pure relay-control state machine.
///
/// This file owns NO state and performs NO IO: the reducers below are pure
/// functions that turn (state, event) into (new state, list of [FollowUp]
/// hints). The view owns the actual state instances, the timers, the ripples,
/// and the transport calls — it applies the returned [FollowUp]s.
///
/// Everything is ported VERBATIM from the devices page so behaviour is
/// preserved; the only behavioural change is the removal of the unconditional
/// reconcile poll after an ambiguous REST response and the unified
/// SocketUpdate-vs-REST confirmation priority rule.

/// Cloud reachability used by the badge. The socket is the live real-time
/// signal: connected → [up]; disconnected / never connected → [down]. The old
/// `stale` tier (socket connected but no recent `device_status`) was removed
/// with the cloud-reachability routing — taps now route by same-WiFi detection,
/// never by reachability.
enum CloudReachability { up, down }

/// The single transport a tap may use. Decided ONCE per tap by [routingPolicy];
/// a command is never sent through both transports.
///
/// - [localOnly]: the device is on the same network as the phone — control it
///   directly over LAN, no cloud round-trip.
/// - [cloudOnly]: the device is on a different network — control it through
///   the cloud, no LAN attempt.
enum ControlRoute {
  localOnly,
  cloudOnly;

  /// The other transport. Used exactly once by the repository's bounded
  /// fallback safety net when the PRIMARY transport is unavailable — never for
  /// a logical rejection (auth/ownership/validation/identity).
  ControlRoute get opposite =>
      this == ControlRoute.localOnly ? ControlRoute.cloudOnly : ControlRoute.localOnly;
}

/// Device-level connectivity. Only [online]/[offline] are shown; everything
/// else is [syncing].
enum Connectivity { online, offline, syncing }

/// What produced the current OFFLINE verdict (for diagnostics/backoff).
enum OfflineKind { none, lwt, pollExhausted }

/// Effects the view must apply AFTER committing the new state. Timers, ripples
/// and the reconcile poll are view concerns and are never started inside a
/// reducer.
enum FollowUp {
  /// No action needed.
  none,

  /// Start the delayed "TURNING…" indicator timer for this channel.
  startPendingTimer,

  /// Cancel the pending-indicator timer for this channel.
  cancelPendingTimer,

  /// Start/keep the ON ripple for this channel.
  rippleOn,

  /// Stop the OFF ripple for this channel.
  rippleOff,

  /// Re-read device status (ambiguous REST response that no newer accepted
  /// report has already resolved).
  reconcilePoll,
}

/// Wrapper returned by every reducer: the new state plus the effects the view
/// must apply. [committed] is true when an event accepted a REAL (non-null)
/// report for the channel, which the view uses to decide whether the same
/// event is positive device-liveness evidence for the connectivity reducer.
class ReduceResult<T> {
  final T state;
  final List<FollowUp> effects;
  final bool committed;
  const ReduceResult(this.state, this.effects, {this.committed = false});
}

/// Configuration for both reducers, mapped from the constants previously
/// declared on the devices page:
///
/// | devices_page constant | field |
/// |---|---|
/// | `kLocalReportHold` | [localHold] |
/// | `_kCloudFreshWindow` | [cloudFreshWindow] |
/// | `_kDeviceEvidenceFreshWindow` | [evidenceFreshWindow] |
/// | `kRelayPendingIndicatorDelay` | [pendingIndicatorDelay] |
/// | `_maxPollFailures` | [maxPollFailures] |
/// | (new) | [pollBackoff] |
/// | (new) | [offlineDebounce] |
class ChannelReducerConfig {
  final Duration localHold;
  final Duration cloudFreshWindow;
  final Duration evidenceFreshWindow;
  final Duration pendingIndicatorDelay;
  final int maxPollFailures;
  final Duration pollBackoff;
  final Duration offlineDebounce;

  const ChannelReducerConfig({
    required this.localHold,
    required this.cloudFreshWindow,
    required this.evidenceFreshWindow,
    required this.pendingIndicatorDelay,
    required this.maxPollFailures,
    required this.pollBackoff,
    required this.offlineDebounce,
  });
}

/// A single relay channel's state. `reported` is ONLY ever set from an accepted
/// device report — never from `desired` (the optimistic-user-intent guard, see
/// the no-desync invariant).
class ChannelState {
  final String? reported; // 'ON' / 'OFF' / null = UNKNOWN
  final DateTime? confirmedAt; // receive time of the last ACCEPTED report
  final DateTime? serverTs; // cloud backend updatedAt
  final DeviceTransportSource? source;
  final String? desired; // user intent while pending
  final bool pending;
  final bool showIndicator;
  final int epoch; // bumped on every ACCEPTED report (rollback guard)
  final int? tapEpoch; // epoch at the tap this pending op belongs to
  final String? opId; // in-flight operation id (single-flight + socket match)

  const ChannelState({
    this.reported,
    this.confirmedAt,
    this.serverTs,
    this.source,
    this.desired,
    this.pending = false,
    this.showIndicator = false,
    this.epoch = 0,
    this.tapEpoch,
    this.opId,
  });

  ChannelState copyWith({
    String? reported,
    bool clearReported = false,
    DateTime? confirmedAt,
    bool clearConfirmedAt = false,
    DateTime? serverTs,
    bool clearServerTs = false,
    DeviceTransportSource? source,
    bool clearSource = false,
    String? desired,
    bool clearDesired = false,
    bool? pending,
    bool? showIndicator,
    int? epoch,
    int? tapEpoch,
    bool clearTapEpoch = false,
    String? opId,
    bool clearOpId = false,
  }) {
    return ChannelState(
      reported: clearReported ? null : (reported ?? this.reported),
      confirmedAt: clearConfirmedAt ? null : (confirmedAt ?? this.confirmedAt),
      serverTs: clearServerTs ? null : (serverTs ?? this.serverTs),
      source: clearSource ? null : (source ?? this.source),
      desired: clearDesired ? null : (desired ?? this.desired),
      pending: pending ?? this.pending,
      showIndicator: showIndicator ?? this.showIndicator,
      epoch: epoch ?? this.epoch,
      tapEpoch: clearTapEpoch ? null : (tapEpoch ?? this.tapEpoch),
      opId: clearOpId ? null : (opId ?? this.opId),
    );
  }
}

/// Device-wide connectivity state (badge + routing inputs).
class DeviceConnectivityState {
  final Connectivity connectivity;
  final OfflineKind offlineKind;
  final DateTime? lastDeviceEvidenceAt;
  final DateTime? lastAuthoritativeOfflineAt;
  final DateTime? lastLocalEvidenceAt;
  final int pollFailures;
  final CloudReachability cloud;

  const DeviceConnectivityState({
    this.connectivity = Connectivity.syncing,
    this.offlineKind = OfflineKind.none,
    this.lastDeviceEvidenceAt,
    this.lastAuthoritativeOfflineAt,
    this.lastLocalEvidenceAt,
    this.pollFailures = 0,
    this.cloud = CloudReachability.up,
  });

  DeviceConnectivityState copyWith({
    Connectivity? connectivity,
    OfflineKind? offlineKind,
    DateTime? lastDeviceEvidenceAt,
    bool clearLastDeviceEvidenceAt = false,
    DateTime? lastAuthoritativeOfflineAt,
    bool clearLastAuthoritativeOfflineAt = false,
    DateTime? lastLocalEvidenceAt,
    bool clearLastLocalEvidenceAt = false,
    int? pollFailures,
    CloudReachability? cloud,
  }) {
    return DeviceConnectivityState(
      connectivity: connectivity ?? this.connectivity,
      offlineKind: offlineKind ?? this.offlineKind,
      lastDeviceEvidenceAt: clearLastDeviceEvidenceAt
          ? null
          : (lastDeviceEvidenceAt ?? this.lastDeviceEvidenceAt),
      lastAuthoritativeOfflineAt: clearLastAuthoritativeOfflineAt
          ? null
          : (lastAuthoritativeOfflineAt ?? this.lastAuthoritativeOfflineAt),
      lastLocalEvidenceAt: clearLastLocalEvidenceAt
          ? null
          : (lastLocalEvidenceAt ?? this.lastLocalEvidenceAt),
      pollFailures: pollFailures ?? this.pollFailures,
      cloud: cloud ?? this.cloud,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────

sealed class ChannelEvent {
  const ChannelEvent();
}

/// User tapped a relay toward [target].
class UserTap extends ChannelEvent {
  final bool target;
  final String? opId;
  const UserTap(this.target, {this.opId});
}

/// A cloud-sourced channel report (poll or control response).
class CloudReport extends ChannelEvent {
  final ChannelReport report;
  final bool deviceOnline;
  const CloudReport(this.report, {this.deviceOnline = true});
}

/// A local (verified LAN) channel report.
class LocalReport extends ChannelEvent {
  final ChannelReport report;
  const LocalReport(this.report);
}

/// A Socket.IO channel update and/or a `device_status` liveness event.
class SocketUpdate extends ChannelEvent {
  final ChannelReport report;
  final String? opId;
  final bool deviceOnline;
  const SocketUpdate(this.report, {this.opId, this.deviceOnline = false});
}

/// The transport response for a relay command. [channel] is 1-based; [report]
/// is that channel's report from the response (null when absent).
class RestResponse extends ChannelEvent {
  final int channel;
  final ChannelReport? report;
  final bool online;
  final DeviceTransportSource source;
  const RestResponse(this.channel, {this.report, required this.online, required this.source});
}

/// The command deadline elapsed without a resolution.
class Timeout extends ChannelEvent {
  final int channel;
  const Timeout(this.channel);
}

/// Explicit MQTT LWT Offline (`device_status` offline) — authoritative.
class LwtOffline extends ChannelEvent {
  final DateTime at;
  const LwtOffline(this.at);
}

/// A single failed status poll. Only [ChannelReducerConfig.maxPollFailures]
/// consecutive failures count as strong evidence.
class PollFailure extends ChannelEvent {
  final DateTime at;
  const PollFailure(this.at);
}

/// Confirmed cloud reachability change.
class CloudHealth extends ChannelEvent {
  final CloudReachability reachability;
  const CloudHealth(this.reachability);
}

// ─────────────────────────────────────────────────────────────
// Channel reducer
// ─────────────────────────────────────────────────────────────

ReduceResult<ChannelState> channelReduce(
  ChannelState state,
  ChannelEvent event,
  ChannelReducerConfig config, {
  required DateTime now,
}) {
  switch (event) {
    case UserTap():
      return _applyTap(state, event);
    case CloudReport() || LocalReport() || SocketUpdate():
      return _applyReport(state, event, config, now);
    case RestResponse():
      return _applyRest(state, event, config, now);
    case Timeout():
      return _applyTimeout(state, event);
    default:
      // LwtOffline / PollFailure / CloudHealth are device-level.
      return ReduceResult(state, const [FollowUp.none]);
  }
}

ReduceResult<ChannelState> _applyTap(ChannelState state, UserTap event) {
  if (state.pending) {
    // Coalesce: a second tap while one command is in flight updates the
    // desired value to the latest intent without starting a new pending
    // lifecycle. The view's _pendingRelays guard ensures only one HTTP call
    // is in flight; the queued desired will be sent as a follow-up after the
    // first completes if it still differs from the confirmed state.
    final targetStr = event.target ? 'ON' : 'OFF';
    if (state.desired == targetStr) {
      return ReduceResult(state, const [FollowUp.none]);
    }
    final next = state.copyWith(desired: targetStr);
    final effect = targetStr == 'ON' ? FollowUp.rippleOn : FollowUp.rippleOff;
    return ReduceResult(next, [effect], committed: false);
  }
  final next = state.copyWith(
    desired: event.target ? 'ON' : 'OFF',
    pending: true,
    tapEpoch: state.epoch,
    opId: event.opId,
  );
  return ReduceResult(
    next,
    const [FollowUp.startPendingTimer],
    committed: false,
  );
}

/// How long after a fresh LOCAL verdict a contradicting socket telemetry echo
/// is treated as suspect (relay settle / MQTT cross-topic reordering window)
/// instead of authoritative truth. Mirrors the ReachabilityState sticky-window
/// pattern: a single contradictory message near a just-settled local read is
/// noise (stale pre-switch tele/STATE), not a state change.
const Duration kRelaySettleWindow = Duration(seconds: 2);

/// Step-1 trace: set false once the on-device capture confirms the flicker
/// sequence. Prints one line per channel report as it is accepted or rejected.
const bool _channelReportTrace = true;

void _traceChannelReport(ChannelEvent event, String outcome) {
  if (!_channelReportTrace || !kDebugMode) return;
  final report = switch (event) {
    CloudReport(:final report) => report,
    LocalReport(:final report) => report,
    SocketUpdate(:final report) => report,
    _ => null,
  };
  final source = switch (event) {
    CloudReport() => 'cloud',
    LocalReport() => 'local',
    SocketUpdate() => 'socket',
    _ => '?',
  };
  // ignore: avoid_print — Step-1 on-device flicker trace (see _channelReportTrace)
  print('[CHANNEL REDUCE] source=$source state=${report?.state} '
      'updatedAt=${report?.updatedAt?.toIso8601String()} -> $outcome');
}

ReduceResult<ChannelState> _applyReport(
  ChannelState state,
  ChannelEvent event,
  ChannelReducerConfig config,
  DateTime now,
) {
  final ChannelReport report;
  final DeviceTransportSource source;
  final String? opId;
  switch (event) {
    case CloudReport():
      report = event.report;
      source = DeviceTransportSource.cloud;
      opId = null;
    case LocalReport():
      report = event.report;
      source = DeviceTransportSource.local;
      opId = null;
    case SocketUpdate():
      report = event.report;
      source = DeviceTransportSource.cloud;
      opId = event.opId;
    default:
      throw StateError('unreachable');
  }

  final incomingTs = report.updatedAt ?? now;

  // UNIFIED SocketUpdate priority rule (replaces the scattered
  // `alreadyResolved` + Phase 3/3b checks): a socket event whose opId matches
  // the in-flight op is a valid backend ACK and resolves the pending tap even
  // when the acceptance rules below would reject the report as stale. This
  // must run BEFORE the acceptance rules so an old-updatedAt MQTT ACK is never
  // swallowed by the serverTs / fresh-local guards.
  final isSocket = event is SocketUpdate;
  final opIdMatch = isSocket &&
      report.state != null &&
      opId != null &&
      state.pending &&
      opId == state.opId;
  if (opIdMatch) {
    _traceChannelReport(event, 'ACCEPT (opIdMatch, resolves pending)');
    final effects = <FollowUp>[
      report.state == 'ON' ? FollowUp.rippleOn : FollowUp.rippleOff,
      FollowUp.cancelPendingTimer,
    ];
    return ReduceResult(
      state.copyWith(
        reported: report.state,
        confirmedAt: incomingTs,
        serverTs: report.updatedAt,
        source: source,
        epoch: state.epoch + 1,
        pending: false,
        desired: null,
        clearDesired: true,
        showIndicator: false,
        tapEpoch: null,
        clearTapEpoch: true,
        opId: null,
        clearOpId: true,
      ),
      effects,
      committed: true,
    );
  }

  // UNKNOWN branch, ported verbatim: only meaningful when we have nothing
  // confirmed and nothing pending.
  if (report.state == null) {
    if (state.reported == null && !state.pending) {
      _traceChannelReport(event, 'ACCEPT (UNKNOWN, source-only)');
      final next = state.copyWith(
        source: source,
        confirmedAt: report.updatedAt ?? now,
        epoch: state.epoch + 1,
      );
      return ReduceResult(next, const [FollowUp.none]);
    }
    _traceChannelReport(event, 'REJECT (UNKNOWN while confirmed/pending)');
    return ReduceResult(state, const [FollowUp.none]);
  }

  if (source == DeviceTransportSource.cloud) {
    // A strictly older cloud report must never overwrite a newer one.
    if (state.serverTs != null &&
        report.updatedAt != null &&
        !report.updatedAt!.isAfter(state.serverTs!)) {
      _traceChannelReport(event, 'REJECT (older than serverTs)');
      return ReduceResult(state, const [FollowUp.none]);
    }
    // A fresh LAN read is the closest truth. A cloud report may only replace
    // it when the backend genuinely has newer (recent) information.
    final hasFreshLocal = state.source == DeviceTransportSource.local &&
        state.confirmedAt != null &&
        now.difference(state.confirmedAt!) < config.localHold;
    final cloudFresh = report.updatedAt == null ||
        now.difference(report.updatedAt!) < config.cloudFreshWindow;
    if (hasFreshLocal && !cloudFresh) {
      _traceChannelReport(event, 'REJECT (stale cloud vs fresh local)');
      return ReduceResult(state, const [FollowUp.none]);
    }
  } else {
    // Local is the freshest possible report; only a strictly-newer local read
    // may replace the current one (guards an older local read that lands
    // late).
    if (state.source == DeviceTransportSource.local &&
        state.confirmedAt != null &&
        incomingTs.isBefore(state.confirmedAt!)) {
      _traceChannelReport(event, 'REJECT (older local read)');
      return ReduceResult(state, const [FollowUp.none]);
    }
  }

  // Same-value guard (mirrors the ReachabilityState equality fix): an accepted
  // report that repeats the CURRENT verdict is a redundant re-signal — a LAN
  // tap's outcome is echoed by the REST response, the socket's device_update
  // telemetry, and the 15s poll. Skip the epoch bump and all effects so the
  // ripple pulse is never visibly re-triggered for a value that did not
  // change. A report that RESOLVES a still-pending tap is a meaningful
  // transition, so it is never suppressed here — but only a tap's confirmation
  // counts as resolution: the DESIRED value (the device flipped) or, for a
  // CLOUD-confirmed tap, any fresh socket report (the device may legitimately
  // refuse, so the socket is authority). A socket echo carrying the OLD
  // pre-tap value while a LAN-confirmed tap is pending is the stale pre-switch
  // tele/STATE — holding it lets the verified local REST read-back settle
  // truth. The freshness / rollback acceptance rules above are untouched —
  // this only stops redundant re-application on top of them.
  final resolvesPendingTap = isSocket &&
      state.pending &&
      (report.state == state.desired ||
          state.source != DeviceTransportSource.local);
  if (report.state == state.reported && !resolvesPendingTap) {
    _traceChannelReport(event, 'REJECT (same-value echo)');
    return ReduceResult(state, const [FollowUp.none]);
  }

  // Settle-window contradiction guard (FIX B): a socket telemetry echo that
  // CONTRADICTS a fresh LOCAL verdict shortly after it landed is a stale
  // pre-switch tele/STATE delivered late (MQTT has no cross-topic ordering
  // guarantee), not device truth. Hold it — the verified local read, or a
  // second echo once the settle window lapses, re-establishes the real value.
  // Only applies while NOT pending: a pending tap expects value-change socket
  // reports as its confirmation, and the verified local REST read-back settles
  // the verdict. Scoped to sockets; a local contradiction is always real.
  final freshLocalContradiction = isSocket &&
      state.reported != null &&
      report.state != state.reported &&
      !state.pending &&
      state.source == DeviceTransportSource.local &&
      state.confirmedAt != null &&
      now.difference(state.confirmedAt!) < kRelaySettleWindow;
  if (freshLocalContradiction) {
    _traceChannelReport(event, 'REJECT (contradictory socket in settle window)');
    return ReduceResult(state, const [FollowUp.none]);
  }

  final next = state.copyWith(
    reported: report.state,
    confirmedAt: incomingTs,
    serverTs: (source == DeviceTransportSource.cloud && report.updatedAt != null)
        ? report.updatedAt
        : null,
    clearServerTs: source != DeviceTransportSource.cloud,
    source: source,
    epoch: state.epoch + 1,
  );
  final effects = <FollowUp>[
    report.state == 'ON' ? FollowUp.rippleOn : FollowUp.rippleOff,
  ];

  if (isSocket && state.pending) {
    _traceChannelReport(event, 'ACCEPT (socket resolves pending)');
    // Phase 3: accepted real socket state is authoritative and resolves the
    // pending tap (its newer epoch beats the REST response).
    final resolved = next.copyWith(
      pending: false,
      desired: null,
      clearDesired: true,
      showIndicator: false,
      tapEpoch: null,
      clearTapEpoch: true,
      opId: null,
      clearOpId: true,
    );
    return ReduceResult(
      resolved,
      [...effects, FollowUp.cancelPendingTimer],
      committed: true,
    );
  }

  _traceChannelReport(event, 'ACCEPT (value change)');
  return ReduceResult(next, effects, committed: report.state != null);
}

ReduceResult<ChannelState> _applyRest(
  ChannelState state,
  RestResponse event,
  ChannelReducerConfig config,
  DateTime now,
) {
  // Whether a NEWER accepted report already landed after the tap (only when
  // epoch advanced past tapEpoch BEFORE this response). Captured first because
  // the pending resolution below would make tapEpoch disappear.
  final tap = state.tapEpoch;
  final tapPending = state.pending;
  final noNewerSinceTap = tap != null && state.epoch == tap;

  // Always resolve the op lifecycle: the REST response finishes the command.
  var next = state;
  final effects = <FollowUp>[FollowUp.cancelPendingTimer];
  if (state.pending) {
    next = state.copyWith(
      pending: false,
      desired: null,
      clearDesired: true,
      showIndicator: false,
      tapEpoch: null,
      clearTapEpoch: true,
      opId: null,
      clearOpId: true,
    );
  }

  final report = event.report;
  var committed = false;
  if (report != null) {
    // Honor the transport that actually answered: a local control response is
    // a LOCAL report (never mislabeled cloud), a cloud one stays CloudReport.
    // Correct `source` metadata keeps the hasFreshLocal guard meaningful.
    final applied = _applyReport(
      next,
      event.source == DeviceTransportSource.local
          ? LocalReport(report) as ChannelEvent
          : CloudReport(report, deviceOnline: event.online) as ChannelEvent,
      config,
      now,
    );
    next = applied.state;
    committed = applied.committed;
    // The inner report may flip the ripple (an accepted REST report is the
    // device's real state), so its effects must reach the view too.
    effects.addAll(applied.effects);
  }

  // Ambiguous REST: the changed channel did not come back with a confirmed
  // report. Reconcile by re-reading ONLY when no accepted report arrived after
  // the tap (removes the unconditional `_fetchStatus(silent:true)`).
  final reportUnknown = report == null || report.state == null;
  if (reportUnknown && tapPending && noNewerSinceTap) {
    effects.add(FollowUp.reconcilePoll);
  }
  return ReduceResult(next, effects, committed: committed);
}

ReduceResult<ChannelState> _applyTimeout(ChannelState state, Timeout event) {
  if (!state.pending) {
    return ReduceResult(state, const [FollowUp.none]);
  }
  // The command failed and no newer report resolved it: degrade to UNKNOWN
  // (never fabricate OFF), matching the old catch path.
  final next = state.copyWith(
    reported: null,
    clearReported: true,
    source: null,
    clearSource: true,
    confirmedAt: null,
    clearConfirmedAt: true,
    desired: null,
    clearDesired: true,
    pending: false,
    showIndicator: false,
    tapEpoch: null,
    clearTapEpoch: true,
    opId: null,
    clearOpId: true,
  );
  return ReduceResult(next, const [FollowUp.cancelPendingTimer, FollowUp.rippleOff]);
}

// ─────────────────────────────────────────────────────────────
// Device connectivity reducer
// ─────────────────────────────────────────────────────────────

ReduceResult<DeviceConnectivityState> deviceReduce(
  DeviceConnectivityState state,
  ChannelEvent event,
  ChannelReducerConfig config, {
  required DateTime now,
}) {
  switch (event) {
    case LocalReport():
      // A verified local report is always positive liveness evidence.
      return ReduceResult(
        state.copyWith(
          connectivity: Connectivity.online,
          offlineKind: OfflineKind.none,
          lastDeviceEvidenceAt: now,
          lastLocalEvidenceAt: now,
          pollFailures: 0,
        ),
        const [FollowUp.none],
      );
    case CloudReport():
      return _applyCloudVerdict(state, event.report, event.deviceOnline, config, now);
    case SocketUpdate():
      // A committed device state OR a device_status online event is positive
      // liveness evidence (the view only forwards committed channel updates).
      final isOnline = event.deviceOnline || event.report.state != null;
      if (!isOnline) {
        return ReduceResult(state, const [FollowUp.none]);
      }
      return ReduceResult(
        state.copyWith(
          connectivity: Connectivity.online,
          offlineKind: OfflineKind.none,
          lastDeviceEvidenceAt: now,
          pollFailures: 0,
        ),
        const [FollowUp.none],
      );
    case LwtOffline():
      return _applyLwtOffline(state, event.at);
    case PollFailure():
      return _applyPollFailure(state, config);
    case CloudHealth():
      return ReduceResult(
        state.copyWith(cloud: event.reachability),
        const [FollowUp.none],
      );
    default:
      // UserTap / RestResponse / Timeout carry no device verdict on their own.
      return ReduceResult(state, const [FollowUp.none]);
  }
}

ReduceResult<DeviceConnectivityState> _applyCloudVerdict(
  DeviceConnectivityState state,
  ChannelReport report,
  bool online,
  ChannelReducerConfig config,
  DateTime now,
) {
  if (online) {
    // Positive device evidence.
    return ReduceResult(
      state.copyWith(
        connectivity: Connectivity.online,
        offlineKind: OfflineKind.none,
        lastDeviceEvidenceAt: now,
        pollFailures: 0,
      ),
      const [FollowUp.none],
    );
  }
  // Ported _applyResult verbatim for a weak cloud "offline" verdict.
  final freshLocal = state.lastLocalEvidenceAt != null &&
      now.difference(state.lastLocalEvidenceAt!) < config.localHold;
  final recentEvidence = _hasRecentDeviceEvidence(state, config, now);
  if (freshLocal || recentEvidence) {
    // A stale/contradicted verdict must never kill a live local session or a
    // recently-confirmed device.
    return ReduceResult(
      state.copyWith(
        connectivity: Connectivity.online,
        offlineKind: OfflineKind.none,
        pollFailures: 0,
      ),
      const [FollowUp.none],
    );
  }
  if (state.lastDeviceEvidenceAt != null) {
    // Confirmed before but no recent evidence + authoritative offline verdict.
    return ReduceResult(
      state.copyWith(
        connectivity: Connectivity.offline,
        offlineKind: OfflineKind.none,
      ),
      const [FollowUp.none],
    );
  }
  // No confirmed device evidence yet: SYNCING, never a fabricated OFFLINE.
  return ReduceResult(
    state.copyWith(connectivity: Connectivity.syncing),
    const [FollowUp.none],
  );
}

ReduceResult<DeviceConnectivityState> _applyLwtOffline(
  DeviceConnectivityState state,
  DateTime at,
) {
  // Authoritative device-offline evidence; may only be superseded by positive
  // device evidence that is strictly NEWER (ported _hasRecentDeviceEvidence
  // ordering).
  final last = state.lastDeviceEvidenceAt;
  if (last != null && last.isAfter(at)) {
    return ReduceResult(state, const [FollowUp.none]);
  }
  return ReduceResult(
    state.copyWith(
      connectivity: Connectivity.offline,
      offlineKind: OfflineKind.lwt,
      lastAuthoritativeOfflineAt: at,
    ),
    const [FollowUp.none],
  );
}

ReduceResult<DeviceConnectivityState> _applyPollFailure(
  DeviceConnectivityState state,
  ChannelReducerConfig config,
) {
  final failures = state.pollFailures + 1;
  if (failures >= config.maxPollFailures) {
    return ReduceResult(
      state.copyWith(
        connectivity: Connectivity.offline,
        offlineKind: OfflineKind.pollExhausted,
        pollFailures: failures,
      ),
      const [FollowUp.none],
    );
  }
  // A single failure is NOT offline evidence (flicker guard).
  return ReduceResult(
    state.copyWith(pollFailures: failures),
    const [FollowUp.none],
  );
}

// Ported `_hasRecentDeviceEvidence` (:296): recent positive device evidence
// that is NEWER than the last authoritative LWT Offline.
bool _hasRecentDeviceEvidence(
  DeviceConnectivityState state,
  ChannelReducerConfig config,
  DateTime now,
) {
  final last = state.lastDeviceEvidenceAt;
  if (last == null) return false;
  if (now.difference(last) >= config.evidenceFreshWindow) return false;
  final offline = state.lastAuthoritativeOfflineAt;
  return offline == null || last.isAfter(offline);
}

// ─────────────────────────────────────────────────────────────
// Derived view helpers
// ─────────────────────────────────────────────────────────────

/// Whether the badge should read "LAN" (Online styling, cloud confirmed down,
/// fresh local evidence). Ported from `_StatusPill` (showLan).
bool showLanBadge(
  DeviceConnectivityState state,
  ChannelReducerConfig config,
  DateTime now,
) {
  final freshLocal = state.lastLocalEvidenceAt != null &&
      now.difference(state.lastLocalEvidenceAt!) < config.localHold;
  return state.connectivity == Connectivity.online &&
      state.cloud == CloudReachability.down &&
      freshLocal;
}

/// Evaluates cloud reachability from the socket's live signal. The socket
/// connects when the backend is reachable and disconnects on a confirmed
/// outage, so the badge and the local-evidence holder can derive from it
/// directly. The old `stale` tier is gone: taps route by same-WiFi detection,
/// and a connected-but-quiet socket is still reachable.
CloudReachability evaluateCloudReachability({required bool socketConnected}) =>
    socketConnected ? CloudReachability.up : CloudReachability.down;

/// Routes a tap by NETWORK, not by cloud reachability. Same WiFi → direct
/// local control (the device is reachable on the phone's subnet). Otherwise the
/// cloud is the only path that can reach the device — UNLESS the cloud socket is
/// not ready (mid-reconnect after a network change): firing a known-unready
/// cloud call first would waste a timeout, so the tap starts on the LAN and the
/// repository's single-fallback safety net still gets a cloud chance if the LAN
/// misses. Ambiguous same-WiFi detection (no cached IP, probe timeout, identity
/// mismatch) is `false` → the safe cloud default when the socket is ready.
ControlRoute routingPolicy({
  required bool sameWifi,
  bool cloudSocketReady = true,
}) {
  if (sameWifi) return ControlRoute.localOnly;
  if (!cloudSocketReady) return ControlRoute.localOnly;
  return ControlRoute.cloudOnly;
}