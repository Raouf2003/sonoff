import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';

enum _Step { connect, provision, waiting }

/// STEES provisioning wizard. Replaces the workflow of typing MQTT/Wi-Fi
/// settings into the raw Tasmota web page, using STEES-styled screens and the
/// existing backend claim endpoint.
class ProvisionDeviceScreen extends StatefulWidget {
  const ProvisionDeviceScreen({super.key});

  @override
  State<ProvisionDeviceScreen> createState() => _ProvisionDeviceScreenState();
}

class _ProvisionDeviceScreenState extends State<ProvisionDeviceScreen>
    with WidgetsBindingObserver {
  static const String _deviceUrl = 'http://192.168.4.1';

  // Expected Tasmota AP SSID used only for the Wi-Fi binding sanity check.
  // The trailing XXXX acts as a tasmota- prefix wildcard in MainActivity.
  static const String _tasmotaApSsid = 'tasmota-XXXX';

  static const MethodChannel _wifiBindChannel =
      MethodChannel('stees/wifi_binding');

  bool _wifiBound = false;

  final _api = ApiService();

  final _ssidCtl = TextEditingController();
  final _wifiPassCtl = TextEditingController();
  final _mqttBrokerCtl = TextEditingController(text: 'broker.emqx.io');
  final _mqttPortCtl = TextEditingController(text: '1883');
  final _mqttUserCtl = TextEditingController();
  final _mqttPassCtl = TextEditingController();
  final _deviceNameCtl = TextEditingController();
  final _topicCtl = TextEditingController();

  bool _manualWifi = false;

  _Step _step = _Step.connect;
  bool _searching = false;
  bool _provisioning = false;
  String? _error;
  Timer? _reachTimer;
  Timer? _waitTimer;
  String? _pollingTopic;

  String get _phaseLabel {
    switch (_step) {
      case _Step.connect:
        return 'AP_CONNECT';
      case _Step.provision:
        return 'CONFIGURING';
      case _Step.waiting:
        return 'WAITING_FOR_DEVICE';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phase-dependent resume handling. The AP probe / Wi-Fi binding must run
    // ONLY during the initial "connect phone to Tasmota AP" phase. After the
    // Tasmota Restart command succeeds, the AP is EXPECTED to disappear, so we
    // must never re-probe 192.168.4.1 or show an AP connection error again.
    if (state != AppLifecycleState.resumed || !mounted) return;
    switch (_step) {
      case _Step.connect:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - rechecking Tasmota AP');
        _reachTimer?.cancel();
        _wifiBound = false;
        _probeReachability();
      case _Step.provision:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - AP probe skipped (configuring)');
      case _Step.waiting:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - AP probe skipped: provisioning already completed');
        _waitTimer?.cancel();
        final topic = _pollingTopic;
        if (topic != null) _pollSnapshot(topic);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseWifiBinding());
    _reachTimer?.cancel();
    _waitTimer?.cancel();
    _ssidCtl.dispose();
    _wifiPassCtl.dispose();
    _mqttBrokerCtl.dispose();
    _mqttPortCtl.dispose();
    _mqttUserCtl.dispose();
    _mqttPassCtl.dispose();
    _deviceNameCtl.dispose();
    _topicCtl.dispose();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────────
  // Step 1 - connect to device Wi-Fi + reachability
  // ──────────────────────────────────────────────────────────

  static const MethodChannel _wifiSettingsChannel =
      MethodChannel('stees/wifi_settings');

  Future<void> _openWifiSettings() async {
    try {
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        await launchUrl(
          Uri.parse('App-Prefs:root=WIFI'),
          mode: LaunchMode.externalApplication,
        );
      } else {
        await _wifiSettingsChannel.invokeMethod<void>('openWifiSettings');
      }
    } catch (_) {
      _setError('Could not open Wi-Fi settings.');
    }
  }

  void _startSearch() {
    debugPrint('[PROVISION] phase=$_phaseLabel start search');
    if (_step != _Step.connect) return;
    _reachTimer?.cancel();
    setState(() {
      _searching = true;
      _error = null;
    });
    _wifiBound = false;
    _probeReachability();
  }

  // Bind this process's sockets to the CURRENTLY ACTIVE Wi-Fi network (the one
  // the user manually selected in Android Wi-Fi settings). Unlike the old
  // requestNetwork() approach this never lets Android pick a different network
  // (e.g. the router) — getActiveNetwork() returns exactly the user's choice.
  Future<void> _ensureBoundToWifi() async {
    if (Theme.of(context).platform == TargetPlatform.iOS) return;
    if (_wifiBound) return;
    final expected = _tasmotaApSsid;
    try {
      final info = await _wifiBindChannel.invokeMethod<Map<dynamic, dynamic>>(
        'ensureBoundToActiveWifi',
        {'expectedSsid': expected},
      );
      final activeSsid = info?['activeSsid']?.toString() ?? '<unknown>';
      debugPrint('[PROVISION] expected SSID: $expected');
      debugPrint('[PROVISION] active SSID: $activeSsid');
      final matched = info?['matched'] == true;
      _wifiBound = info?['bound'] == true;
      if (_wifiBound) {
        debugPrint('[PROVISION] active Wi-Fi network matched');
        debugPrint('[PROVISION] process bound to active Wi-Fi');
        await _logNetworkInfo('after bind');
      } else if (!matched) {
        debugPrint('[PROVISION] wrong Wi-Fi network');
        _error =
            "You're connected to $activeSsid. Connect to $expected. Open Wi-Fi settings and try again.";
        setState(() {});
      } else {
        debugPrint('[PROVISION] could not bind to active Wi-Fi');
      }
    } catch (e) {
      debugPrint('[PROVISION] wifi bind failed: $e');
    }
  }

  Future<void> _releaseWifiBinding() async {
    if (Theme.of(context).platform == TargetPlatform.iOS) return;
    try {
      await _wifiBindChannel.invokeMethod<void>('releaseWifiBinding');
      debugPrint('[PROVISION] wifi binding released');
    } catch (_) {}
    _wifiBound = false;
  }

  Future<void> _probeReachability() async {
    if (!mounted || _step != _Step.connect) return;
    // Give Android a moment to settle on the newly selected network after the
    // user returns from Wi-Fi Settings (or from Continue).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || _step != _Step.connect) return;
    await _ensureBoundToWifi();
    if (!_wifiBound) {
      // Wrong SSID or bind failed: stop auto-retrying, show error + Retry.
      if (mounted && _step == _Step.connect) setState(() => _searching = false);
      return;
    }
    if (await _isReachable()) {
      _reachTimer?.cancel();
      setState(() {
        _searching = false;
        _step = _Step.provision;
        _syncTopic();
      });
      return;
    }
    setState(() {
      _error ??=
          'Could not find the device. Open Wi-Fi settings and connect to it.';
    });
    _reachTimer = Timer(const Duration(seconds: 2), _probeReachability);
  }

  Future<bool> _isReachable() async {
    try {
      debugPrint('[PROVISION] probing $_deviceUrl');
      final res =
          await http.get(Uri.parse(_deviceUrl)).timeout(const Duration(seconds: 3));
      // Any HTTP response counts as reachable, regardless of status code.
      debugPrint('[PROVISION] probe status=${res.statusCode}');
      return true;
    } catch (_) {
      debugPrint('[PROVISION] probe unreachable (connection failed or timeout)');
      _wifiBound = false;
      await _logNetworkInfo('probe failed');
      return false;
    }
  }

  Future<bool> _logNetworkInfo(String tag) async {
    if (Theme.of(context).platform == TargetPlatform.iOS) return false;
    try {
      final info = await _wifiBindChannel
          .invokeMethod<Map<dynamic, dynamic>>('getNetworkInfo');
      debugPrint(
          '[PROVISION] $tag: bound=${info?['bound']} wifi=${info?['wifi']} '
          'internet=${info?['internet']} validated=${info?['validated']}');
      return info?['internet'] == true;
    } catch (e) {
      debugPrint('[PROVISION] $tag: could not read network info: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────
  // Step 2 - configuration form + topic generation
  // ──────────────────────────────────────────────────────────

  void _syncTopic() {
    final name = _deviceNameCtl.text.trim();
    if (name.isEmpty) return;
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final rand = (DateTime.now().millisecondsSinceEpoch % 0xFFFF)
        .toRadixString(16)
        .padLeft(4, '0');
    _topicCtl.text = 'stees_${slug}_$rand';
    setState(() {});
  }

  // ──────────────────────────────────────────────────────────
  // Step 3 - provision via Tasmota HTTP + restart
  // ──────────────────────────────────────────────────────────

  Future<void> _provision() async {
    final name = _deviceNameCtl.text.trim();
    final ssid = _ssidCtl.text.trim();
    if (name.isEmpty) {
      _setError('Enter a Device Name.');
      return;
    }
    if (ssid.isEmpty) {
      _setError('Select or enter your home Wi-Fi network.');
      return;
    }
    _syncTopic();
    final topic = _topicCtl.text.trim();
    if (topic.isEmpty) {
      _setError('Could not generate a Device ID. Enter a Device Name first.');
      return;
    }
    setState(() {
      _provisioning = true;
      _error = null;
    });
    final ok = await _sendTasmotaConfig();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _provisioning = false;
        _error = 'Configuration failed. The device rejected the settings.';
      });
      return;
    }
    debugPrint('[PROVISION] restart succeeded');
    // Post-provision / waiting phase. The Tasmota AP is expected to disappear
    // now — stop AP probing and do NOT re-run Wi-Fi binding. The phone must go
    // back to normal routing and we wait for the device on the backend.
    _reachTimer?.cancel();
    debugPrint('[PROVISION] phase=WAITING_FOR_DEVICE');
    await _releaseWifiBinding();
    debugPrint('[PROVISION] wifi binding released');
    if (!mounted) return;
    setState(() {
      _provisioning = false;
      _step = _Step.waiting;
      _error = null;
    });
    _waitForDeviceOnline(topic);
  }

  // Provision the device in two phases:
  //  1) Write MQTT + Topic + DeviceName FIRST, while the phone is still on the
  //     device AP. If Tasmota drops the connection when the SSID changes, these
  //     settings are already saved.
  //  2) Then switch Wi-Fi, and finally restart so MQTT applies with fresh state.
  Future<bool> _sendTasmotaConfig() async {
    await _ensureBoundToWifi();
    final mqttParts = <String>[
      'MqttHost ${_mqttBrokerCtl.text.trim()}',
      'MqttPort ${_mqttPortCtl.text.trim()}',
      if (_mqttUserCtl.text.trim().isNotEmpty)
        'MqttUser ${_mqttUserCtl.text.trim()}',
      if (_mqttPassCtl.text.isNotEmpty) 'MqttPassword ${_mqttPassCtl.text}',
      'Topic ${_topicCtl.text.trim()}',
      'DeviceName ${_deviceNameCtl.text.trim()}',
    ];
    final mqttCommand = 'Backlog ${mqttParts.join('; ')}';
    debugPrint('[PROVISION] sending MQTT phase command: $mqttCommand');
    final mqttOk = await _sendCommand(mqttCommand);
    if (!mqttOk) return false;

    await Future<void>.delayed(const Duration(milliseconds: 500));

    final wifiCommand =
        'Backlog SSId1 ${_ssidCtl.text.trim()}; Password1 ${_wifiPassCtl.text}';
    debugPrint('[PROVISION] sending WiFi phase command: $wifiCommand');
    final wifiOk = await _sendCommand(wifiCommand);
    if (!wifiOk) return false;

    await Future<void>.delayed(const Duration(milliseconds: 500));

    debugPrint('[PROVISION] sending restart command: Restart 1');
    return _sendCommand('Restart 1');
  }

  Future<bool> _sendCommand(String command) async {
    try {
      final uri = Uri.parse('$_deviceUrl/cm').replace(
        queryParameters: {'cmnd': command},
      );
      debugPrint('[PROVISION] HTTP GET $uri');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      debugPrint('[PROVISION] status=${res.statusCode} body=${res.body}');
      return true;
    } catch (e) {
      debugPrint('[PROVISION] exception sending "$command": $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────
  // Wait for the device to come online, then auto-claim
  // ──────────────────────────────────────────────────────────

  void _waitForDeviceOnline(String deviceId) {
    _pollingTopic = deviceId;
    _pollSnapshot(deviceId);
  }

  Future<void> _pollSnapshot(String deviceId) async {
    if (_step != _Step.waiting) return;
    bool found = false;
    try {
      debugPrint('[PROVISION] polling backend for deviceId=$deviceId');
      final snapshot = await _api.fetchSnapshot();
      final recent = snapshot['recentDevices'] as List<dynamic>? ?? [];
      found = recent.any((d) => d is Map && d['deviceId'] == deviceId);
    } catch (_) {
      found = false;
    }
    if (!mounted || _step != _Step.waiting) return;
    if (found) {
      debugPrint('[PROVISION] device detected in recentDevices');
      _waitTimer?.cancel();
      await _runClaim(deviceId);
      return;
    }
    _waitTimer = Timer(const Duration(seconds: 3), () => _pollSnapshot(deviceId));
  }

  Future<void> _runClaim(String deviceId) async {
    try {
      await _api.claimDevice(deviceId, _deviceNameCtl.text.trim(), channels: 4);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      final claimed = msg.toLowerCase().contains('already claimed');
      _setError(
        claimed
            ? 'This device is already linked to another account.'
            : 'Could not claim the device. Please try again.',
      );
    }
  }

  // ──────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────

  void _setError(String msg) {
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Provision Device',
          style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam),
        ),
        backgroundColor: colors.well,
        iconTheme: IconThemeData(color: colors.mist),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.well, Theme.of(context).colorScheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: _buildStep(colors),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(SteesColors colors) {
    switch (_step) {
      case _Step.connect:
        return _buildConnect(colors);
      case _Step.provision:
        return _buildConfig(colors);
      case _Step.waiting:
        return _buildWaiting(colors);
    }
  }

  Widget _buildConnect(SteesColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: colors.submerged,
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          child: Column(
            children: [
              Icon(Icons.wifi_outlined, size: 40, color: colors.stream.withValues(alpha: 0.5)),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Connect your phone to the device Wi-Fi.\n\n'
                "Tap below, pick the device's access point (tasmota-XXXX), "
                'then return here.',
                style: GoogleFonts.inter(fontSize: 13, color: colors.mist, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _openWifiSettings,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Open Wi-Fi Settings'),
                  style: _filledStyle(colors),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _searching ? null : _startSearch,
                  style: _filledStyle(colors),
                  child: _searching
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well),
                        )
                      : Text('Continue', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 12, color: colors.danger),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConfig(SteesColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(colors, 'HOME WI-FI'),
        _buildWifiSelector(colors),
        const SizedBox(height: AppSpacing.md),
        if (_manualWifi) ...[
          _Field(
            controller: _ssidCtl,
            hint: 'Network name (SSID)',
            icon: Icons.router_outlined,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _Field(
          controller: _wifiPassCtl,
          hint: 'Wi-Fi Password',
          icon: Icons.lock_outline,
          obscure: true,
        ),
        const SizedBox(height: AppSpacing.xl),
        _section(colors, 'DEVICE'),
        _Field(
          controller: _deviceNameCtl,
          hint: 'Device Name',
          icon: Icons.label_outline,
          onChanged: (_) => _syncTopic(),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Icon(Icons.alternate_email, size: 18, color: colors.mist),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Device ID',
                      style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _topicCtl.text.isEmpty ? 'generated from device name' : _topicCtl.text,
                      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _provisioning ? null : _provision,
            style: _filledStyle(colors),
            child: _provisioning
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well),
                  )
                : Text('Provision Device', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  // Dropdown-style selector for the HOME Wi-Fi network. Opening it scans for
  // nearby networks (without disconnecting from the Tasmota AP) and offers a
  // manual entry fallback for hidden/unlisted networks.
  Widget _buildWifiSelector(SteesColors colors) {
    final selected = _ssidCtl.text.trim();
    return InkWell(
      onTap: _openWifiPicker,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi, size: 18, color: colors.mist),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Wi-Fi Network',
                    style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selected.isEmpty ? 'Select Wi-Fi network' : selected,
                    style: GoogleFonts.inter(fontSize: 14, color: selected.isEmpty ? colors.mist : colors.foam),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 22, color: colors.mist),
          ],
        ),
      ),
    );
  }

  Future<void> _openWifiPicker() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) => _WifiPickerSheet(
        currentSsid: _ssidCtl.text.trim(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (picked == '_manual') {
        _manualWifi = true;
      } else {
        _manualWifi = false;
        _ssidCtl.text = picked;
      }
    });
  }

  Widget _buildWaiting(SteesColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xxxl),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.stream.withValues(alpha: 0.06),
              border: Border.all(color: colors.stream.withValues(alpha: 0.12)),
            ),
            child: Icon(Icons.cloud_done_outlined, size: 32, color: colors.stream.withValues(alpha: 0.5)),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Waiting for device...',
          textAlign: TextAlign.center,
          style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'The device will join your Wi-Fi, reconnect to MQTT, and be claimed automatically.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 13, height: 1.5, color: colors.mist.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.xl),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 13, color: colors.danger),
          ),
        ],
      ],
    );
  }

  Widget _section(SteesColors colors, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
      child: Text(
        title,
        style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: colors.mist),
      ),
    );
  }

  ButtonStyle _filledStyle(SteesColors colors) {
    return FilledButton.styleFrom(
      backgroundColor: colors.stream,
      foregroundColor: colors.well,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
    );
  }
}

class _WifiPickerSheet extends StatefulWidget {
  final String currentSsid;
  const _WifiPickerSheet({required this.currentSsid});

  @override
  State<_WifiPickerSheet> createState() => _WifiPickerSheetState();
}

class _WifiPickerSheetState extends State<_WifiPickerSheet> {
  static const _scanChannel = MethodChannel('stees/wifi_settings');

  List<String> _networks = const [];
  bool _scanning = false;
  String? _scanMessage;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanMessage = null;
      _networks = const [];
    });
    try {
      final Map<dynamic, dynamic>? result = await _scanChannel
          .invokeMethod<Map<dynamic, dynamic>>('scanWifi')
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final available = result?['available'] == true;
      final raw = result?['networks'] as List<dynamic>? ?? const [];
      final ssids = raw
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      setState(() {
        _scanning = false;
        _networks = ssids;
        _scanMessage = !available
            ? 'Wi-Fi scan unavailable. Enter your network manually.'
            : (ssids.isEmpty ? 'No Wi-Fi networks found.' : null);
      });
    } on TimeoutException {
      debugPrint('[PROVISION] wifi scan timed out after 10s');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = 'Wi-Fi scan timed out. Tap refresh to try again.';
      });
    } catch (e) {
      debugPrint('[PROVISION] wifi scan failed: $e');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = 'Wi-Fi scan unavailable. Enter your network manually.';
      });
    }
  }

  void _selectNetwork(String ssid) {
    Navigator.of(context).pop(ssid);
  }

  void _selectManual() {
    Navigator.of(context).pop('_manual');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Select Wi-Fi Network',
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: colors.foam),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Rescan',
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: colors.stream),
                        )
                      : const Icon(Icons.refresh, size: 20, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_scanMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  _scanMessage!,
                  style: GoogleFonts.inter(fontSize: 12, color: colors.mist.withValues(alpha: 0.8)),
                ),
              ),
            if (_scanning)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.stream),
                  ),
                ),
              )
            else if (_networks.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _networks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (ctx, i) {
                    final ssid = _networks[i];
                    final isCurrent = ssid == widget.currentSsid;
                    return Material(
                      color: isCurrent ? colors.stream.withValues(alpha: 0.12) : colors.submerged,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                        leading: Icon(Icons.wifi, size: 20, color: colors.mist),
                        title: Text(
                          ssid,
                          style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isCurrent
                            ? Icon(Icons.check_circle, size: 18, color: colors.stream)
                            : null,
                        onTap: () => _selectNetwork(ssid),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: AppSpacing.xl),
            ListTile(
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              leading: Icon(Icons.keyboard_outlined, size: 20, color: colors.mist),
              title: Text(
                'Enter network manually',
                style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
              ),
              onTap: _selectManual,
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 18, color: colors.mist),
        filled: true,
        fillColor: colors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: colors.stream, width: 1.5),
        ),
      ),
    );
  }
}