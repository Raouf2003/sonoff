import 'package:flutter_test/flutter_test.dart';
import 'package:stees_local/connection/ap_connector.dart';

void main() {
  test('tasmota networks sort first, then strongest signal', () {
    final sorted = sortNetworks(const [
      WifiNetwork(name: 'HomeNet', rssi: -40),
      WifiNetwork(name: 'tasmota-AB12CD', rssi: -80),
      WifiNetwork(name: 'TASMOTA-weak', rssi: -90),
      WifiNetwork(name: 'Cafe', rssi: -60),
      WifiNetwork(name: '34987AC30304', rssi: -70),
    ]);
    expect(sorted.map((n) => n.name).toList(), [
      '34987AC30304',
      'tasmota-AB12CD',
      'TASMOTA-weak',
      'HomeNet',
      'Cafe',
    ]);
  });

  test('looksLikeTasmota is a hint only', () {
    expect(const WifiNetwork(name: 'tasmota-1').looksLikeTasmota, isTrue);
    expect(const WifiNetwork(name: 'Tasmota-XYZ').looksLikeTasmota, isTrue);
    expect(const WifiNetwork(name: 'AABBCCDDEEFF').looksLikeTasmota, isTrue);
    expect(const WifiNetwork(name: 'HomeNet').looksLikeTasmota, isFalse);
  });
}
