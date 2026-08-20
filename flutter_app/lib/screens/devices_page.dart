import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/channel_state_machine.dart';
import '../services/control_timeline.dart';
import '../services/device_repository_service.dart';
import '../services/device_transport.dart';
import '../services/local_device_cache.dart';
import '../services/provisioning_service.dart';
import '../services/reachability_monitor.dart';
import '../main.dart' show kServerIp, kProtocol, channels, ChannelConfig;
import '../widgets/stees_widgets.dart';
import 'add_device_screen.dart';

/// Device-level connectivity, kept SEPARATE from Socket.IO transport state.
/// `online` requires recent confirmed device evidence; `offline` requires
/// authoritative LWT Offline or repeated failure evidence; everything else is
/// SYNCING. A socket drop or a single failed poll must never flip the pill
/// offline by itself. The verdicts and per-channel states are computed by the
/// pure reducers in `channel_state_machine.dart`; this State only owns the
/// timers, ripples, and transport calls those reducers ask for via [FollowUp].
class DevicesPage extends StatefulWidget {
  final ValueChanged<int> onNavigateToTab;
  const DevicesPage({super.key, required this.onNavigateToTab})
      : testRepository = null,
        testSocketFactory = null,
        testHealthCheck = null,
        testApi = null,
        testMonitor = null;

  /// Test seam: injects a fake repository / socket connector / cloud health
  /// probe so widget tests exercise the relay gate and cloud→local fallback
  /// without network.
  @visibleForTesting
  const DevicesPage.test({
    super.key,
    required this.onNavigateToTab,
    this.testRepository,
    this.testSocketFactory,
    this.testHealthCheck,
    this.testApi,
    this.testMonitor,
  });

  final DeviceRepositoryService? testRepository;
  final io.Socket Function(String url, Map<String, dynamic> options)?
      testSocketFactory;
  final Future<bool> Function()? testHealthCheck;
  final ApiService? testApi;

  /// Injected reachability monitor so widget tests can drive background
  /// same-WiFi/cloud readiness state directly (network-change debounce,
  /// badge reactivity) without touching a real probe.
  final ReachabilityMonitor? testMonitor;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final DeviceRepositoryService _repository =
      widget.testRepository ?? DeviceRepositoryService();
  late final ApiService _api = widget.testApi ?? ApiService();

  /// Continuous background reachability source for routing. Taps READ this live
  /// state (near-zero latency, no fresh probe); the monitor is fed by the
  /// existing socket events, the 15s status poll, lifecycle resumes, and
  /// network-change notifications.
  late final ReachabilityMonitor _monitor =
      widget.testMonitor ?? ReachabilityMonitor(_repository);
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  bool _loadError = false;
  String? _selectedDeviceId;
  int _deviceChannels = 4;
  // True while the authenticated DELETE (Delete Device) is in flight. Guards
  // against duplicate taps / duplicate DELETE requests.
  bool _deleting = false;

  io.Socket? _socket;

  // Fast cloud-failure detection. Socket.IO is the live real-time cloud signal,
  // but its disconnect detection can take 10-20s+ after Internet drops while
  // the phone stays on Wi-Fi. A lightweight bounded /api/health probe catches
  // the same outage in a couple of seconds so the LAN fallback probe starts
  // immediately instead of waiting for the socket's own timeout.
  static const Duration _cloudHealthInterval = Duration(seconds: 5);
  static const int _cloudHealthConfirmFailures = 2;
  static const Duration _cloudHealthRecheckDelay = Duration(milliseconds: 400);
  Timer? _cloudHealthTimer;
  bool _cloudHealthInFlight = false;
  int _cloudHealthFailures = 0;

  late final Future<bool> Function() _healthCheck =
      widget.testHealthCheck ?? ApiService().checkHealth;

  // CLOUD reachability, driven by the Socket.IO cloud monitor (the socket is
  // the app's live signal that the backend is reachable). Initialized `true` so
  // an unknown, still-connecting state keeps the safe cloud-first default; it
  // is only flipped `false` on a confirmed disconnect / connect error.
  bool _socketConnected = true;

  // The pure-machine device verdict (badge + routing input). All writes flow
  // through `_dispatchDevice`.
  DeviceConnectivityState _deviceState = const DeviceConnectivityState();

  // Reducer configuration, mapped from the previous page constants.
  final ChannelReducerConfig _config = ChannelReducerConfig(
    localHold: kLocalReportHold,
    cloudFreshWindow: _kCloudFreshWindow,
    evidenceFreshWindow: _kDeviceEvidenceFreshWindow,
    pendingIndicatorDelay: kRelayPendingIndicatorDelay,
    maxPollFailures: _maxPollFailures,
    pollBackoff: const Duration(seconds: 5),
    offlineDebounce: const Duration(seconds: 10),
  );

  // A cloud poll that reports the device offline is weak evidence: it may only
  // flip the card when the device has NOT produced positive evidence within
  // this window (and that evidence is newer than the last authoritative LWT
  // Offline). Mirrors _kCloudFreshWindow so a device that reports at least this
  // often is never flapped by a stale/contradicted backend verdict.
  static const Duration _kDeviceEvidenceFreshWindow = Duration(minutes: 5);

  static const int _maxPollFailures = 3;

  // A cloud report whose backend updatedAt is older than this is considered
  // stale and can never overwrite a fresh LAN read.
  static const Duration _kCloudFreshWindow = Duration(minutes: 5);

  /// Delay before showing the visual pending/loading indicator.
  /// If the command confirms (via Socket.IO or HTTP) before this delay,
  /// the user never sees the heavy loading state.
  static const Duration kRelayPendingIndicatorDelay =
      Duration(milliseconds: 200);

  Timer? _statusTimer;

  /// Debounces the BADGE's visual representation of ReachabilityState. Rapid
  /// writes during a network transition (socket drop → local-status result →
  /// socket reconnect → debounced probe) collapse into one render. Routing
  /// (_toggle:757) never touches this: it reads the live state directly.
  Timer? _badgeSettleTimer;

  final List<ChannelState> _channelStates =
      List.generate(4, (_) => const ChannelState());
  final List<bool> _channelLoading = [false, false, false, false];
  final List<bool> _showPendingIndicator = [false, false, false, false];
  final Set<String> _pendingRelays = {};
  final List<AnimationController> _rippleControllers = [];
  final List<AnimationController> _entranceControllers = [];

  bool _statusInFlight = false;

  // device:channel -> opId of the command currently in flight, so a socket
  // device_update for that relay can be correlated to its tap for the
  // end-to-end timing timeline.
  final Map<String, String> _inFlightOps = {};

  // device:channel -> Timer for delayed pending indicator. Allows cancellation
  // if the command resolves before the delay elapses.
  final Map<String, Timer> _pendingIndicatorTimers = {};

  bool get _isOnline => _deviceState.connectivity == Connectivity.online;
  bool get _isOffline => _deviceState.connectivity == Connectivity.offline;

  /// The single controlled writer for CHANNEL state: runs the pure reducer and
  /// applies its [FollowUp] hints (pending-indicator timers, ripples, reconcile
  /// poll). `reported` is only ever written by an accepted device report inside
  /// the reducer — never directly by the view. Returns the reduce result so
  /// callers can inspect `committed`.
  ReduceResult<ChannelState> _dispatchChannel(
      int index, ChannelEvent event, DateTime now) {
    if (index < 0 || index >= _deviceChannels) {
      return ReduceResult(const ChannelState(), const [FollowUp.none]);
    }
    final r = channelReduce(_channelStates[index], event, _config, now: now);
    final previousReported = _channelStates[index].reported;
    _channelStates[index] = r.state;
    _applyChannelEffects(
      index,
      event,
      r.effects,
      previousReported: previousReported,
      newReported: r.state.reported,
    );
    setState(() {});
    return r;
  }

  /// The single controlled writer for DEVICE connectivity state.
  void _dispatchDevice(ChannelEvent event, DateTime now) {
    final r = deviceReduce(_deviceState, event, _config, now: now);
    _deviceState = r.state;
    setState(() {});
  }

  /// Applies the reducer's follow-up hints for a channel event. Timers, ripples
  /// and reconcile polls are view concerns — the reducer never starts them.
  /// [previousReported]/[newReported] let the ripple guard tell a genuine value
  /// change from a redundant same-value re-signal.
  void _applyChannelEffects(
    int index,
    ChannelEvent event,
    List<FollowUp> effects, {
    String? previousReported,
    String? newReported,
  }) {
    final channel = index + 1;
    final key = '$_selectedDeviceId:$channel';
    final opId = switch (event) {
      UserTap() => event.opId,
      SocketUpdate() => event.opId,
      _ => null,
    };
    for (final f in effects) {
      switch (f) {
        case FollowUp.startPendingTimer:
          final t = Timer(_config.pendingIndicatorDelay, () {
            if (!mounted) return;
            if (_pendingRelays.contains(key) && _inFlightOps[key] == opId) {
              setState(() {
                _channelLoading[index] = true;
                _showPendingIndicator[index] = true;
              });
              if (opId != null) {
                ControlTimeline.mark(opId, _selectedDeviceId!, channel,
                    'Pending indicator shown');
              }
            }
          });
          _pendingIndicatorTimers[key] = t;
        case FollowUp.cancelPendingTimer:
          _pendingIndicatorTimers[key]?.cancel();
          _pendingIndicatorTimers.remove(key);
          if (_channelLoading[index] || _showPendingIndicator[index]) {
            setState(() {
              _channelLoading[index] = false;
              _showPendingIndicator[index] = false;
            });
          }
        case FollowUp.rippleOn:
          // Belt-and-suspenders on top of the reducer's same-value guard:
          // never restart an already-pulsing ripple for a report that did not
          // change the channel's reported value (a restart would visibly
          // re-trigger the pulse, the original LAN-tap flicker).
          final redundantRestart = _rippleControllers[index].isAnimating &&
              previousReported == newReported;
          if (!redundantRestart) {
            _rippleControllers[index].repeat(reverse: true);
          }
        case FollowUp.rippleOff:
          _rippleControllers[index].stop();
          _rippleControllers[index].reset();
        case FollowUp.reconcilePoll:
          _fetchStatus(silent: true);
        case FollowUp.none:
          break;
      }
    }
  }

  /// Applies a full status result: one device verdict plus every channel report
  /// the transport returned. Channels in [skipChannels] are left to the caller
  /// (the REST response already applied them).
  void _applyStatusResult(RelayStatusResult result, {Set<int>? skipChannels}) {
    final now = DateTime.now();
    final isLocal = result.source == DeviceTransportSource.local;
    // Feed the reachability monitor with zero extra probes: a local source
    // proves same-network reachability, a cloud source means the LAN could not
    // reach the device.
    final id = _selectedDeviceId;
    if (id != null) _monitor.noteStatusResult(id, result.source);
    _dispatchDevice(
      isLocal
          ? LocalReport(const ChannelReport(null)) as ChannelEvent
          : CloudReport(const ChannelReport(null), deviceOnline: result.online)
              as ChannelEvent,
      now,
    );
    for (final e in result.channels.entries) {
      if (skipChannels?.contains(e.key) ?? false) continue;
      _dispatchChannel(
        e.key - 1,
        isLocal
            ? LocalReport(e.value) as ChannelEvent
            : CloudReport(e.value, deviceOnline: result.online) as ChannelEvent,
        now,
      );
    }
  }

  /// Re-evaluates cloud reachability from transport facts and feeds the result
  /// into the device reducer as a [CloudHealth] event (only on change). Also
  /// folds the socket fact into the reachability monitor so tap-time routing
  /// sees the same live signal.
  void _refreshCloudReachability() {
    if (!mounted) return;
    _monitor.setCloudSocketReady(_socketConnected);
    final now = DateTime.now();
    final reach = evaluateCloudReachability(socketConnected: _socketConnected);
    if (reach != _deviceState.cloud) {
      _dispatchDevice(CloudHealth(reach), now);
    }
  }

  // Stops every ripple so an OFF channel is never left animating.
  void _stopRipples() {
    for (final c in _rippleControllers) {
      c.stop();
      c.reset();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (int i = 0; i < 4; i++) {
      _rippleControllers.add(
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        ),
      );
      _entranceControllers.add(
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: 400 + i * 100),
        )..forward(),
      );
    }
    _loadDevices();
    _connectSocket();
    _startCloudHealthMonitor();
    // Badge reactivity: rebuild whenever the background reachability changes so
    // LAN/Online reflects the live routing mode without requiring a tap.
    _monitor.state.addListener(_onReachabilityChanged);
    _statusTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        _refreshCloudReachability();
        _fetchStatus(silent: true); // its result also refreshes reachability
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _badgeSettleTimer?.cancel();
    _cloudHealthTimer?.cancel();
    _cloudHealthTimer = null;
    _monitor.state.removeListener(_onReachabilityChanged);
    _monitor.dispose();
    // Cancel all pending indicator timers.
    for (final timer in _pendingIndicatorTimers.values) {
      timer.cancel();
    }
    _pendingIndicatorTimers.clear();
    for (final c in _rippleControllers) {
      c.dispose();
    }
    for (final c in _entranceControllers) {
      c.dispose();
    }
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  void _onReachabilityChanged() {
    if (!mounted) return;
    // UI-only settle: the badge re-renders only after ReachabilityState has
    // been stable for [kBadgeSettleDelay], so a burst of writes during a
    // transition shows ONE badge change instead of a flicker per write. This
    // does NOT delay routing — _toggle reads `_monitor.state.value` live.
    _badgeSettleTimer?.cancel();
    _badgeSettleTimer = Timer(kBadgeSettleDelay, () {
      _badgeSettleTimer = null;
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _startCloudHealthMonitor();
      // The network may have changed while the app was backgrounded: re-probe
      // same-WiFi (debounced) so routing/badge reflect the new network fast.
      _monitor.notifyNetworkChanged(_selectedDeviceId);
      _syncAfterReconnect();
    } else if (state != AppLifecycleState.resumed) {
      // Pause the fast reachability probe in the background: it exists to make
      // the ONLINE → LAN transition fast while the user is looking, not to burn
      // battery/network while the app is hidden. The 15s status poll stays as-is.
      _cloudHealthTimer?.cancel();
      _cloudHealthTimer = null;
    }
  }

  Future<void> _loadDevices() async {
    // Cold-start progressive load: render the persisted local device list at
    // once (bounded, best-effort) so the card structure and the local-first
    // status probe are NEVER gated behind the cloud API timeout — the page must
    // not wait for the full cloud timeout before attempting LAN. The cloud list
    // remains the authoritative source and replaces this render when it
    // arrives; an empty/failed cache simply falls through to the cloud path.
    try {
      final cached = await _repository
          .cachedDevices()
          .timeout(const Duration(seconds: 2));
      if (mounted && cached.isNotEmpty && _devices.isEmpty) {
        setState(() {
          _devices = cached.cast<Map<String, dynamic>>().toList();
          _loading = false;
          _loadError = false;
        });
        if (_selectedDeviceId == null) {
          _selectDevice(_devices.first['deviceId'] as String);
        }
        // Warm up verified IPs so the LAN probe is fast; discovery stays
        // single-flight per device and never blocks the UI. Devices that warm
        // up as referer-gated (SO128 off) are repaired afterwards (see the
        // repository helper) so an already-registered pre-SO128 box regains
        // local control without being re-claimed.
        unawaited(_warmUpDevices(_devices));
      }
    } catch (_) {
      // Storage unavailable: fall through to the normal cloud path.
    }

    try {
      // The repository serves the registered list cloud-first and falls back
      // to the local cache on availability failures, so a cloud outage never
      // blanks the page or breaks Local Mode discovery.
      final devices = await _repository.getDevices();
      if (mounted) {
        setState(() {
          _devices = devices.cast<Map<String, dynamic>>().toList();
          _loading = false;
          _loadError = false;
        });
        if (_selectedDeviceId == null && _devices.isNotEmpty) {
          _selectDevice(_devices.first['deviceId'] as String);
        } else if (_selectedDeviceId != null &&
            _devices.isNotEmpty &&
            !_devices.any((d) => d['deviceId'] == _selectedDeviceId)) {
          // The authoritative list no longer contains the device selected from
          // the cached render (e.g. removed elsewhere): fall back to the first
          // registered device instead of pointing at a phantom.
          _selectDevice(_devices.first['deviceId'] as String);
        }
      }
      // Background local discovery warm-up so relay taps use a verified IP
      // instead of waiting on mDNS. Never blocks the UI.
      unawaited(_warmUpDevices(_devices));
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          // Distinguish "could not load" from "nothing to show": an empty
          // device list is a happy state, a failed fetch needs a retry.
          _loadError = _devices.isEmpty;
        });
      }
    }
  }

  /// Background local warm-up for every registered device (cached verified IP
  /// first, then bounded mDNS). Never blocks the UI and is safe to re-run
  /// (warm-up is single-flight per device). Old-device SO128 repair was
  /// deliberately removed: only the claim flow enables local HTTP control.
  Future<void> _warmUpDevices(List<Map<String, dynamic>> devices) async {
    try {
      await _repository.warmUp(devices);
    } catch (e) {
      debugPrint('[DEVICES] warm-up failed: $e');
    }
  }

  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    _loadDevices();
  }

  void _selectDevice(String deviceId) {
    final device = _devices.firstWhere(
      (d) => d['deviceId'] == deviceId,
      orElse: () => _devices.first,
    );
    setState(() {
      _selectedDeviceId = deviceId;
      _deviceChannels = device['channels'] as int? ?? 4;
    });
    // Switch context fully: previous device's states and animations must not
    // leak into the newly selected device's grid. Channels start UNKNOWN
    // (never a fabricated OFF) until the next report. The DEVICE verdict is
    // kept across selections (matches the pre-refactor behavior).
    for (int i = 0; i < 4; i++) {
      _channelStates[i] = const ChannelState();
      _channelLoading[i] = false;
      _showPendingIndicator[i] = false;
    }
    _stopRipples();
    _refreshCloudReachability();
    // Reset the reachability verdict for the newly selected device so the next
    // tap never reuses the previous device's same-WiFi result.
    _monitor.selectDevice(deviceId);
    _fetchStatus();
  }

  Map<String, dynamic> _getDevice(String deviceId) {
    return _devices.firstWhere(
      (d) => d['deviceId'] == deviceId,
      orElse: () => _devices.first,
    );
  }

  int get _activeCount {
    var n = 0;
    for (int i = 0; i < _deviceChannels; i++) {
      if (_channelStates[i].reported == 'ON') n++;
    }
    return n;
  }

  void _connectSocket() {
    _connectSocketAsync();
  }

  Future<void> _connectSocketAsync() async {
    final token = await AuthService().getToken();
    final socketFactory = widget.testSocketFactory ?? io.io;
    _socket = socketFactory('$kProtocol://$kServerIp', <String, dynamic>{
      'transports': ['websocket'],
      'secure': true,
      'autoConnect': false,
      if (token != null) 'auth': <String, dynamic>{'token': token},
    });

    _socket?.onConnect((_) {
      _socketConnected = true;
      _refreshCloudReachability();
      // The socket reconnected, usually because the network path changed:
      // re-probe same-WiFi (debounced) so routing follows the new network.
      _monitor.notifyNetworkChanged(_selectedDeviceId);
      // Reconnect: reconcile instead of waiting for the next 15s poll.
      _syncAfterReconnect();
      if (mounted) setState(() {});
    });
    _socket?.onDisconnect((_) {
      final cloudWasUp = _socketConnected;
      _socketConnected = false;
      _refreshCloudReachability();
      if (cloudWasUp) {
        // First confirmed cloud outage of this drop: probe the verified LAN IP
        // immediately so the badge can flip to LAN without waiting for the next
        // 15s poll. Repeated events are skipped (already down) and _fetchStatus
        // has its own single-flight guard, so no duplicate probes are spawned.
        _probeLocalAfterCloudDown();
      }
      if (mounted) setState(() {});
    });
    _socket?.onConnectError((_) {
      final cloudWasUp = _socketConnected;
      _socketConnected = false;
      _refreshCloudReachability();
      if (cloudWasUp) {
        _probeLocalAfterCloudDown();
      }
      if (mounted) setState(() {});
    });

    // Live events are fire-and-forget wake-ups, never the sole source of
    // truth. Casts are guarded so a malformed payload can't crash the handler.
    _socket?.on('device_status', (data) {
      try {
        if (!mounted) return;
        final map = data as Map<String, dynamic>;
        final deviceId = map['deviceId'] as String?;
        if (deviceId != null && deviceId != _selectedDeviceId) return;
        final online = map['online'] == true;
        final now = DateTime.now();
        final freshLocal = _deviceState.lastLocalEvidenceAt != null &&
            now.difference(_deviceState.lastLocalEvidenceAt!) < kLocalReportHold;
        // A cloud status event must never overwrite a fresher local session.
        if (freshLocal) return;
        // The socket is delivering live events: the cloud is genuinely up.
        if (online) {
          // Positive device report: restore ONLINE.
          _dispatchDevice(
              SocketUpdate(const ChannelReport(null), deviceOnline: true), now);
        } else {
          // Explicit MQTT LWT Offline — authoritative device-offline evidence.
          _dispatchDevice(LwtOffline(now), now);
        }
        _refreshCloudReachability();
        setState(() {});
      } catch (_) {
        // Ignore malformed event; polling re-establishes truth.
      }
    });

    _socket?.on('device_update', (data) {
      try {
        if (!mounted) return;
        final map = data as Map<String, dynamic>;
        final deviceId = map['deviceId'] as String?;
        if (deviceId != null && deviceId != _selectedDeviceId) return;
        final channel = map['channel'] as int;
        final state = map['state'] as String?;
        DateTime? updatedAt;
        final ua = map['updatedAt'];
        if (ua is String) updatedAt = DateTime.tryParse(ua);
        // FIX A: only the BACKEND's correlated opId counts as a tap ACK. The
        // backend echoes the app's opId (via /api/control → MQTT RESULT) for
        // cloud-routed commands, and null for LAN-routed ones (no backend
        // pending exists). Stamping the app's own _inFlightOps opId onto EVERY
        // channel echo made stale telemetry look like the command's own
        // confirmation — never do that. A LAN tap is instead confirmed by its
        // verified local REST read-back (LocalDeviceTransport UNCONFIRMED).
        final backendOpId = map['opId'] as String?;
        if (backendOpId != null) {
          ControlTimeline.mark(backendOpId, _selectedDeviceId!, channel,
              'Socket.IO received (device_update)');
        }
        final report =
            ChannelReport(state == 'UNKNOWN' ? null : state, updatedAt: updatedAt);
        final now = DateTime.now();
        final r = _dispatchChannel(
          channel - 1,
          SocketUpdate(report, opId: backendOpId),
          now,
        );
        // A committed device report is strong liveness evidence (the device
        // demonstrably talked to MQTT and produced a real state) — restore
        // ONLINE even if the paired `device_status` event is delayed or lost.
        if (r.committed) {
          _dispatchDevice(SocketUpdate(report, deviceOnline: false), now);
        }
        _refreshCloudReachability();
        setState(() {});
      } catch (_) {
        // Ignore malformed event; polling re-establishes truth.
      }
    });

    _socket?.connect();
  }

  // Reconnect / resume / post-load reconciliation: refresh local availability
  // in the background and re-fetch fresh state through the single writer, so a
  // stale response can never win.
  void _syncAfterReconnect() {
    if (!mounted) return;
    _refreshCloudReachability();
    _fetchStatus(silent: true);
    unawaited(_warmUpDevices(_devices));
  }

  // On a confirmed cloud outage, immediately re-read status through the normal
  // LOCAL-ONLY known-endpoint path. The repository ladder runs first and
  // unchanged — warm in-memory endpoint, then the persisted verified IP, then a
  // cloud-learned candidate (identity-verified with `Status 5`), then mDNS —
  // so an already-known, verified IP is probed directly with NO discovery
  // window. `cloudDown` also stops the read from falling through to the cloud,
  // which is confirmed unreachable and would otherwise burn up to the 15s API
  // timeout before the LAN fallback could resolve. Failures simply fall back to
  // the existing poll / repeated-failure-threshold behavior; the socket
  // reconnect restores cloud priority as usual.
  void _probeLocalAfterCloudDown() {
    if (!mounted || _selectedDeviceId == null) return;
    _fetchStatus(silent: true, cloudDown: true);
  }

  // ──────────────────────────────────────────────────────────────
  // Fast cloud-failure detection (complements Socket.IO)
  // ──────────────────────────────────────────────────────────────

  void _startCloudHealthMonitor() {
    _cloudHealthTimer?.cancel();
    _cloudHealthTimer = Timer.periodic(_cloudHealthInterval, (_) {
      _checkCloudHealth();
    });
  }

  /// Bounded reachability probe. Never overlaps itself and only flips the cloud
  /// state to down on CONSECUTIVE failures (flicker guard). Recovery stays
  /// socket-driven: the socket's own reconnect (`onConnect`) restores the
  /// cloud-connected state and Online immediately — it never waits for the 15s
  /// poll or `kLocalReportHold`, so this probe needs no restore path of its own.
  Future<void> _checkCloudHealth() async {
    if (!mounted || _cloudHealthInFlight) return;
    _cloudHealthInFlight = true;
    try {
      final ok = await _healthCheck();
      if (!mounted) return;
      if (ok) {
        _cloudHealthFailures = 0;
        return;
      }
      if (!_socketConnected) return; // already down; the socket confirms recovery
      _cloudHealthFailures++;
      if (_cloudHealthFailures >= _cloudHealthConfirmFailures) {
        // Confirmed by consecutive failures: mark the cloud down NOW and start
        // the existing LAN probe immediately — no socket timeout wait.
        _cloudHealthFailures = 0;
        _confirmCloudDown();
      } else {
        // A single transient failure is weak evidence: re-probe shortly so a
        // genuine outage is confirmed within ~2s while a lone packet blip is
        // filtered out.
        Timer(_cloudHealthRecheckDelay, _checkCloudHealth);
      }
    } finally {
      _cloudHealthInFlight = false;
    }
  }

  /// The single place the health monitor flips the cloud state to down. Shares
  /// the exact same follow-up as a socket disconnect: immediate LAN probe, no
  /// duplicate when the socket later notices the same outage on its own.
  void _confirmCloudDown() {
    if (!mounted || !_socketConnected) return;
    _socketConnected = false;
    _cloudHealthFailures = 0;
    _refreshCloudReachability();
    _probeLocalAfterCloudDown();
    if (mounted) setState(() {});
  }

  Future<void> _fetchStatus({bool silent = false, bool cloudDown = false}) async {
    if (_selectedDeviceId == null) return;
    if (_statusInFlight) return; // overlapping-poll guard
    _statusInFlight = true;
    try {
      final result = await _repository.getStatus(
        _selectedDeviceId!,
        cloudDown: cloudDown,
      );
      if (!mounted) return;
      _applyStatusResult(result);
    } catch (e) {
      if (mounted) {
        if (!silent) _showError('Failed to fetch status');
        // A single failed poll is NOT device-offline evidence (flicker guard).
        // Only repeated consecutive failures count as strong evidence, and
        // that threshold lives inside the device reducer.
        _dispatchDevice(PollFailure(DateTime.now()), DateTime.now());
      }
    } finally {
      _statusInFlight = false;
    }
  }

  Future<void> _toggle(int channel, bool targetState) async {
    if (_selectedDeviceId == null) return;
    // No connectivity gate here: the repository owns reachability. This lets a
    // tap reach the transport layer so the local-first path can run; the card
    // visuals still reflect the device verdict.
    final key = '$_selectedDeviceId:$channel';
    if (_pendingRelays.contains(key)) return;
    final index = channel - 1;
    final opId = ControlTimeline.begin(_selectedDeviceId!, channel);
    final now = DateTime.now();

    _inFlightOps['$_selectedDeviceId:$channel'] = opId;
    _pendingRelays.add(key);
    // Optimistic visual flip: the card reflects the requested state at tap
    // time; the first confirmed report via the reducer overwrites it and on
    // total failure the Timeout path degrades to UNKNOWN (never fabricated).
    if (targetState) {
      _rippleControllers[index].repeat(reverse: true);
    } else {
      _rippleControllers[index].stop();
      _rippleControllers[index].reset();
    }
    _dispatchChannel(index, UserTap(targetState, opId: opId), now);
    // Light haptic feedback for instant perceived responsiveness.
    HapticFeedback.lightImpact();
    ControlTimeline.mark(opId, _selectedDeviceId!, channel, 'Optimistic UI applied');

    // Route the tap by the CONTINUOUSLY-maintained reachability state, not a
    // fresh probe: the background monitor already re-checked on network changes,
    // socket events, and the 15s heartbeat, so this read is instant and the
    // value is the current network reality — no probe wait on the tap path.
    // same WiFi → direct local control (no cloud round-trip); otherwise →
    // cloud-only (no LAN attempt). Any ambiguity (unknown state, stale for a
    // different device) defaults to cloud, the safe reachable-by-default path.
    final reach = _monitor.state.value;
    final sameWifi =
        _monitor.deviceId == _selectedDeviceId && reach.sameWifi;
    final route = routingPolicy(
      sameWifi: sameWifi,
      cloudSocketReady: reach.cloudSocketReady,
    );
    ControlTimeline.mark(
        opId,
        _selectedDeviceId!,
        channel,
        route == ControlRoute.localOnly
            ? 'Routing: local-only (same WiFi)'
            : 'Routing: cloud-only');

    try {
      final result = await _repository.control(
        _selectedDeviceId!,
        channel,
        targetState ? 'ON' : 'OFF',
        opId: opId,
        route: route,
      );
      if (!mounted) {
        ControlTimeline.end(opId);
        return;
      }
      ControlTimeline.mark(opId, _selectedDeviceId!, channel,
          'HTTP response received');
      // The socket may already have confirmed this relay: then pending is
      // already resolved and this REST response only finishes the lifecycle,
      // never re-enables pending or regresses the confirmed state.
      final alreadyResolved = !_channelStates[index].pending;
      _dispatchChannel(
        index,
        RestResponse(
          channel,
          report: result.channels[channel],
          online: result.online,
          source: result.source,
        ),
        DateTime.now(),
      );
      _applyStatusResult(result, skipChannels: {channel});
      ControlTimeline.mark(
          opId,
          _selectedDeviceId!,
          channel,
          alreadyResolved
              ? 'REST completed (already resolved)'
              : 'Pending cleared (HTTP)');
      if (!alreadyResolved) {
        ControlTimeline.mark(opId, _selectedDeviceId!, channel,
            'UI confirmed (REST)');
      }
    } catch (e) {
      if (!mounted) {
        ControlTimeline.end(opId);
        return;
      }
      ControlTimeline.mark(opId, _selectedDeviceId!, channel, 'Command failed');
      final msg = e.toString().replaceFirst('Exception: ', '');
      // If the command failed but a newer device report already arrived
      // (socket confirmed), pending is resolved so the Timeout is a no-op and
      // the UI already shows the truth. Otherwise Timeout degrades to UNKNOWN.
      final socketConfirmed = !_channelStates[index].pending;
      _dispatchChannel(index, Timeout(channel), DateTime.now());
      if (socketConfirmed) {
        // The device already confirmed a newer state (e.g. via tele/STATE)
        // while the REST wait timed out: the UI shows the truth, so a scary
        // error toast would contradict the confirmed state. Stay quiet.
        ControlTimeline.mark(opId, _selectedDeviceId!, channel,
            'REST failed but socket confirmed');
      } else {
        // Connectivity is NOT decided here: a single command failure is weak
        // evidence and the reconcile poll below re-establishes truth from the
        // device report (or the repeated-failure threshold).
        _showError(msg);
      }
      _fetchStatus(silent: true); // reconcile
    } finally {
      _inFlightOps.remove('$_selectedDeviceId:$channel');
      ControlTimeline.end(opId);
      _pendingRelays.remove(key);
      _pendingIndicatorTimers[key]?.cancel();
      _pendingIndicatorTimers.remove(key);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        margin: const EdgeInsets.all(AppSpacing.lg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _openAddDevice() async {
    // Refresh the PERSISTED account snapshot BEFORE the wizard can reach the
    // offline Tasmota AP: while the phone is still on its normal network, a
    // successful GET /api/devices (bounded) replaces the stored registered-MAC
    // set, so a later offline duplicate check inside the wizard is always
    // decided from fresh, persisted knowledge. Any failure keeps the last valid
    // snapshot — it must never be erased by a failed request.
    final cache = LocalDeviceCache();
    try {
      final devices = await _api.getDevices().timeout(kRegisteredCheckLimit);
      final normalized = devices
          .whereType<Map<String, dynamic>>()
          .toList();
      await cache.saveAccountSnapshot(normalized);
      await cache.replaceAll(normalized);
    } catch (_) {
      // Offline at entry (or transient error): the existing persisted snapshot
      // is kept, and the wizard itself re-attempts the refresh on open.
    }
    if (!mounted) return;
    final added = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const AddDeviceScreen()));
    if (added == true) _loadDevices();
  }

  // The selected device. Returns the first entry as a fallback so the delete
  // flow always addresses an actual device.
  Map<String, dynamic> get _selectedDevice =>
      _getDevice(_selectedDeviceId ?? _devices.first['deviceId']);

  // Confirm then delete the existing registration for the selected device from
  // the authenticated account. Re-claiming happens through the normal claim
  // flow afterwards, which re-checks the backend and finds the device gone.
  Future<void> _confirmDeleteDevice() async {
    if (_deleting) return;
    final colors = context.steesColors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Text('Delete Device',
            style: GoogleFonts.sora(
                fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam)),
        content: Text(
          'Are you sure you want to delete this device?\n'
          'You can claim it again after deletion.',
          style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete',
                style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _deleteDevice();
  }

  // Executes the authenticated DELETE, guarding against duplicate taps, then
  // drops the device from the local list and clears its Local Mode cache entry
  // so a later re-claim starts clean.
  Future<void> _deleteDevice() async {
    if (_deleting) return;
    final deviceId = _selectedDevice['deviceId'] as String?;
    if (deviceId == null || deviceId.isEmpty) return;
    setState(() => _deleting = true);
    DeleteOutcome outcome;
    try {
      await _api.deleteDevice(deviceId);
      outcome = classifyDeleteOutcome(succeeded: true);
    } on ApiException catch (e) {
      outcome = classifyDeleteOutcome(statusCode: e.statusCode);
      if (e.statusCode == 401) {
        // The shared ApiService.onUnauthorized handler already handles sign-out.
        // Keep the device; do not pretend deletion succeeded.
        if (mounted) {
          _showError('You appear to be signed out. Sign in again and retry.');
        }
        setState(() => _deleting = false);
        return;
      }
    } catch (_) {
      outcome = classifyDeleteOutcome();
    }
    if (!mounted) return;
    final colors = context.steesColors;
    if (outcome == DeleteOutcome.cleared) {
      // Removed (200) or already gone (404): drop the device locally, clear
      // its Local Mode cache entry, and remove its canonical MAC from the
      // persisted account snapshot so a re-claim is treated as a new device.
      await LocalDeviceCache().remove(deviceId);
      await LocalDeviceCache().removeFromAccountSnapshot(deviceId);
      if (!mounted) return;
      setState(() {
        _devices.removeWhere((d) => d['deviceId'] == deviceId);
        if (_selectedDeviceId == deviceId) _selectedDeviceId = null;
        if (_devices.isNotEmpty) {
          _selectedDeviceId ??= _devices.first['deviceId'] as String;
        } else {
          _loading = false;
          _loadError = false;
        }
        _deleting = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Device deleted.',
              style: const TextStyle(fontSize: 13)),
          backgroundColor: colors.stream,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md)),
          margin: const EdgeInsets.all(AppSpacing.lg),
          duration: const Duration(seconds: 3),
        ));
    } else {
      // Network / timeout / server / unexpected failure: keep the device and
      // surface a retryable error. Never claim deletion succeeded.
      setState(() => _deleting = false);
      _showError('Could not delete the device. Check your connection and try '
          'again.');
    }
  }

  void _openSchedules() {
    widget.onNavigateToTab(2);
  }

  // Channel label/icon for any channel count. The 4-entry default palette
  // covers the common case; additional relays fall back to a generated entry so
  // a device claimed with more channels never indexes past the list.
  ChannelConfig _configFor(int index) {
    if (index < channels.length) return channels[index];
    return ChannelConfig(
      'Zone ${index + 1}',
      Icons.water_drop,
      const Color(0xFF0F766E),
      'CHANNEL ${index + 1}',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SteesLoading();
    if (_loadError) return _buildError(context.steesColors);
    if (_devices.isEmpty) return _buildEmpty(context.steesColors);
    return _buildDeviceView(context.steesColors);
  }

  Widget _buildError(SteesColors colors) {
    // Uses the shared error component so the failure state is visually
    // consistent with the rest of the app.
    return SteesError(
      title: 'Could not load devices',
      subtitle: 'Check your connection and try again.',
      onRetry: _retryLoad,
    );
  }

  Widget _buildEmpty(SteesColors colors) {
    return SteesEmpty(
      icon: Icons.water_drop_outlined,
      title: 'No devices yet',
      subtitle:
          'Claim a Sonoff controller to start\nmanaging your irrigation zones.',
      action: FilledButton.icon(
        onPressed: _openAddDevice,
        icon: const Icon(Icons.add, size: 18),
        label: Text(
          'Add Device',
          style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: colors.stream,
          foregroundColor: colors.well,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceView(SteesColors colors) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPageTitle(colors),
          _buildDeviceRow(colors),
          const SizedBox(height: AppSpacing.lg),
          _buildHeroCard(colors),
          const SizedBox(height: AppSpacing.lg),
          _buildGridHeader(colors),
          const SizedBox(height: AppSpacing.md),
          _buildRelayGrid(),
          const SizedBox(height: AppSpacing.lg),
          _buildBottomActions(colors),
        ],
      ),
    );
  }

  Widget _buildPageTitle(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.sm,
      ),
      child: Text(
        'DEVICES',
        style: GoogleFonts.sora(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.8,
          color: colors.mist,
        ),
      ),
    );
  }

  Widget _buildDeviceRow(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(child: _buildSelectorList(colors)),
          const SizedBox(width: AppSpacing.sm),
          _buildAddButton(colors),
        ],
      ),
    );
  }

  Widget _buildSelectorList(SteesColors colors) {
    if (_devices.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _devices.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (_, i) {
          final d = _devices[i];
          final id = d['deviceId'] as String;
          final name = d['name'] as String;
          final ch = d['channels'] as int? ?? 4;
          final selected = id == _selectedDeviceId;
          return GestureDetector(
            onTap: () => _selectDevice(id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                color: colors.submerged,
                border: Border.all(
                  color: selected
                      ? colors.stream.withValues(alpha: 0.6)
                      : colors.border,
                  width: selected ? 1.5 : 1,
                ),
                boxShadow: [AppShadows.cardShadow(colors.border)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.memory,
                    size: 14,
                    color: selected ? colors.stream : colors.mist,
                  ),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Text(
                    '$name · $ch',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? colors.foam : colors.mist,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddButton(SteesColors colors) {
    return GestureDetector(
      onTap: _openAddDevice,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.stream.withValues(alpha: 0.1),
          border: Border.all(color: colors.stream.withValues(alpha: 0.4)),
        ),
        child: Icon(Icons.add, size: 18, color: colors.stream),
      ),
    );
  }

  Widget _buildHeroCard(SteesColors colors) {
    final device = _getDevice(
      _selectedDeviceId ?? _devices.first['deviceId'] as String,
    );
    final name = device['name'] as String? ?? _selectedDeviceId ?? '';
    final channelsCount = device['channels'] as int? ?? _deviceChannels;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.submerged, colors.surface],
        ),
        border: Border.all(
          color: _isOnline
              ? colors.stream.withValues(alpha: 0.25)
              : colors.border,
        ),
        boxShadow: [AppShadows.cardShadow(colors.border)],
      ),
      child: Row(
        children: [
          _HeroIcon(connected: _isOnline),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.foam,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  // When the device is unreachable the flowing count is not
                  // live truth (it is only the last-known relay states), so the
                  // summary stops implying current flow and shows zones alone.
                  _isOnline
                      ? '$channelsCount zones · $_activeCount flowing'
                      : '$channelsCount zones',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.mist,
                  ),
                ),
              ],
            ),
          ),
          _StatusPill(
            online: _deviceState.connectivity == Connectivity.online,
            offline: _deviceState.connectivity == Connectivity.offline,
            lan: showLanBadge(_deviceState, _config, DateTime.now()) ||
                // The badge reflects the ACTUAL transport routingPolicy will
                // use for a tap (see _toggle:757-763): same-WiFi → local
                // control → LAN, regardless of the cloud socket. Routing and
                // badge always agree — a stable same-WiFi session with the
                // cloud up is controlled locally and shows LAN, never ONLINE.
                (_monitor.deviceId == _selectedDeviceId &&
                    _monitor.state.value.sameWifi),
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            onPressed: _deleting ? null : _confirmDeleteDevice,
            tooltip: 'Delete Device',
            icon: _deleting
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: colors.danger),
                  )
                : Icon(Icons.delete_outline,
                    size: 20, color: colors.mist),
          ),
        ],
      ),
    );
  }

  Widget _buildGridHeader(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Row(
        children: [
          Text(
            'ZONES',
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.8,
              color: colors.mist,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surfaceLight,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              '$_deviceChannels',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: colors.mist,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelayGrid() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: _deviceChannels == 1 ? 1 : 2,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: _deviceChannels == 1 ? 1.4 : 1.15,
        children: List.generate(
          _deviceChannels,
          (i) => _WaterCard(
            index: i,
            channel: i + 1,
            config: _configFor(i),
            reported: _channelStates[i].reported,
            desired: _channelStates[i].desired,
            pending: _channelStates[i].pending,
            loading: _channelLoading[i],
            showPendingIndicator: _showPendingIndicator[i],
            offline: _isOffline,
            entrance: _entranceControllers[i],
            ripple: _rippleControllers[i],
            onToggle: (val) => _toggle(i + 1, val),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomActions(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _openSchedules,
          icon: const Icon(Icons.schedule, size: 16),
          label: Text(
            'Schedules',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.foam,
            side: BorderSide(color: colors.stream.withValues(alpha: 0.35)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroIcon extends StatelessWidget {
  final bool connected;
  const _HeroIcon({required this.connected});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected
              ? [
                  colors.stream.withValues(alpha: 0.25),
                  colors.leaf.withValues(alpha: 0.05),
                ]
              : [colors.submerged, colors.surface],
        ),
        border: Border.all(
          color: connected
              ? colors.stream.withValues(alpha: 0.35)
              : colors.border,
        ),
      ),
      child: Icon(
        connected ? Icons.water_drop : Icons.water_drop_outlined,
        size: 22,
        color: connected ? colors.stream : colors.mist,
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool online;

  /// Authoritative device-offline verdict (LWT or repeated poll failures).
  final bool offline;

  /// Local Mode badge: Online styling + the transport routingPolicy will use
  /// for a tap (same-WiFi → local control) or, for the cloud-down case, fresh
  /// local evidence. Never derived from "the last request ran on the LAN".
  final bool lan;

  const _StatusPill({
    required this.online,
    required this.offline,
    required this.lan,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final isOnline = online;
    final color = isOnline ? colors.leaf : colors.mist;
    final label = lan
        ? 'LAN'
        : isOnline
            ? 'Online'
            : offline
                ? 'Offline'
                : 'SYNCING';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: isOnline
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.35),
                        blurRadius: 3,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.sora(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Water Card (relay control)
// ──────────────────────────────────────────────────────────────

class _WaterCard extends AnimatedWidget {
  final int index;
  final int channel;
  final ChannelConfig config;
  final String? reported;
  final String? desired;
  final bool pending;
  final bool loading;
  final bool showPendingIndicator;
  final bool offline;
  final AnimationController entrance;
  final AnimationController ripple;
  final ValueChanged<bool> onToggle;

  const _WaterCard({
    required this.index,
    required this.channel,
    required this.config,
    required this.reported,
    required this.desired,
    required this.pending,
    required this.loading,
    required this.showPendingIndicator,
    required this.offline,
    required this.entrance,
    required this.ripple,
    required this.onToggle,
  }) : super(listenable: entrance);

  @override
  Widget build(BuildContext context) {
    final scale = Curves.easeOutBack.transform(entrance.value);
    return Transform.scale(
      scale: scale,
      child: _WaterCardBody(
        channel: channel,
        config: config,
        reported: reported,
        desired: desired,
        pending: pending,
        loading: loading,
        showPendingIndicator: showPendingIndicator,
        offline: offline,
        ripple: ripple,
        onToggle: onToggle,
      ),
    );
  }
}

class _WaterCardBody extends StatefulWidget {
  final int channel;
  final ChannelConfig config;
  final String? reported;
  final String? desired;
  final bool pending;
  final bool loading;
  final bool showPendingIndicator;
  final bool offline;
  final AnimationController ripple;
  final ValueChanged<bool> onToggle;

  const _WaterCardBody({
    required this.channel,
    required this.config,
    required this.reported,
    required this.desired,
    required this.pending,
    required this.loading,
    required this.showPendingIndicator,
    required this.offline,
    required this.ripple,
    required this.onToggle,
  });

  @override
  State<_WaterCardBody> createState() => _WaterCardBodyState();
}

class _WaterCardBodyState extends State<_WaterCardBody>
    with SingleTickerProviderStateMixin {
  late AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final isOn = widget.pending
        ? widget.desired == 'ON'
        : widget.reported == 'ON';
    final isUnknown = widget.reported == null;
    final colors = context.steesColors;
    // The heavy visual loading indicator (spinner, opacity, disabled) is driven
    // by showPendingIndicator, which only becomes true after a delay if the
    // command is still in flight. The pending flag tracks the command lifecycle
    // for optimistic state and _pendingRelays guard.
    final showLoading = widget.showPendingIndicator;
    // Only showLoading disables taps: offline/unknown cards stay tappable so the
    // local-first path can run when the socket/backend is down. Offline still
    // renders grey via widget.offline below.
    final disabled = showLoading;

    return GestureDetector(
      onTapDown: disabled ? null : (_) => _press.forward(),
      onTapUp: disabled
          ? null
          : (_) {
              _press.reverse();
              widget.onToggle(!isOn);
            },
      onTapCancel: () => _press.reverse(),
      child: AnimatedScale(
        scale: 1.0 - _press.value * 0.03,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          opacity: showLoading ? 0.6 : (widget.offline ? 0.72 : 1.0),
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              color: widget.offline
                  ? colors.submerged.withValues(alpha: 0.5)
                  : colors.submerged,
              border: Border.all(
                color: widget.offline
                    ? colors.mist.withValues(alpha: 0.5)
                    : isOn
                        ? colors.leaf
                        : colors.border,
                width: widget.offline ? 1 : (isOn ? 1.2 : 1),
              ),
              boxShadow: [AppShadows.cardShadow(colors.border)],
            ),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      c.subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.1,
                        color: widget.offline
                            ? colors.mist.withValues(alpha: 0.6)
                            : colors.mist,
                      ),
                    ),
                    _DropletToggle(
                      isOn: isOn,
                      loading: showLoading,
                      disabled: widget.offline,
                      activeColor: colors.leaf,
                      onTap: disabled ? null : () => widget.onToggle(!isOn),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 34,
                      child: Center(
                        child: widget.offline
                            ? Icon(
                                c.icon,
                                size: 30,
                                color: isOn
                                    ? colors.leaf.withValues(alpha: 0.6)
                                    : colors.mist.withValues(alpha: 0.35),
                              )
                            : _RippleIcon(
                                icon: c.icon,
                                size: 30,
                                color: isOn
                                    ? colors.leaf
                                    : colors.mist.withValues(alpha: 0.45),
                                ripple: widget.ripple,
                              ),
                      ),
                    ),
                  ],
                ),
                _buildStatusPill(colors, isOn, isUnknown, widget.pending, widget.desired),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill(
      SteesColors colors, bool isOn, bool isUnknown, bool pending, String? desired) {
    // When a command is in flight (pending), immediately show the intended
    // direction so the user sees TURNING ON/OFF without waiting for the
    // 200ms delayed loading indicator. The confirmed state (FLOWING/DRY)
    // is shown once pending clears.
    if (pending) {
      final turningOn = desired == 'ON';
      return _SyncPill(
        label: turningOn ? 'TURNING ON…' : 'TURNING OFF…',
        color: colors.stream,
      );
    }
    // Not pending: show confirmed state as before.
    if (widget.showPendingIndicator) {
      return _SyncPill(label: 'TURNING…', color: colors.stream);
    }
    if (widget.reported == null) {
      // UNKNOWN is never rendered as OFF. Connected+unknown → syncing;
      // otherwise the device is unreachable.
      return widget.offline ? const _OfflineBadge() : _SyncPill(label: 'SYNCING', color: colors.mist);
    }
    final confirmedIsOn = widget.reported == 'ON';
    return _FlowPill(isOn: confirmedIsOn, color: colors.leaf);
  }
}

class _RippleIcon extends AnimatedWidget {
  final IconData icon;
  final Color color;
  final double size;
  const _RippleIcon({
    required this.icon,
    required this.color,
    required AnimationController ripple,
    this.size = 24,
  }) : super(listenable: ripple);

  @override
  Widget build(BuildContext context) {
    final ctrl = listenable as AnimationController;
    final scale = 1.0 + ctrl.value * 0.08;
    final opacity = 0.6 + ctrl.value * 0.4;
    final ring = size + 12;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (ctrl.value > 0.1)
          Transform.scale(
            scale: 1.0 + ctrl.value * 0.4,
            child: Opacity(
              opacity: (1.0 - ctrl.value) * 0.25,
              child: Container(
                width: ring,
                height: ring,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                ),
              ),
            ),
          ),
        Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: Icon(icon, size: size, color: color),
          ),
        ),
      ],
    );
  }
}

class _DropletToggle extends StatelessWidget {
  final bool isOn;
  final bool loading;
  final bool disabled;
  final Color activeColor;
  final VoidCallback? onTap;

  const _DropletToggle({
    required this.isOn,
    required this.loading,
    required this.activeColor,
    this.disabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return GestureDetector(
      // `disabled` here is purely visual (grey when offline). Taps always
      // reach the repository so the local-first path can run while offline.
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: 36,
        height: 21,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: disabled
              ? colors.surfaceLight.withValues(alpha: 0.5)
              : isOn
                  ? activeColor
                  : colors.surfaceLight,
        ),
        padding: const EdgeInsets.all(2.5),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: disabled
                  ? colors.mist.withValues(alpha: 0.4)
                  : isOn
                      ? colors.well
                      : colors.mist.withValues(alpha: 0.5),
            ),
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: isOn ? activeColor : colors.mist,
                      ),
                    )
                  : Icon(
                      isOn ? Icons.water_drop : Icons.water_drop_outlined,
                      size: 9,
                      color: disabled
                          ? colors.mist.withValues(alpha: 0.4)
                          : isOn
                              ? activeColor
                              : colors.well,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.mist.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 9, color: colors.mist.withValues(alpha: 0.8)),
          const SizedBox(width: 4),
          Text(
            'OFFLINE',
            style: GoogleFonts.sora(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: colors.mist.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncPill extends StatelessWidget {
  final String label;
  final Color color;
  const _SyncPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sync, size: 9, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.sora(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowPill extends StatelessWidget {
  final bool isOn;
  final Color color;
  const _FlowPill({required this.isOn, required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final bg = isOn ? color.withValues(alpha: 0.14) : colors.surfaceLight;
    final fg = isOn ? color : colors.mist.withValues(alpha: 0.7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(shape: BoxShape.circle, color: fg),
          ),
          const SizedBox(width: 4),
          Text(
            isOn ? 'FLOWING' : 'DRY',
            style: GoogleFonts.sora(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
