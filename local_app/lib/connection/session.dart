import 'package:flutter/foundation.dart';
import 'pairing_store.dart';

class Session {
  const Session({required this.mac, required this.name, this.password, required this.profileId});
  final String mac;
  final String name;
  final String? password;
  final String profileId;
}

class SessionState extends ChangeNotifier {
  SessionState({PairingStore? pairing}) : _pairing = pairing ?? PairingStore();

  final PairingStore _pairing;
  Session? _session;
  bool _loaded = false;

  Session? get session => _session;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final mac = await _pairing.pairedMac();
      if (mac != null && mac.isNotEmpty) {
        final name = await _pairing.deviceName() ?? 'Sonoff 4CH';
        final password = await _pairing.password();
        final profile = await _pairing.deviceProfile();
        _session = Session(
          mac: mac,
          name: name,
          password: password == null || password.isEmpty ? null : password,
          profileId: profile.id,
        );
      }
    } catch (_) {
      _session = null;
    }
    _loaded = true;
    notifyListeners();
  }

  void establish(Session session) {
    _session = session;
    _loaded = true;
    notifyListeners();
  }

  Future<void> clear() async {
    try {
      await _pairing.clear();
    } catch (_) {}
    _session = null;
    notifyListeners();
  }
}
