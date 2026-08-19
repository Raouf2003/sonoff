import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// DEBUG DIAGNOSTIC screen for the production `stees/ap_connect` channel
/// (debug-launcher only, never shown to users; shares NOTHING with the real
/// provisioning flow).
///
/// Questions under test on a real device:
///   1. Does WifiNetworkSpecifier connect to the Tasmota soft-AP at all?
///   2. When it does, does the OS STILL kick the user into the captive-portal
///      browser / "Sign in to network" UI? (Observed by eye, not asserted.)
///   3. Does `probeGateway` (GET the Tasmota gateway over the bound network)
///      succeed?
///   4. Timings: request → onAvailable, and request → successful probe.
///
/// The production wizard never probes here — it uses its own 192.168.4.1
/// reachability check after `connectToAp` succeeds.
/// ─────────────────────────────────────────────────────────────────────────────
class ApConnectPocScreen extends StatefulWidget {
  const ApConnectPocScreen({super.key});

  @override
  State<ApConnectPocScreen> createState() => _ApConnectPocScreenState();
}

class _ApConnectPocScreenState extends State<ApConnectPocScreen> {
  static const MethodChannel _channel = MethodChannel('stees/ap_connect');
  static const String _defaultGateway = 'http://192.168.4.1/';

  final TextEditingController _ssidCtl =
      TextEditingController(text: 'tasmota-C30304-0772');
  final TextEditingController _gatewayCtl =
      TextEditingController(text: _defaultGateway);

  bool _supported = false;
  int _sdkInt = -1;
  bool _checking = true;

  String _stage = 'idle';
  Map<String, dynamic> _state = const {};
  final List<String> _log = [];
  String _manualNote = '';

  Timer? _pollTimer;

  bool _probeFired = false;

  @override
  void initState() {
    super.initState();
    _loadSdkInfo();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ssidCtl.dispose();
    _gatewayCtl.dispose();
    super.dispose();
  }

  Future<void> _loadSdkInfo() async {
    _logLine('Checking platform support...');
    try {
      final info = await _channel.invokeMethod<Map<dynamic, dynamic>>('sdkInfo');
      final sdk = info?['sdkInt'] as int? ?? -1;
      final supported = info?['supported'] == true;
      if (!mounted) return;
      setState(() {
        _sdkInt = sdk;
        _supported = supported;
        _checking = false;
      });
      _logLine(
        supported
            ? 'OK: Android API $sdk (WifiNetworkSpecifier supported).'
            : 'BLOCKED: Android API $sdk — specifier needs API 29+. '
                'Checklist applies to the manual flow instead.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _supported = false;
      });
      _logLine('Could not read platform info: $e');
    }
  }

  void _logLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '${DateTime.now().toString().substring(11, 23)}  $line');
      if (_log.length > 40) _log.removeRange(40, _log.length);
    });
  }

  Future<void> _startConnect() async {
    final ssid = _ssidCtl.text.trim();
    if (ssid.isEmpty) {
      _manualNote = '';
      _logLine('Aborted: SSID is empty.');
      return;
    }
    _manualNote =
        'Manual check needed on the phone: was there a system "Connect to '
        'this network?" dialog, and AFTER confirming did any captive-portal / '
        '"Sign in to network" page auto-open?';
    _logLine('Requested connect to "$ssid"');
    setState(() {
      _stage = 'requesting';
      _state = const {};
      _probeFired = false;
    });
    _startPolling();
    try {
      await _channel.invokeMethod<void>('connectToAp', {'ssid': ssid});
    } on PlatformException catch (e) {
      _logLine('connectToAp failed (${e.code}): ${e.message}');
      setState(() => _stage = 'failed');
    } catch (e) {
      _logLine('connectToAp threw: $e');
      setState(() => _stage = 'failed');
    }
  }

  Future<void> _cancel() async {
    _stopPolling();
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (e) {
      _logLine('cancel threw: $e');
    }
    setState(() => _stage = 'cancelled');
    _logLine('Cancelled / binding released.');
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final Map<dynamic, dynamic>? st;
      try {
        st = await _channel.invokeMethod<Map<dynamic, dynamic>>('getState');
      } catch (e) {
        _logLine('poll threw: $e');
        return;
      }
      if (!mounted) return;
      final stage = st?['stage'] as String? ?? 'unknown';
      if (stage == 'available' && !_probeFired) {
        _probeFired = true;
        _logLine('Bound — firing diagnostic probeGateway(${_gatewayCtl.text.trim().isEmpty ? _defaultGateway : _gatewayCtl.text.trim()})');
        try {
          await _channel.invokeMethod<void>('probeGateway', {
            'gatewayUrl':
                _gatewayCtl.text.trim().isEmpty ? _defaultGateway : _gatewayCtl.text.trim(),
          });
        } catch (e) {
          _logLine('probeGateway threw: $e');
        }
      }
      if (stage != _stage) {
        _stage = stage;
        _logLine(
          'stage=$stage (${_stageLabel(stage)})'
          '${st?['httpStatus'] is int && (st?['httpStatus'] as int) > 0 ? ' http=${st?['httpStatus']}' : ''}'
          '${st?['error'] != null ? ' err=${st?['error']}' : ''}',
        );
        if (stage == 'http_ok' || stage == 'http_failed') _stopPolling();
      }
      setState(() => _state = st?.cast<String, dynamic>() ?? const {});
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  String _stageLabel(String stage) {
    switch (stage) {
      case 'idle':
        return 'not started';
      case 'requesting':
        return 'building specifier request';
      case 'awaiting_system':
        return 'awaiting user confirmation / system choice';
      case 'available':
        return 'onAvailable — bound; probe fires now';
      case 'probing':
        return 'probing gateway over bound network';
      case 'http_ok':
        return 'HTML probe OK';
      case 'http_failed':
        return 'probe failed';
      case 'unavailable':
        return 'no matching AP / request rejected';
      case 'lost':
        return 'connection dropped';
      case 'failed':
        return 'failure';
      case 'cancelled':
        return 'cancelled';
      default:
        return stage;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      backgroundColor: colors.well,
      appBar: AppBar(
        backgroundColor: colors.well,
        elevation: 0,
        title: Text(
          'AP-connect POC',
          style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700, color: colors.foam),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: _checking
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildBanner(colors),
                    const SizedBox(height: AppSpacing.lg),
                    _buildControls(colors),
                    const SizedBox(height: AppSpacing.lg),
                    _buildResults(colors),
                    const SizedBox(height: AppSpacing.lg),
                    _buildChecklist(colors),
                    const SizedBox(height: AppSpacing.lg),
                    _buildLog(colors),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildBanner(SteesColors colors) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        color: colors.sunlight.withValues(alpha: 0.12),
        border: Border.all(color: colors.sunlight.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, size: 18, color: colors.sunlight),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _supported
                  ? 'EXPERIMENTAL — Android API $_sdkInt. Isolated test only; '
                      'the real Add Device wizard is untouched.'
                  : 'UNSUPPORTED (Android API $_sdkInt). WifiNetworkSpecifier '
                      'needs API 29+ (Android 10). Still view the checklist for '
                      'the manual-flow comparison.',
              style: GoogleFonts.inter(fontSize: 11, color: colors.foam, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(SteesColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ssidCtl,
          enabled: _supported,
          style: TextStyle(color: colors.foam),
          decoration: InputDecoration(
            labelText: 'Device AP SSID',
            hintText: 'tasmota-XXXX',
            labelStyle: GoogleFonts.inter(fontSize: 12, color: colors.mist),
            filled: true,
            fillColor: colors.submerged,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide(color: colors.border),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _gatewayCtl,
          enabled: _supported,
          style: TextStyle(color: colors.foam),
          decoration: InputDecoration(
            labelText: 'Gateway URL to probe',
            labelStyle: GoogleFonts.inter(fontSize: 12, color: colors.mist),
            filled: true,
            fillColor: colors.submerged,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide(color: colors.border),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _supported && _stage != 'requesting'
                    ? _startConnect
                    : null,
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Run POC connection'),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.stream,
                  foregroundColor: colors.well,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(
              onPressed: _stage == 'requesting' ? _cancel : null,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResults(SteesColors colors) {
    final stage = _state['stage'] as String? ?? _stage;
    final status = _state['httpStatus'] as int? ?? -1;
    final elapsedAvailable = _state['elapsedToAvailableMs'] as int? ?? -1;
    final elapsedHttpGet = _state['elapsedToHttpGetMs'] as int? ?? -1;
    final bound = _state['bound'] == true;
    final httpOk = _state['httpOk'] == true;
    final sdk = _state['sdkInt'] as int? ?? -1;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        color: colors.submerged,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LIVE RESULT',
            style: GoogleFonts.sora(
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: colors.mist,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _row(colors, 'stage', '${_stageLabel(stage)} ($stage)'),
          _row(colors, 'SDK', sdk > 0 ? 'API $sdk' : '—'),
          _row(colors, 'onAvailable fired',
              bound ? 'yes (bound)' : (elapsedAvailable >= 0 ? 'yes' : 'no yet')),
          _row(colors, 'GET → 192.168.4.1',
              httpOk ? 'OK (HTTP $status)' : (status > 0 ? 'failed (HTTP $status)' : 'not attempted')),
          _row(colors, 'request → available', elapsedAvailable >= 0 ? '$elapsedAvailable ms' : '—'),
          _row(colors, 'request → probe', elapsedHttpGet >= 0 ? '$elapsedHttpGet ms' : '—'),
          if (_state['error'] != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'error: ${_state['error']}',
              style: GoogleFonts.inter(fontSize: 11, color: colors.danger, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(SteesColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: GoogleFonts.inter(fontSize: 11, color: colors.mist)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: colors.foam,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildChecklist(SteesColors colors) {
    final items = [
      'A system "Connect to this network?" confirmation dialog appears '
          '(expected, one-time). Tap Connect.',
      'After confirming, does any SEPARATE captive-portal / "Sign in to '
          'network" notification or auto-launched browser appear? '
          'THIS IS THE KEY OBSERVATION.',
      'The HTTP GET to 192.168.4.1 succeeds while the specifier-bound '
          'network is active (watch LIVE RESULT).',
      'Does normal internet access elsewhere get disrupted while the process '
          'is bound to the AP network?',
    ];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.borderActive),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MANUAL TEST CHECKLIST',
            style: GoogleFonts.sora(
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: colors.mist,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}.',
                      style: GoogleFonts.inter(fontSize: 11, color: colors.stream)),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(items[i],
                        style: GoogleFonts.inter(fontSize: 11, color: colors.foam, height: 1.4)),
                  ),
                ],
              ),
            ),
          if (_manualNote.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_manualNote,
                style: GoogleFonts.inter(fontSize: 11, color: colors.sunlight, height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _buildLog(SteesColors colors) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        color: const Color(0xFF0D1117),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'EVENT LOG (latest first)',
            style: GoogleFonts.sora(
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: colors.mist,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_log.isEmpty)
            Text('No events yet.',
                style: GoogleFonts.inter(fontSize: 11, color: colors.mist))
          else
            ..._log.map(
              (l) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(l,
                    maxLines: 3,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF9FE8A0))),
              ),
            ),
        ],
      ),
    );
  }
}