import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

class ApConnectionException implements Exception {
  const ApConnectionException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

class ApNetworkInfo {
  const ApNetworkInfo({
    required this.bound,
    required this.wifi,
    required this.internet,
    required this.validated,
    this.activeSsid,
    this.matched,
  });
  final bool bound;
  final bool wifi;
  final bool internet;
  final bool validated;
  final String? activeSsid;
  final bool? matched;

  factory ApNetworkInfo.fromMap(Map<dynamic, dynamic> map) {
    return ApNetworkInfo(
      bound: map['bound'] == true,
      wifi: map['wifi'] == true,
      internet: map['internet'] == true,
      validated: map['validated'] == true,
      activeSsid: map['activeSsid'] as String?,
      matched: map['matched'] as bool?,
    );
  }
}

class WifiNetwork {
  const WifiNetwork({required this.name, this.rssi, this.bssid});
  final String name;
  final int? rssi;
  final String? bssid;

  bool get looksLikeTasmota {
    final lower = name.toLowerCase();
    return lower.startsWith('tasmota') ||
        lower.startsWith('trelay') ||
        lower.startsWith('t-relay') ||
        RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(name.trim());
  }
}

List<WifiNetwork> sortNetworks(List<WifiNetwork> networks) {
  final sorted = List<WifiNetwork>.from(networks);
  sorted.sort((a, b) {
    final ta = a.looksLikeTasmota ? 0 : 1;
    final tb = b.looksLikeTasmota ? 0 : 1;
    if (ta != tb) return ta.compareTo(tb);
    return (b.rssi ?? -999).compareTo(a.rssi ?? -999);
  });
  return sorted;
}

class WifiScanResult {
  const WifiScanResult({required this.available, required this.networks, this.reason});
  final bool available;
  final List<WifiNetwork> networks;
  final String? reason;
}

class ApConnector {
  ApConnector({
    MethodChannel? bindChannel,
    MethodChannel? apChannel,
    MethodChannel? settingsChannel,
  })  : _bind = bindChannel ?? const MethodChannel('stees/wifi_binding'),
        _ap = apChannel ?? const MethodChannel('stees/ap_connect'),
        _settings = settingsChannel ?? const MethodChannel('stees/wifi_settings');

  final MethodChannel _bind;
  final MethodChannel _ap;
  final MethodChannel _settings;

  Future<ApNetworkInfo> ensureBound(String expectedSsid) async {
    try {
      final raw = await _bind.invokeMethod<Map<dynamic, dynamic>>(
        'ensureBoundToActiveWifi',
        {'expectedSsid': expectedSsid},
      );
      if (raw == null) throw const ApConnectionException('No network state returned.');
      return ApNetworkInfo.fromMap(raw);
    } on MissingPluginException {
      throw const ApConnectionException(
        'Wi-Fi binding is only available on Android.',
        code: 'UNSUPPORTED',
      );
    } on PlatformException catch (e) {
      throw ApConnectionException(e.message ?? 'Wi-Fi binding failed.', code: e.code);
    }
  }

  Future<void> releaseBinding() async {
    try {
      await _bind.invokeMethod<void>('releaseWifiBinding');
    } on MissingPluginException {
      return;
    } catch (e) {
      debugPrint('[LOCAL][AP] release binding failed: $e');
    }
  }

  Future<ApNetworkInfo> networkInfo() async {
    try {
      final raw = await _bind.invokeMethod<Map<dynamic, dynamic>>('getNetworkInfo');
      if (raw == null) throw const ApConnectionException('No network state returned.');
      return ApNetworkInfo.fromMap(raw);
    } on MissingPluginException {
      throw const ApConnectionException(
        'Wi-Fi state is only available on Android.',
        code: 'UNSUPPORTED',
      );
    }
  }

  Future<String> connectToAp(String ssid) async {
    try {
      final raw = await _ap.invokeMethod<Map<dynamic, dynamic>>(
        'connectToAp',
        {'ssid': ssid},
      );
      return (raw?['stage'] ?? 'unknown').toString();
    } on MissingPluginException {
      throw const ApConnectionException(
        'Programmatic AP join is only available on Android 10+.',
        code: 'UNSUPPORTED',
      );
    } on PlatformException catch (e) {
      throw ApConnectionException(e.message ?? 'AP join failed.', code: e.code);
    }
  }

  Future<void> cancelApConnect() async {
    try {
      await _ap.invokeMethod<void>('cancel');
    } on MissingPluginException {
      return;
    } catch (e) {
      debugPrint('[LOCAL][AP] cancel failed: $e');
    }
  }

  Future<WifiScanResult> scanWifi({Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final raw = await _settings
          .invokeMethod<Map<dynamic, dynamic>>('scanWifi')
          .timeout(timeout);
      if (raw == null) {
        return const WifiScanResult(available: false, networks: [], reason: 'no response');
      }
      final list = raw['networks'];
      final networks = <WifiNetwork>[];
      if (list is List) {
        for (final e in list) {
          if (e is Map) {
            final name = '${e['name'] ?? ''}'.trim();
            if (name.isEmpty) continue;
            final rssi = e['rssi'];
            networks.add(WifiNetwork(
              name: name,
              rssi: rssi is int ? rssi : int.tryParse('$rssi'),
              bssid: e['bssid']?.toString(),
            ));
          } else if (e is String && e.trim().isNotEmpty) {
            networks.add(WifiNetwork(name: e.trim()));
          }
        }
      }
      return WifiScanResult(
        available: raw['available'] == true,
        networks: sortNetworks(networks),
        reason: raw['reason']?.toString(),
      );
    } on MissingPluginException {
      return const WifiScanResult(available: false, networks: [], reason: 'unsupported platform');
    } on TimeoutException catch (e) {
      debugPrint('[LOCAL][SCAN] timeout: $e');
      return const WifiScanResult(available: false, networks: [], reason: 'scan timed out');
    } on PlatformException catch (e) {
      return WifiScanResult(available: false, networks: [], reason: e.message);
    }
  }

  Future<void> openWifiSettings() async {
    try {
      await _settings.invokeMethod<void>('openWifiSettings');
    } on MissingPluginException {
      throw const ApConnectionException(
        'Wi-Fi settings can only be opened on Android.',
        code: 'UNSUPPORTED',
      );
    }
  }
}
