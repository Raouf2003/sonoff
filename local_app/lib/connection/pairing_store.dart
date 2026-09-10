import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../devices/device_profile.dart';

const String _kPairedMac = 'stees_local.paired_mac';
const String _kDeviceName = 'stees_local.device_name';
const String _kApSsid = 'stees_local.ap_ssid';
const String _kDeviceProfile = 'stees_local.device_profile';
const String _kWebPassword = 'stees_local.web_password';
const Duration _secureBudget = Duration(seconds: 5);

class PairingStore {
  PairingStore({
    Future<SharedPreferences> Function()? prefs,
    FlutterSecureStorage? secure,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _secure = secure ?? const FlutterSecureStorage();

  final Future<SharedPreferences> Function() _prefs;
  final FlutterSecureStorage _secure;

  Future<void> savePairing({
    required String mac,
    required String name,
    String? apSsid,
    String? profileId,
  }) async {
    final prefs = await _prefs();
    await prefs.setString(_kPairedMac, mac);
    await prefs.setString(_kDeviceName, name);
    if (apSsid != null && apSsid.isNotEmpty) {
      await prefs.setString(_kApSsid, apSsid);
    }
    if (profileId != null && profileId.isNotEmpty) {
      await prefs.setString(_kDeviceProfile, profileId);
    }
  }

  Future<void> saveApSsid(String ssid) async {
    if (ssid.isEmpty) return;
    await (await _prefs()).setString(_kApSsid, ssid);
  }

  Future<String?> pairedMac() async => (await _prefs()).getString(_kPairedMac);
  Future<String?> deviceName() async => (await _prefs()).getString(_kDeviceName);
  Future<String?> apSsid() async => (await _prefs()).getString(_kApSsid);

  Future<DeviceProfile> deviceProfile() async {
    final prefs = await _prefs();
    return DeviceProfile.fromId(prefs.getString(_kDeviceProfile));
  }

  Future<void> savePassword(String password) {
    return _secure
        .write(key: _kWebPassword, value: password)
        .timeout(_secureBudget, onTimeout: () {});
  }

  Future<String?> password() {
    try {
      return _secure
          .read(key: _kWebPassword)
          .timeout(_secureBudget, onTimeout: () => null);
    } catch (_) {
      return Future.value();
    }
  }

  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_kPairedMac);
    await prefs.remove(_kDeviceName);
    await prefs.remove(_kApSsid);
    try {
      await _secure.delete(key: _kWebPassword);
    } catch (_) {}
  }
}
