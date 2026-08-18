import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/control_timeline.dart';
import '../services/device_repository_service.dart';
import '../services/device_transport.dart';
import '../services/local_device_cache.dart';
import '../services/provisioning_service.dart';
import '../main.dart' show kServerIp, kProtocol, channels, ChannelConfig;
import '../widgets/stees_widgets.dart';
import 'add_device_screen.dart';

/// Device-level connectivity, kept SEPARATE from Socket.IO transport state.
/// `online` requires recent confirmed device evidence; `offline` requires
/// authoritative LWT Offline or repeated failure evidence; everything else is
/// `unknown` (SYNCING). A socket drop or a single failed poll must never flip
/// the pill offline by itself.
enum _DeviceConnectivity { online, unknown, offline }

/// Per-channel state on the devices page. `reported` is ONLY ever set from a
/// device report (local HTTP read-back, cloud MQTT report via socket/poll).
/// The user's tap only sets [desired] + [pending] until a report confirms it.
class _ChannelState {
  String? reported; // 'ON' / 'OFF' / null = UNKNOWN
  bool pending = false;
  String? desired; // last intent while awaiting confirmation
  DeviceTransportSource? source;
  DateTime? updatedAt; // receive time on the phone
  DateTime? serverTs; // backend per-channel updatedAt (cloud reports)
  int seq = 0; // bumped on every ACCEPTED report; rollback guard
}

class DevicesPage extends StatefulWidget {
  final ValueChanged<int> onNavigateToTab;
  const DevicesPage({super.key, required this.onNavigateToTab})
      : testRepository = null,
        testSocketFactory = null,
        testHealthCheck = null,
        testApi = null;

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
  });

  final DeviceRepositoryService? testRepository;
  final io.Socket Function(String url, Map<String, dynamic> options)?
      testSocketFactory;
  final Future<bool> Function()? testHealthCheck;
  final ApiService? testApi;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final DeviceRepositoryService _repository =
      widget.testRepository ?? DeviceRepositoryService();
  late final ApiService _api = widget.testApi ?? ApiService();
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

  // Whether the socket has EVER successfully connected. Used to allow instant
  // local control when the phone is on the same WiFi but has no internet —
  // the socket will never connect, but a verified local IP may be cached.
  bool _socketEverConnected = false;
  _DeviceConnectivity _connectivity = _DeviceConnectivity.unknown;

  // When the DEVICE last produced positive evidence (confirmed channel report,
  // online status/control result, or online socket event). Used to distinguish
  // "never seen / stale → SYNCING" from "confirmed before, now authoritative
  // offline → OFFLINE". This is device evidence, not socket/transport state.
  DateTime? _lastDeviceEvidenceAt;

  // When an EXPLICIT LWT Offline (`device_status` offline) was last seen. It is
  // authoritative device-offline evidence and may only be superseded by positive
  // device evidence that is strictly NEWER. A cloud poll's plain "offline"
  // verdict (weak/stale) can never undo it.
  DateTime? _lastAuthoritativeOfflineAt;

  // A cloud poll that reports the device offline is weak evidence: it may only
  // flip the card when the device has NOT produced positive evidence within
  // this window (and that evidence is newer than the last authoritative LWT
  // Offline). Mirrors _kCloudFreshWindow so a device that reports at least this
  // often is never flapped by a stale/contradicted backend verdict.
  static const Duration _kDeviceEvidenceFreshWindow = Duration(minutes: 5);

  // When the phone last completed a successful LOCAL (verified LAN) operation.
  // Fresh local evidence must never be overwritten by a stale cloud verdict.
  DateTime? _lastLocalEvidenceAt;

  Timer? _statusTimer;

  static const int _maxPollFailures = 3;
  int _pollFailures = 0;

  // A cloud report whose backend updatedAt is older than this is considered
  // stale and can never overwrite a fresh LAN read.
  static const Duration _kCloudFreshWindow = Duration(minutes: 5);

  /// Delay before showing the visual pending/loading indicator.
  /// If the command confirms (via Socket.IO or HTTP) before this delay,
  /// the user never sees the heavy loading state.
  static const Duration kRelayPendingIndicatorDelay =
      Duration(milliseconds: 200);

  final List<_ChannelState> _channels =
      List.generate(4, (_) => _ChannelState());
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

  bool get _isOnline => _connectivity == _DeviceConnectivity.online;
  bool get _isOffline => _connectivity == _DeviceConnectivity.offline;

  void _setConnectivity(_DeviceConnectivity value) {
    if (!mounted || _connectivity == value) return;
    setState(() => _connectivity = value);
  }

  // The socket reflects CLOUD reachability only. Device connectivity is
  // decided from DEVICE evidence (reports/polls/LWT), never from the transport
  // socket itself. When the last successful operation ran on the LAN, a cloud
  // outage must not flip the card offline — the device is reachable and
  // controllable locally. Polling re-establishes truth in every other case.
  void _socketDown() {
    // No-op by design: a Socket.IO disconnect is NOT device-offline evidence.
  }

  // Stops every ripple so an OFF channel is never left animating.
  void _stopRipples() {
    for (final c in _rippleControllers) {
      c.stop();
      c.reset();
    }
  }

  /// THE single controlled writer for channel state. Every report — local
  /// command/status, cloud poll, socket event — funnels through here and is
  /// rejected when it is stale. A device report with `state == null` means
  /// UNKNOWN: it never fabricates OFF and never clears a confirmed state.
  /// Applies a confirmed device report for a channel. Returns true only when
  /// the report was actually committed (i.e. it is genuinely NEWER than current
  /// state) — false for stale/older reports that must never regress the UI.
  bool _applyChannelReport(
    int index,
    ChannelReport report,
    DeviceTransportSource source,
  ) {
    if (index < 0 || index >= _deviceChannels) return false;
    final ch = _channels[index];
    final now = DateTime.now();

    if (report.state == null) {
      // UNKNOWN report: only meaningful when we have nothing confirmed.
      if (ch.reported == null && !ch.pending) {
        setState(() {
          ch.source = source;
          ch.updatedAt = report.updatedAt ?? now;
          ch.seq++;
        });
        return true;
      }
      return false;
    }

    final incomingTs = report.updatedAt ?? now;

    if (source == DeviceTransportSource.cloud) {
      // A strictly older cloud report must never overwrite a newer one.
      if (ch.serverTs != null &&
          report.updatedAt != null &&
          !report.updatedAt!.isAfter(ch.serverTs!)) {
        return false;
      }
      // A fresh LAN read is the closest truth. A cloud report may only replace
      // it when the backend genuinely has newer (recent) information.
      final hasFreshLocal = ch.source == DeviceTransportSource.local &&
          ch.updatedAt != null &&
          now.difference(ch.updatedAt!) < kLocalReportHold;
      final cloudFresh = report.updatedAt == null ||
          now.difference(report.updatedAt!) < _kCloudFreshWindow;
      if (hasFreshLocal && !cloudFresh) return false;
    } else {
      // Local is the freshest possible report; only a strictly-newer local
      // read may replace the current one (guards an older local read that
      // lands late).
      if (ch.source == DeviceTransportSource.local &&
          ch.updatedAt != null &&
          incomingTs.isBefore(ch.updatedAt!)) {
        return false;
      }
    }

    setState(() {
      ch.reported = report.state;
      ch.updatedAt = incomingTs;
      if (source == DeviceTransportSource.cloud && report.updatedAt != null) {
        ch.serverTs = report.updatedAt;
      }
      ch.source = source;
      ch.seq++;
      if (report.state == 'ON') {
        _rippleControllers[index].repeat(reverse: true);
      } else {
        _rippleControllers[index].stop();
        _rippleControllers[index].reset();
      }
    });
    return true;
  }

  /// Clears the visual pending/loading state for a relay whose command has been
  /// confirmed. Idempotent: safe to call multiple times for the same operation.
  /// Keeps the single-flight `_pendingRelays` guard in place until the REST
  /// lifecycle finishes, so a tap can never spawn a second command.
  void _resolvePendingForChannel(int channel, String opId) {
    final index = channel - 1;
    final key = '${_selectedDeviceId}_$channel';
    if (index < 0 || index >= _deviceChannels) return;
    if (!_pendingRelays.contains(key)) return;

    // Cancel any pending indicator timer for this operation.
    _pendingIndicatorTimers[key]?.cancel();
    _pendingIndicatorTimers.remove(key);

    setState(() {
      _channels[index].pending = false;
      _channels[index].desired = null;
      _channelLoading[index] = false;
      _showPendingIndicator[index] = false;
    });
    ControlTimeline.mark(opId, _selectedDeviceId!, channel, 'UI confirmed (socket)');
  }

  /// Recent positive device evidence that is NEWER than the last authoritative
  /// LWT Offline. When true, a cloud poll's plain "offline" verdict is stale or
  /// contradicted and must not flip a freshly-confirmed-healthy device.
  bool _hasRecentDeviceEvidence() {
    final last = _lastDeviceEvidenceAt;
    if (last == null) return false;
    if (DateTime.now().difference(last) >= _kDeviceEvidenceFreshWindow) {
      return false;
    }
    // A real LWT Offline that arrived AFTER the last positive evidence wins:
    // only evidence strictly newer than that verdict may hold the card online.
    final offline = _lastAuthoritativeOfflineAt;
    return offline == null || last.isAfter(offline);
  }

  void _applyResult(RelayStatusResult result) {
    final freshLocal = _lastLocalEvidenceAt != null &&
        DateTime.now().difference(_lastLocalEvidenceAt!) < kLocalReportHold;
    if (result.source == DeviceTransportSource.local) {
      // A verified local report is always positive liveness evidence.
      _lastLocalEvidenceAt = DateTime.now();
      _lastDeviceEvidenceAt = DateTime.now();
      _setConnectivity(_DeviceConnectivity.online);
    } else if (result.online) {
      _lastDeviceEvidenceAt = DateTime.now();
      _setConnectivity(_DeviceConnectivity.online);
    } else if (freshLocal) {
      // A stale cloud "offline" verdict must never kill a live local session.
      _setConnectivity(_DeviceConnectivity.online);
    } else if (_hasRecentDeviceEvidence()) {
      // The device produced positive evidence recently (a committed
      // device_update, a successful control ACK, or a recent online status)
      // that is newer than any authoritative LWT Offline. The cloud poll's
      // "offline" is a stale/contradicted verdict, so keep ONLINE — a genuine
      // LWT Offline or the expiry of the freshness window will still flip it.
      _setConnectivity(_DeviceConnectivity.online);
    } else if (_lastDeviceEvidenceAt != null) {
      // The device was confirmed before but has NO recent evidence and the
      // cloud now reports authoritative offline: strong evidence, so OFFLINE.
      _setConnectivity(_DeviceConnectivity.offline);
    } else {
      // No confirmed device evidence yet: SYNCING, never a fabricated OFFLINE.
      _setConnectivity(_DeviceConnectivity.unknown);
    }
    for (final e in result.channels.entries) {
      _applyChannelReport(e.key - 1, e.value, result.source);
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
    _statusTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _fetchStatus(silent: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _cloudHealthTimer?.cancel();
    _cloudHealthTimer = null;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _startCloudHealthMonitor();
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
        // single-flight per device and never blocks the UI.
        unawaited(_repository.warmUp(_devices));
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
      unawaited(_repository.warmUp(_devices));
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
    // (never a fabricated OFF) until the next report.
    for (int i = 0; i < 4; i++) {
      _channels[i] = _ChannelState();
      _channelLoading[i] = false;
    }
    _stopRipples();
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
      if (_channels[i].reported == 'ON') n++;
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
      _socketEverConnected = true;
      // Reconnect: reconcile instead of waiting for the next 15s poll.
      _syncAfterReconnect();
      if (mounted) setState(() {});
    });
    _socket?.onDisconnect((_) {
      final cloudWasUp = _socketConnected;
      _socketConnected = false;
      _socketDown();
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
      _socketDown();
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
        _pollFailures = 0;
        final map = data as Map<String, dynamic>;
        final deviceId = map['deviceId'] as String?;
        if (deviceId != null && deviceId != _selectedDeviceId) return;
        final online = map['online'] == true;
        final freshLocal = _lastLocalEvidenceAt != null &&
            DateTime.now().difference(_lastLocalEvidenceAt!) < kLocalReportHold;
        // A cloud status event must never overwrite a fresher local session.
        if (freshLocal) return;
        // A socket event is always cloud truth.
        if (online) {
          // Positive device report: restore ONLINE.
          _lastDeviceEvidenceAt = DateTime.now();
          _setConnectivity(_DeviceConnectivity.online);
        } else {
          // Explicit MQTT LWT Offline — authoritative device-offline evidence.
          _lastAuthoritativeOfflineAt = DateTime.now();
          _setConnectivity(_DeviceConnectivity.offline);
        }
      } catch (_) {
        // Ignore malformed event; polling re-establishes truth.
      }
    });

    _socket?.on('device_update', (data) {
      try {
        if (!mounted) return;
        _pollFailures = 0;
        final map = data as Map<String, dynamic>;
        final deviceId = map['deviceId'] as String?;
        if (deviceId != null && deviceId != _selectedDeviceId) return;
        final channel = map['channel'] as int;
        final state = map['state'] as String?;
        DateTime? updatedAt;
        final ua = map['updatedAt'];
        if (ua is String) updatedAt = DateTime.tryParse(ua);
        // Phase 2: correlate this socket report to the in-flight tap so the
        // timeline can answer "did Socket.IO confirm before the REST response?"
        final opId = _inFlightOps['$_selectedDeviceId:$channel'];
        if (opId != null) {
          ControlTimeline.mark(opId, _selectedDeviceId!, channel,
              'Socket.IO received (device_update)');
        }
        final committed = _applyChannelReport(
          channel - 1,
          ChannelReport(state == 'UNKNOWN' ? null : state, updatedAt: updatedAt),
          DeviceTransportSource.cloud,
        );
        // A committed device report is itself strong liveness evidence: the
        // device demonstrably talked to MQTT and produced a real state, so
        // restore ONLINE immediately even if the paired `device_status` event
        // is delayed or lost. Newer device evidence also supersedes an older
        // LWT Offline (evidence ordering).
        if (committed && state != null && state != 'UNKNOWN') {
          // Committing a real device state is itself positive liveness
          // evidence (distinct from the channel reports that ride along with a
          // poll's stale "offline" verdict, which must never refresh it).
          _lastDeviceEvidenceAt = DateTime.now();
          _setConnectivity(_DeviceConnectivity.online);
        }
        // Phase 3: a Socket.IO report that the device itself confirmed is
        // authoritative and may resolve the pending tap immediately — but ONLY
        // when it was actually committed as newer (the `_applyChannelReport`
        // return value), for the right device/channel (guarded above). The
        // later REST response still completes the command lifecycle, but can
        // no longer re-enable pending or regress this confirmed state.
        if (opId != null && committed && state != null && state != 'UNKNOWN') {
          _resolvePendingForChannel(channel, opId);
        }
        // Phase 3b: Separately, if the Socket.IO event carries an opId that
        // matches our in-flight operation, it means the backend received a
        // valid MQTT ACK for our command. Resolve the command lifecycle
        // immediately, even if the state report was rejected as stale by
        // _applyChannelReport. The stale-report guard protects authoritative
        // state reconciliation; it must not delay command confirmation.
        if (opId != null && _pendingRelays.contains('$_selectedDeviceId:$channel')) {
          ControlTimeline.mark(opId, _selectedDeviceId!, channel,
              'Socket.IO opId matched — command confirmed');
          _resolvePendingForChannel(channel, opId);
        }
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
    _pollFailures = 0;
    _fetchStatus(silent: true);
    unawaited(_repository.warmUp(_devices));
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
      _pollFailures = 0;
      _applyResult(result);
    } catch (e) {
      if (mounted) {
        if (!silent) _showError('Failed to fetch status');
        // A single failed poll is NOT device-offline evidence (flicker guard).
        // Only repeated consecutive failures count as strong evidence.
        _pollFailures++;
        if (_pollFailures >= _maxPollFailures) {
          _setConnectivity(_DeviceConnectivity.offline);
        }
      }
    } finally {
      _statusInFlight = false;
    }
  }

  Future<void> _toggle(int channel, bool targetState) async {
    if (_selectedDeviceId == null) return;
    // No connectivity gate here: the repository owns reachability. This lets a
    // tap reach the transport layer so the local-first path can run; the card
    // visuals still reflect `_connectivity`.
    final key = '${_selectedDeviceId}_$channel';
    if (_pendingRelays.contains(key)) return;
    final index = channel - 1;
    final ch = _channels[index];
    final seqBefore = ch.seq;
    final opId = ControlTimeline.begin(_selectedDeviceId!, channel);
    _inFlightOps['$_selectedDeviceId:$channel'] = opId;
    _pendingRelays.add(key);
    // Immediately apply optimistic visual state and register the operation.
    // Set pending=true so the optimistic UI (desired) is shown, but do NOT
    // show the heavy loading indicator yet — it will appear after a delay only
    // if the command is still unresolved.
    setState(() {
      ch.pending = true;
      ch.desired = targetState ? 'ON' : 'OFF';
      // Optimistic visual flip: the card reflects the requested state at tap
      // time. The first confirmed report via `_applyChannelReport` overwrites
      // it; on total failure the catch path degrades to UNKNOWN.
      if (targetState) {
        _rippleControllers[index].repeat(reverse: true);
      } else {
        _rippleControllers[index].stop();
        _rippleControllers[index].reset();
      }
    });
    // Light haptic feedback for instant perceived responsiveness.
    HapticFeedback.lightImpact();
    ControlTimeline.mark(opId, _selectedDeviceId!, channel, 'Optimistic UI applied');

// If we have a verified local IP cached and the socket has never connected,
// route the command to the LAN immediately. This enables instant local control
// when the phone is on the same WiFi but has no internet (socket never connects).
// Also use local-first when the socket was connected but is now disconnected
// (confirmed cloud outage).
final hasLocalIp = _repository.hasVerifiedLocalIp(_selectedDeviceId!);
final useLocalFirst = !_socketConnected || (!_socketEverConnected && hasLocalIp);

    // Start a delayed timer to show the pending indicator if the command
    // hasn't resolved by then. The timer is tied to this specific operation
    // via the key, so a newer command on the same channel won't be affected.
    final pendingTimer = Timer(kRelayPendingIndicatorDelay, () {
      if (!mounted) return;
      // Only show the indicator if THIS exact operation is still in flight.
      // A newer tap would have replaced _pendingRelays and _inFlightOps.
      if (_pendingRelays.contains(key) &&
          _inFlightOps['$_selectedDeviceId:$channel'] == opId) {
        setState(() {
          _channelLoading[index] = true;
          _showPendingIndicator[index] = true;
        });
        ControlTimeline.mark(opId, _selectedDeviceId!, channel,
            'Pending indicator shown');
      }
    });
    _pendingIndicatorTimers[key] = pendingTimer;

    try {
      final result = await _repository.control(
        _selectedDeviceId!,
        channel,
        targetState ? 'ON' : 'OFF',
        opId: opId,
        // Route the tap immediately: when the Socket.IO cloud monitor has
        // confirmed the cloud is unreachable, OR when we have a verified local
        // IP and the socket is not connected, the LAN gets the command first.
        cloudDown: useLocalFirst,
      );
      if (!mounted) {
        ControlTimeline.end(opId);
        return;
      }
      ControlTimeline.mark(opId, _selectedDeviceId!, channel,
          'HTTP response received');
      // The socket may already have confirmed this relay (Phase 3): then
      // pending is already resolved and this REST response must only finish
      // the lifecycle, never re-enable pending or regress the confirmed state.
      final alreadyResolved = !_pendingRelays.contains(key);
      _resolvePendingForChannel(channel, opId);
      ControlTimeline.mark(opId, _selectedDeviceId!, channel,
          alreadyResolved ? 'REST completed (already resolved)' : 'Pending cleared (HTTP)');
      _applyResult(result);
      if (!alreadyResolved) {
        ControlTimeline.mark(opId, _selectedDeviceId!, channel,
            'UI confirmed (REST)');
      }
      // If the changed channel did not come back with a confirmed report,
      // reconcile immediately rather than leaving a silent pending state.
      if (result.channels[channel]?.state == null) {
        _fetchStatus(silent: true);
      }
    } catch (e) {
      if (!mounted) {
        ControlTimeline.end(opId);
        return;
      }
      ControlTimeline.mark(opId, _selectedDeviceId!, channel, 'Command failed');
      final msg = e.toString().replaceFirst('Exception: ', '');
      final socketConfirmed = ch.seq != seqBefore;
      // If the command failed but a newer device report already arrived
      // (socketConfirmed), the UI already shows the truth. Otherwise,
      // degrade to UNKNOWN.
      if (!socketConfirmed) {
        _resolvePendingForChannel(channel, opId);
        setState(() {
          ch.reported = null;
          ch.source = null;
          ch.updatedAt = null;
          _rippleControllers[index].stop();
          _rippleControllers[index].reset();
        });
      } else {
        _resolvePendingForChannel(channel, opId);
      }
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

  void _openAddDevice() async {
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
      // Removed (200) or already gone (404): drop the device locally and clear
      // its Local Mode cache entry so a re-claim is treated as a new device.
      await LocalDeviceCache().remove(deviceId);
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
            connectivity: _connectivity,
            cloudReachable: _socketConnected,
            localEvidenceFresh: _lastLocalEvidenceAt != null &&
                DateTime.now().difference(_lastLocalEvidenceAt!) <
                    kLocalReportHold,
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
            reported: _channels[i].reported,
            desired: _channels[i].desired,
            pending: _channels[i].pending,
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
  final _DeviceConnectivity connectivity;

  /// Whether the cloud is reachable (Socket.IO connected, or still unknown —
  /// the safe cloud-first default). ONLINE has priority whenever the cloud is
  /// up; a successful local read alone must never downgrade the badge to LAN.
  final bool cloudReachable;

  /// Whether the device produced RECENT local evidence (within the local-report
  /// hold window). LAN is only shown when the cloud is CONFIRMED unreachable
  /// AND the device was verified locally — never because the last request
  /// happened to use the LAN transport.
  final bool localEvidenceFresh;

  const _StatusPill({
    required this.connectivity,
    required this.cloudReachable,
    required this.localEvidenceFresh,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    // 'LAN' is the subtle Local Mode indicator: same styling as 'Online' so the
    // relay UI itself never changes; only the label differentiates transport.
    // LAN means "cloud confirmed down + device verified on the LAN", NOT
    // "the last successful request ran on the LAN".
    final isOnline = connectivity == _DeviceConnectivity.online;
    final showLan = isOnline && !cloudReachable && localEvidenceFresh;
    final color = isOnline ? colors.leaf : colors.mist;
    final label = isOnline
        ? (showLan ? 'LAN' : 'Online')
        : connectivity == _DeviceConnectivity.offline
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
