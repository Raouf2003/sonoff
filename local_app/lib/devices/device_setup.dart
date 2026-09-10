import 'device_profile.dart';
import 'device_repository.dart';

Future<bool> applyProfileTemplate(
  LocalDeviceRepository repository,
  String deviceId,
  DeviceProfile profile, {
  String? password,
}) async {
  final template = profile.tasmotaTemplate;
  if (template == null || template.isEmpty) return false;
  final payload = Uri.encodeComponent(template);
  await repository.runDeviceCommand(deviceId, 'Template%20$payload', password: password);
  await repository.runDeviceCommand(deviceId, 'Module%200', password: password);
  try {
    await repository.runDeviceCommand(deviceId, 'Restart%201', password: password);
  } catch (_) {}
  return true;
}

Future<void> applyFourChannelTemplate(
  LocalDeviceRepository repository,
  String deviceId, {
  String? password,
}) async {
  await applyProfileTemplate(repository, deviceId, DeviceProfile.sonoff4chProR3, password: password);
}
