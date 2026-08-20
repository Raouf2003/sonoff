import 'package:flutter_test/flutter_test.dart' hide Timeout;
import 'package:smart_home_app/services/channel_state_machine.dart';
import 'package:smart_home_app/services/device_transport.dart';

// Fixed wall clock for determinism. All relative timestamps derive from it.
final t0 = DateTime(2026, 1, 1, 12, 0, 0);

const config = ChannelReducerConfig(
  localHold: Duration(seconds: 30),
  cloudFreshWindow: Duration(minutes: 5),
  evidenceFreshWindow: Duration(minutes: 5),
  pendingIndicatorDelay: Duration(milliseconds: 400),
  maxPollFailures: 3,
  pollBackoff: Duration(seconds: 5),
  offlineDebounce: Duration(seconds: 10),
);

ChannelReport rep(String? state, {DateTime? updatedAt}) =>
    ChannelReport(state, updatedAt: updatedAt);

Matcher unchanged(ChannelState state) => equals(state);

void main() {
  group('UserTap', () {
    test('arms pending, desired, tapEpoch, opId and requests the indicator',
        () {
      final r = channelReduce(const ChannelState(), const UserTap(true, opId: 'o1'),
          config, now: t0);
      expect(r.effects, [FollowUp.startPendingTimer]);
      expect(r.state.pending, isTrue);
      expect(r.state.desired, 'ON');
      expect(r.state.tapEpoch, 0);
      expect(r.state.opId, 'o1');
      expect(r.state.reported, isNull, reason: 'no optimistic-UI desync');
    });

    test('second tap while pending is ignored (single-flight)', () {
      final armed = channelReduce(const ChannelState(), const UserTap(false, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(armed, const UserTap(true, opId: 'o2'), config, now: t0);
      expect(r.effects, [FollowUp.none]);
      expect(r.state, unchanged(armed));
    });
  });

  group('CloudReport acceptance', () {
    test('strictly newer cloud report is accepted and bumps epoch', () {
      var s = channelReduce(const ChannelState(), CloudReport(rep('ON', updatedAt: t0)),
          config, now: t0).state;
      final r = channelReduce(
          s, CloudReport(rep('OFF', updatedAt: t0.add(const Duration(seconds: 1)))),
          config,
          now: t0.add(const Duration(seconds: 2)));
      expect(r.effects, [FollowUp.rippleOff]);
      expect(r.state.reported, 'OFF');
      expect(r.state.epoch, s.epoch + 1);
      expect(r.state.serverTs, t0.add(const Duration(seconds: 1)));
      expect(r.state.source, DeviceTransportSource.cloud);
      expect(r.committed, isTrue);
    });

    test('cloud report older than serverTs is rejected', () {
      final base = channelReduce(
          const ChannelState(), CloudReport(rep('ON', updatedAt: t0)),
          config,
          now: t0).state;
      final r = channelReduce(
          base, CloudReport(rep('OFF', updatedAt: t0.subtract(const Duration(seconds: 5)))),
          config,
          now: t0.add(const Duration(seconds: 10)));
      expect(r.state, unchanged(base));
      expect(r.committed, isFalse);
    });

    test('stale cloud report cannot overwrite a fresh local read', () {
      final base = channelReduce(const ChannelState(), LocalReport(rep('ON', updatedAt: t0)),
          config, now: t0).state;
      // 10 s later (local still fresh within 30 s hold), cloud claims a 10-min-old value.
      final r = channelReduce(
          base,
          CloudReport(rep('OFF', updatedAt: t0.subtract(const Duration(minutes: 10)))),
          config,
          now: t0.add(const Duration(seconds: 10)));
      expect(r.state, unchanged(base));
    });

    test('fresh cloud report may replace a stale local read', () {
      final base = channelReduce(const ChannelState(), LocalReport(rep('ON', updatedAt: t0)),
          config, now: t0).state;
      final later = t0.add(const Duration(seconds: 45)); // outside 30 s localHold
      final r = channelReduce(
          base, CloudReport(rep('OFF', updatedAt: later)),
          config,
          now: later);
      expect(r.state.reported, 'OFF');
      expect(r.state.source, DeviceTransportSource.cloud);
    });

    test('UNKNOWN cloud report never clears a confirmed value', () {
      final base = channelReduce(
          const ChannelState(), CloudReport(rep('ON', updatedAt: t0)),
          config,
          now: t0).state;
      final r = channelReduce(
          base, CloudReport(rep(null, updatedAt: t0.add(const Duration(minutes: 1)))),
          config,
          now: t0.add(const Duration(minutes: 1)));
      expect(r.state, unchanged(base));
    });

    test('UNKNOWN report on an empty non-pending channel records source only',
        () {
      final r = channelReduce(const ChannelState(),
          CloudReport(rep(null, updatedAt: t0)),
          config,
          now: t0);
      expect(r.state.reported, isNull);
      expect(r.state.source, DeviceTransportSource.cloud);
      expect(r.state.epoch, 1);
    });

    test('UNKNOWN report while pending is ignored', () {
      final armed = channelReduce(const ChannelState(), const UserTap(true, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(armed, CloudReport(rep(null, updatedAt: t0)), config, now: t0);
      expect(r.state, unchanged(armed));
    });
  });

  group('LocalReport acceptance', () {
    test('strictly newer local read is accepted', () {
      final base = channelReduce(
          const ChannelState(), LocalReport(rep('ON', updatedAt: t0)),
          config,
          now: t0).state;
      final r = channelReduce(
          base, LocalReport(rep('OFF', updatedAt: t0.add(const Duration(seconds: 3)))),
          config,
          now: t0.add(const Duration(seconds: 3)));
      expect(r.state.reported, 'OFF');
      expect(r.state.serverTs, isNull, reason: 'local clears cloud serverTs');
    });

    test('older local read landing late is rejected', () {
      final base = channelReduce(
          const ChannelState(), LocalReport(rep('ON', updatedAt: t0.add(const Duration(seconds: 9)))),
          config,
          now: t0.add(const Duration(seconds: 9))).state;
      final r = channelReduce(
          base, LocalReport(rep('OFF', updatedAt: t0)),
          config,
          now: t0.add(const Duration(seconds: 9)));
      expect(r.state, unchanged(base));
    });
  });

  group('SocketUpdate', () {
    test('opId match resolves the pending tap even when the report would be '
        'rejected as stale', () {
      // Cloud confirmed ON at t0; tap OFF afterwards.
      final base = channelReduce(
          const ChannelState(), CloudReport(rep('ON', updatedAt: t0)),
          config,
          now: t0).state;
      final armed = channelReduce(
          base, const UserTap(false, opId: 'o1'),
          config,
          now: t0.add(const Duration(seconds: 1))).state;
      // Socket ACK with an OLD updatedAt (before serverTs) but matching opId.
      final r = channelReduce(
          armed,
          SocketUpdate(rep('OFF', updatedAt: t0.subtract(const Duration(seconds: 1))),
              opId: 'o1'),
          config,
          now: t0.add(const Duration(seconds: 2)));
      expect(r.state.pending, isFalse);
      expect(r.state.desired, isNull);
      expect(r.state.tapEpoch, isNull);
      expect(r.state.reported, 'OFF');
      expect(r.effects, contains(FollowUp.cancelPendingTimer));
      expect(r.committed, isTrue);
    });

    test('matching opId never resolves to UNKNOWN', () {
      final armed = channelReduce(const ChannelState(), const UserTap(true, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(armed, SocketUpdate(rep(null), opId: 'o1'), config, now: t0);
      expect(r.state.pending, isTrue);
      expect(r.state, unchanged(armed));
    });

    test('accepted socket state resolves the pending tap (Phase 3)', () {
      final armed = channelReduce(const ChannelState(), const UserTap(false, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(
          armed, SocketUpdate(rep('OFF', updatedAt: t0), deviceOnline: true),
          config,
          now: t0);
      expect(r.state.pending, isFalse);
      expect(r.state.reported, 'OFF');
      expect(r.state.desired, isNull);
      expect(r.committed, isTrue);
    });

    test('stale non-matching socket event does not resolve the pending tap', () {
      final base = channelReduce(
          const ChannelState(), CloudReport(rep('ON', updatedAt: t0)),
          config,
          now: t0).state;
      final armed = channelReduce(
          base, const UserTap(false, opId: 'o1'),
          config,
          now: t0.add(const Duration(seconds: 1))).state;
      final r = channelReduce(
          armed,
          SocketUpdate(rep('OFF', updatedAt: t0), opId: 'o2'),
          config,
          now: t0.add(const Duration(seconds: 2)));
      expect(r.state.pending, isTrue);
      expect(r.state.desired, 'OFF');
    });
  });

  group('RestResponse', () {
    test('ambiguous REST (no report) triggers a reconcile poll only when no '
        'newer accepted report landed since the tap', () {
      final armed = channelReduce(const ChannelState(), const UserTap(false, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(
          armed,
          const RestResponse(1, online: true, source: DeviceTransportSource.cloud),
          config,
          now: t0);
      expect(r.state.pending, isFalse);
      expect(r.effects, contains(FollowUp.reconcilePoll));
    });

    test('ambiguous REST does NOT poll when a socket commit landed first', () {
      final armed = channelReduce(const ChannelState(), const UserTap(false, opId: 'o1'),
          config, now: t0).state;
      final committed = channelReduce(
          armed, SocketUpdate(rep('OFF', updatedAt: t0), opId: 'o1'),
          config,
          now: t0).state;
      final r = channelReduce(
          committed,
          const RestResponse(1, online: true, source: DeviceTransportSource.cloud),
          config,
          now: t0);
      expect(r.effects, isNot(contains(FollowUp.reconcilePoll)));
      expect(r.state.reported, 'OFF');
    });

    test('REST with a real report applies it and does not poll', () {
      final armed = channelReduce(const ChannelState(), const UserTap(true, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(
          armed,
          RestResponse(1, report: rep('ON', updatedAt: t0), online: true,
              source: DeviceTransportSource.cloud),
          config,
          now: t0);
      expect(r.state.pending, isFalse);
      expect(r.state.reported, 'ON');
      expect(r.effects, isNot(contains(FollowUp.reconcilePoll)));
    });

    test('REST report ripple effects reach the view (accepted ON pulses)', () {
      final armed = channelReduce(const ChannelState(), const UserTap(true, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(
          armed,
          RestResponse(1, report: rep('ON', updatedAt: t0), online: true,
              source: DeviceTransportSource.cloud),
          config,
          now: t0);
      expect(r.effects, contains(FollowUp.rippleOn));

      final off = channelReduce(
          r.state,
          RestResponse(1, report: rep('OFF', updatedAt: t0.add(const Duration(seconds: 1))),
              online: true, source: DeviceTransportSource.cloud),
          config,
          now: t0.add(const Duration(seconds: 1)));
      expect(off.effects, contains(FollowUp.rippleOff));
    });
  });

  group('Timeout', () {
    test('degrades a pending channel to UNKNOWN (never fabricates OFF)', () {
      final armed = channelReduce(const ChannelState(), const UserTap(false, opId: 'o1'),
          config, now: t0).state;
      final r = channelReduce(armed, const Timeout(1), config, now: t0);
      expect(r.state.reported, isNull);
      expect(r.state.desired, isNull);
      expect(r.state.pending, isFalse);
      expect(r.state.opId, isNull);
      expect(r.effects, [FollowUp.cancelPendingTimer, FollowUp.rippleOff]);
    });

    test('idle channel is unaffected', () {
      final base = channelReduce(
          const ChannelState(), CloudReport(rep('ON', updatedAt: t0)),
          config,
          now: t0).state;
      final r = channelReduce(base, const Timeout(1), config, now: t0);
      expect(r.state, unchanged(base));
    });
  });

  group('No-desync invariant', () {
    test('reported is only ever set by an accepted device report', () {
      // Walk a full toggle cycle and assert reported never mirrors desired
      // without a device report.
      var s = const ChannelState();
      var reportedValues = <String?>[];
      var desiredWhilePending = <String?>[];

      s = channelReduce(s, const UserTap(true, opId: 'o1'), config, now: t0).state;
      reportedValues.add(s.reported);
      desiredWhilePending.add(s.desired);
      expect(s.reported, isNull);

      s = channelReduce(s, SocketUpdate(rep('ON', updatedAt: t0), opId: 'o1'), config,
          now: t0).state;
      reportedValues.add(s.reported);
      expect(s.reported, 'ON');

      s = channelReduce(s, const UserTap(false, opId: 'o2'), config,
          now: t0.add(const Duration(seconds: 1))).state;
      desiredWhilePending.add(s.desired);
      expect(s.reported, 'ON', reason: 'tap must not change reported');
      reportedValues.add(s.reported);

      s = channelReduce(s, RestResponse(1, report: rep('OFF', updatedAt: t0.add(const Duration(seconds: 1))),
          online: true, source: DeviceTransportSource.cloud), config,
          now: t0.add(const Duration(seconds: 1))).state;
      reportedValues.add(s.reported);
      expect(s.reported, 'OFF');
      expect(desiredWhilePending, ['ON', 'OFF']);
      expect(reportedValues, [null, 'ON', 'ON', 'OFF']);
    });
  });

  group('Device connectivity reducer', () {
    test('LocalReport is always positive liveness evidence', () {
      final r = deviceReduce(
          const DeviceConnectivityState(connectivity: Connectivity.offline),
          LocalReport(rep('ON', updatedAt: t0)),
          config,
          now: t0);
      expect(r.state.connectivity, Connectivity.online);
      expect(r.state.lastDeviceEvidenceAt, t0);
      expect(r.state.lastLocalEvidenceAt, t0);
      expect(r.state.pollFailures, 0);
    });

    test('cloud report with deviceOnline true is positive evidence', () {
      final r = deviceReduce(
          const DeviceConnectivityState(connectivity: Connectivity.offline),
          CloudReport(rep('ON', updatedAt: t0), deviceOnline: true),
          config,
          now: t0);
      expect(r.state.connectivity, Connectivity.online);
    });

    test('weak cloud offline verdict with fresh local stays ONLINE', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(s, LocalReport(rep('ON', updatedAt: t0)), config, now: t0).state;
      final r = deviceReduce(
          s, CloudReport(rep('ON', updatedAt: t0), deviceOnline: false),
          config,
          now: t0.add(const Duration(seconds: 5)));
      expect(r.state.connectivity, Connectivity.online);
    });

    test('weak cloud offline verdict with recent evidence stays ONLINE', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(
          s, SocketUpdate(rep('ON', updatedAt: t0), deviceOnline: true),
          config,
          now: t0).state;
      final r = deviceReduce(
          s, CloudReport(rep('ON', updatedAt: t0), deviceOnline: false),
          config,
          now: t0.add(const Duration(minutes: 2)));
      expect(r.state.connectivity, Connectivity.online);
    });

    test('weak cloud offline verdict with old evidence becomes OFFLINE', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(
          s, SocketUpdate(rep('ON', updatedAt: t0), deviceOnline: true),
          config,
          now: t0).state;
      final r = deviceReduce(
          s, CloudReport(rep('ON', updatedAt: t0), deviceOnline: false),
          config,
          now: t0.add(const Duration(minutes: 10)));
      expect(r.state.connectivity, Connectivity.offline);
    });

    test('weak cloud offline verdict with no evidence is SYNCING (never '
        'fabricated OFFLINE)', () {
      final r = deviceReduce(
          const DeviceConnectivityState(),
          CloudReport(rep('ON', updatedAt: t0), deviceOnline: false),
          config,
          now: t0);
      expect(r.state.connectivity, Connectivity.syncing);
    });

    test('LwtOffline is authoritative but loses to newer positive evidence', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(
          s, SocketUpdate(rep('ON', updatedAt: t0), deviceOnline: true),
          config,
          now: t0).state;
      // Evidence at t0 is OLDER than the LWT at t0+1min → LWT wins.
      final r = deviceReduce(s, LwtOffline(t0.add(const Duration(minutes: 1))), config,
          now: t0.add(const Duration(minutes: 1)));
      expect(r.state.connectivity, Connectivity.offline);
      expect(r.state.offlineKind, OfflineKind.lwt);

      // Newer evidence beats an earlier LWT.
      var s2 = const DeviceConnectivityState();
      s2 = deviceReduce(s2, LwtOffline(t0), config, now: t0).state;
      final r2 = deviceReduce(
          s2, SocketUpdate(rep('ON', updatedAt: t0.add(const Duration(minutes: 2))),
              deviceOnline: true),
          config,
          now: t0.add(const Duration(minutes: 2)));
      expect(r2.state.connectivity, Connectivity.online);
    });

    test('single poll failure is NOT offline evidence (flicker guard)', () {
      final r = deviceReduce(const DeviceConnectivityState(), PollFailure(t0), config,
          now: t0);
      expect(r.state.connectivity, Connectivity.syncing);
      expect(r.state.pollFailures, 1);
    });

    test('maxPollFailures exhaustion marks OFFLINE and resets on new evidence',
        () {
      var s = const DeviceConnectivityState();
      for (var i = 0; i < 2; i++) {
        s = deviceReduce(s, PollFailure(t0), config, now: t0).state;
      }
      expect(s.connectivity, isNot(Connectivity.offline));
      final exhausted = deviceReduce(s, PollFailure(t0), config, now: t0).state;
      expect(exhausted.connectivity, Connectivity.offline);
      expect(exhausted.offlineKind, OfflineKind.pollExhausted);

      final recovered = deviceReduce(
          exhausted, SocketUpdate(rep('ON', updatedAt: t0), deviceOnline: true),
          config,
          now: t0.add(const Duration(seconds: 1)));
      expect(recovered.state.connectivity, Connectivity.online);
      expect(recovered.state.pollFailures, 0);
      expect(recovered.state.offlineKind, OfflineKind.none);
    });

    test('CloudHealth updates cloud reachability', () {
      final r = deviceReduce(const DeviceConnectivityState(), CloudHealth(CloudReachability.down),
          config, now: t0);
      expect(r.state.cloud, CloudReachability.down);
    });

    test('UserTap/RestResponse/Timeout carry no device verdict', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(s, const UserTap(true), config, now: t0).state;
      s = deviceReduce(
          s, const RestResponse(1, online: true, source: DeviceTransportSource.cloud),
          config,
          now: t0).state;
      final r = deviceReduce(s, const Timeout(1), config, now: t0);
      expect(r.state.connectivity, Connectivity.syncing);
      expect(r.state, s);
    });
  });

  group('routingPolicy', () {
    test('up → cloudFirst', () {
      expect(routingPolicy(CloudReachability.up).order, RoutingOrder.cloudFirst);
      expect(routingPolicy(CloudReachability.up).probeLocal, isFalse);
    });

    test('down → localFirst', () {
      expect(routingPolicy(CloudReachability.down).order, RoutingOrder.localFirst);
      expect(routingPolicy(CloudReachability.down).probeLocal, isFalse);
    });

    test('stale → cloudFirst + probeLocal', () {
      final d = routingPolicy(CloudReachability.stale);
      expect(d.order, RoutingOrder.cloudFirst);
      expect(d.probeLocal, isTrue);
    });
  });

  group('evaluateCloudReachability', () {
    test('socket connected + recent status → up', () {
      expect(
        evaluateCloudReachability(
          socketConnected: true,
          socketEverConnected: true,
          hasVerifiedLocalIp: true,
          lastCloudStatusAt: t0,
          now: t0.add(const Duration(seconds: 5)),
          config: config,
        ),
        CloudReachability.up,
      );
    });

    test('socket connected + stale status → stale', () {
      expect(
        evaluateCloudReachability(
          socketConnected: true,
          socketEverConnected: true,
          hasVerifiedLocalIp: true,
          lastCloudStatusAt: t0,
          now: t0.add(const Duration(minutes: 6)),
          config: config,
        ),
        CloudReachability.stale,
      );
    });

    test('socket disconnected → down (even with fresh status)', () {
      expect(
        evaluateCloudReachability(
          socketConnected: false,
          socketEverConnected: true,
          hasVerifiedLocalIp: true,
          lastCloudStatusAt: t0,
          now: t0.add(const Duration(seconds: 1)),
          config: config,
        ),
        CloudReachability.down,
      );
    });
  });

  group('showLanBadge', () {
    test('online + cloud down + fresh local → true', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(s, LocalReport(rep('ON', updatedAt: t0)), config, now: t0).state;
      s = deviceReduce(s, CloudHealth(CloudReachability.down), config, now: t0).state;
      expect(
        showLanBadge(s, config, t0.add(const Duration(seconds: 5))),
        isTrue,
      );
    });

    test('stale local evidence → false', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(s, LocalReport(rep('ON', updatedAt: t0)), config, now: t0).state;
      s = deviceReduce(s, CloudHealth(CloudReachability.down), config, now: t0).state;
      expect(
        showLanBadge(s, config, t0.add(const Duration(minutes: 2))),
        isFalse,
      );
    });

    test('cloud not confirmed down → false', () {
      var s = const DeviceConnectivityState();
      s = deviceReduce(s, LocalReport(rep('ON', updatedAt: t0)), config, now: t0).state;
      expect(showLanBadge(s, config, t0), isFalse);
    });
  });
}