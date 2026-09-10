import 'dart:async';
import 'package:flutter/foundation.dart';
import '../devices/device_repository.dart';
import '../transport/clock_sync.dart';
import '../transport/device_identity.dart';
import '../transport/device_transport.dart';
import '../transport/local_device_transport.dart';
import '../devices/device_profile.dart';
import 'ap_connector.dart';
import 'connection_machine.dart';
import 'pairing_store.dart';
import 'session.dart';

typedef StatusProbe = Future<String> Function(String address, String command, {String? password, String? referer});

Future<String> _defaultProbe(String address, String command, {String? password, String? referer}) {
  return defaultTasmotaCmFetcher(address, command, password: password, referer: referer);
}

class ConnectionController extends ChangeNotifier {
  ConnectionController({
    ApConnector? connector,
    PairingStore? pairing,
    LocalDeviceRepository? repository,
    ClockSync? clock,
    SessionState? session,
    StatusProbe? probe,
    Duration wifiWatchInterval = const Duration(seconds: 2),
    Duration wifiWatchTimeout = const Duration(seconds: 90),
  })  : _connector = connector ?? ApConnector(),
        _pairing = pairing ?? PairingStore(),
        _repository = repository ?? LocalDeviceRepository(),
        _clock = clock ?? ClockSync(),
        _session = session,
        _probe = probe ?? _defaultProbe,
        _watchInterval = wifiWatchInterval,
        _watchTimeout = wifiWatchTimeout;

  final ApConnector _connector;
  final PairingStore _pairing;
  final LocalDeviceRepository _repository;
  final ClockSync _clock;
  final SessionState? _session;
  final StatusProbe _probe;
  final Duration _watchInterval;
  final Duration _watchTimeout;

  ConnectionState _state = const ConnectionState();
  ConnectionState get state => _state;

  List<WifiNetwork> _networks = const [];
  List<WifiNetwork> get networks => _networks;
  String? _scanMessage;
  String? get scanMessage => _scanMessage;
  String? _selectedSsid;
  String? get selectedSsid => _selectedSsid;

  Timer? _watchTimer;
  int _watchTicks = 0;
  bool _running = false;
  String? _expectedSsid;
  String? _pairedMac;
  String? _password;

  bool get isWatching => _watchTimer?.isActive ?? false;

  void _emit(ConnectionEvent event) {
    final next = connectionReduce(_state, event);
    if (identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }

  Future<void> _loadCredentials() async {
    _pairedMac = await _pairing.pairedMac();
    try {
      _password = await _pairing.password();
    } catch (_) {
      _password = null;
    }
    if (_password != null && _password!.isEmpty) _password = null;
    final savedSsid = await _pairing.apSsid();
    _expectedSsid = (savedSsid == null || savedSsid.isEmpty) ? 'tasmota-xxxx' : savedSsid;
  }

  Future<void> scan() async {
    if (_running) return;
    _running = true;
    try {
      await _loadCredentials();
      _emit(const ScanRequested());
      final result = await _connector.scanWifi();
      if (!result.available && result.networks.isEmpty) {
        _emit(ScanFailed(result.reason ?? 'unavailable'));
        return;
      }
      _networks = result.networks;
      _scanMessage = result.reason;
      _emit(ScanCompleted(count: result.networks.length));
    } finally {
      _running = false;
    }
  }

  Future<void> select(String ssid) async {
    if (_running) return;
    _running = true;
    _selectedSsid = ssid;
    _expectedSsid = ssid;
    _emit(NetworkSelected(ssid));
    try {
      await _loadCredentials();
      _expectedSsid = ssid;
      String stage;
      try {
        stage = await _connector.connectToAp(ssid);
      } on ApConnectionException catch (e) {
        if (e.code == 'UNSUPPORTED' || e.code == 'PERMISSION_DENIED') {
          await _openSettingsFallback();
          return;
        }
        _emit(const ApJoinFailed(ConnectionFailure.wifiRejected));
        return;
      }
      if (stage == 'available') {
        _emit(const ApJoinSucceeded());
        await _continueAfterWifi(ssid);
        return;
      }
      if (stage == 'timeout') {
        _emit(const ApJoinFailed(ConnectionFailure.wifiTimeout));
        return;
      }
      _emit(const ApJoinFailed(ConnectionFailure.wifiRejected));
    } finally {
      if (_state.isTerminal) _running = false;
    }
  }

  Future<void> _openSettingsFallback() async {
    try {
      await _connector.openWifiSettings();
    } on ApConnectionException {
      _emit(const WifiWatchTimeout());
      return;
    }
    _emit(const WifiOpened());
    _beginWatch();
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await _loadCredentials();
      _emit(const StartRequested());
      await _openSettingsFallback();
    } finally {
      if (_state.isTerminal) _running = false;
    }
  }

  void _beginWatch() {
    _watchTimer?.cancel();
    _watchTicks = 0;
    _watchTimer = Timer.periodic(_watchInterval, (_) => _watchTick());
  }

  bool _tickRunning = false;

  Future<void> recheck() async {
    if (_state.phase == ConnectionPhase.waitingWifi && !_tickRunning) {
      await _watchTick();
    }
  }

  Future<void> _watchTick() async {
    if (_tickRunning) return;
    if (_state.phase != ConnectionPhase.waitingWifi) {
      _stopWatch();
      return;
    }
    _tickRunning = true;
    try {
      _watchTicks++;
      if (Duration(milliseconds: _watchInterval.inMilliseconds * _watchTicks) > _watchTimeout) {
        _stopWatch();
        _emit(const WifiWatchTimeout());
        _running = false;
        return;
      }
      ApNetworkInfo info;
      try {
        info = await _connector.ensureBound(_expectedSsid ?? 'tasmota-xxxx');
      } on ApConnectionException {
        return;
      }
      debugPrint('[LOCAL][WATCH] wifi=${info.wifi} bound=${info.bound} '
          'internet=${info.internet} validated=${info.validated} '
          'matched=${info.matched} ssid=${info.activeSsid}');
      if (!info.wifi) return;
      _emit(WifiDetected(wifi: true, matched: info.matched ?? true, internet: info.internet));
      if (_state.phase != ConnectionPhase.wifiConnected) {
        _stopWatch();
        if (!_state.isTerminal) _running = false;
        return;
      }
      _stopWatch();
      await _continueAfterWifi(info.activeSsid);
    } finally {
      _tickRunning = false;
    }
  }

  void _stopWatch() {
    _watchTimer?.cancel();
    _watchTimer = null;
    _watchTicks = 0;
  }

  Future<void> _continueAfterWifi(String? activeSsid) async {
    if (activeSsid != null && activeSsid.isNotEmpty) {
      try {
        await _pairing.saveApSsid(activeSsid);
      } catch (_) {}
    }
    _emit(const ProbeSucceeded(wifi: true));
    String? mac;
    try {
      mac = await _readMac();
    } on PasswordRejected {
      _emit(const BadPassword());
      _running = false;
      return;
    } catch (_) {
      _state = _state.copyWith(phase: ConnectionPhase.failed, failure: ConnectionFailure.unreachable);
      notifyListeners();
      _running = false;
      return;
    }
    if (mac == null) {
      _emit(const DeviceNotTasmota('no identity at 192.168.4.1'));
      _running = false;
      return;
    }
    _emit(DeviceFound(mac));
    if (_pairedMac != null && _pairedMac!.isNotEmpty && _pairedMac != mac) {
      _emit(MacMismatch(expected: _pairedMac!, found: mac));
      _running = false;
      return;
    }
    if (_pairedMac == null || _pairedMac!.isEmpty) {
      _pendingMac = mac;
      notifyListeners();
      return;
    }
    await _finishPairing(mac);
  }

  bool get awaitingConfirm =>
      _state.phase == ConnectionPhase.verifying && _pendingMac != null;

  String? get pendingMac => _pendingMac;
  String? _pendingMac;

  String _pendingProfileId = DeviceProfile.defaultId;

  Future<void> confirmPairing(String name, {String? profileId}) async {
    final mac = _pendingMac;
    if (mac == null || !_running) return;
    _pendingMac = null;
    _pendingProfileId = DeviceProfile.fromId(profileId).id;
    try {
      await _pairing.savePairing(
        mac: mac,
        name: name.isEmpty ? 'Sonoff 4CH' : name,
        profileId: _pendingProfileId,
      );
    } catch (_) {}
    await _finishPairing(mac);
  }

  Future<void> _finishPairing(String mac) async {
    _emit(const IdentityVerified());
    try {
      if (_pairedMac == null || _pairedMac!.isEmpty) {
        await _repository.enableHttpApi(mac, password: _password);
      }
      await _clock.ensureSynced(kApAddress, password: _password);
    } on DeviceTransportException catch (e) {
      if (_isAuthFailure(e)) {
        _emit(const BadPassword());
      } else {
        _emit(ClockFailed(e.message));
      }
      _running = false;
      return;
    } catch (e) {
      _emit(ClockFailed('$e'));
      _running = false;
      return;
    }
    _emit(const ClockSynced());
    var name = 'Sonoff 4CH';
    var profileId = _pendingProfileId;
    try {
      name = await _pairing.deviceName() ?? 'Sonoff 4CH';
      if (name.isEmpty) name = 'Sonoff 4CH';
      profileId = (await _pairing.deviceProfile()).id;
      await _pairing.savePairing(mac: mac, name: name, profileId: profileId);
    } catch (_) {}
    _session?.establish(Session(mac: mac, name: name, password: _password, profileId: profileId));
    _running = false;
  }

  Future<String?> _readMac() async {
    try {
      final body = await _probe(kApAddress, 'Status%205', password: _password);
      final mac = normalizeMac(extractMacFromStatus5(body));
      if (mac != null) return mac;
      if (!body.toLowerCase().contains('denied')) return null;
      final retry = await _probe(kApAddress, 'Status%205',
          password: _password, referer: 'http://$kApAddress/');
      return normalizeMac(extractMacFromStatus5(retry));
    } on DeviceTransportException catch (e) {
      if (_isAuthFailure(e)) throw PasswordRejected();
      rethrow;
    }
  }

  bool _isAuthFailure(DeviceTransportException e) {
    final cause = e.cause;
    if (cause == null) return false;
    return cause.toString().contains('401');
  }

  Future<void> retry() async {
    cancel();
    _emit(const RetryRequested());
    await scan();
  }

  Future<void> openPairedSession() async {
    try {
      final mac = await _pairing.pairedMac();
      if (mac == null || mac.isEmpty) return;
      final name = await _pairing.deviceName() ?? 'Sonoff 4CH';
      final profile = await _pairing.deviceProfile();
      _session?.establish(Session(
        mac: mac,
        name: name.isEmpty ? 'Sonoff 4CH' : name,
        password: _password,
        profileId: profile.id,
      ));
    } catch (_) {}
  }

  Future<void> openSystemWifi() async {
    try {
      await _connector.openWifiSettings();
    } on ApConnectionException {
      return;
    }
  }

  void cancel() {
    _stopWatch();
    _running = false;
    _pendingMac = null;
    _selectedSsid = null;
    _emit(const Cancelled());
  }

  @override
  void dispose() {
    _stopWatch();
    super.dispose();
  }
}

class PasswordRejected implements Exception {
  const PasswordRejected();
}
