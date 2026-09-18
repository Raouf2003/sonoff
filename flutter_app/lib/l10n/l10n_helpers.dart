import 'package:intl/intl.dart';

import 'gen/app_localizations.dart';
import '../services/api_service.dart';
import '../services/device_repository_service.dart';
import '../services/provisioning_service.dart';

/// Localized counterpart of [provisionUserLabel] (provisioning_service.dart).
///
/// The pure English function is kept for logging/tests; UI code must use this
/// so the wizard step labels follow the app locale.
String provisionUserLabelL10n(ProvisionState state, AppLocalizations l10n) {
  switch (state) {
    case ProvisionState.idle:
      return l10n.pvGettingReady;
    case ProvisionState.connectingToAp:
    case ProvisionState.apConnected:
      return l10n.pvConnecting;
    case ProvisionState.recoveryRequired:
      return l10n.pvReconnecting;
    case ProvisionState.configuringBroker:
    case ProvisionState.configuringIdentity:
    case ProvisionState.verifyingIdentity:
    case ProvisionState.configuringWifi:
    case ProvisionState.readyToRestart:
      return l10n.pvConfiguring;
    case ProvisionState.configuringWifiTest:
      return l10n.pvTesting;
    case ProvisionState.wifiTestFailed:
      return l10n.pvWifiFailedShort;
    case ProvisionState.wifiTestSucceeded:
      return l10n.pvWifiVerifiedShort;
    case ProvisionState.restarting:
    case ProvisionState.waitingForWifi:
      return l10n.pvRestarting;
    case ProvisionState.waitingForReboot:
      return l10n.pvRebooting;
    case ProvisionState.waitingForMqtt:
      return l10n.pvConnectingMqtt;
    case ProvisionState.deviceDetected:
    case ProvisionState.verifyingPossession:
    case ProvisionState.claiming:
      return l10n.pvRegistering;
    case ProvisionState.settingUpLocalControl:
      return l10n.pvEnablingLocal;
    case ProvisionState.localSetupWaiting:
      return l10n.pvWaitingWifi;
    case ProvisionState.completed:
      return l10n.pvDeviceReady;
    case ProvisionState.failed:
      return l10n.pvProvisionFailed;
    case ProvisionState.cancelled:
      return l10n.pvCancelled;
  }
}

/// Localized counterpart of [wifiTestMessage] (provisioning_service.dart).
String wifiTestMessageL10n(WifiTestResult result, AppLocalizations l10n) {
  switch (result) {
    case WifiTestResult.noIp:
      return l10n.pvNoIp;
    case WifiTestResult.ssidNotFound:
      return l10n.pvSsidNotFound;
    case WifiTestResult.wrongPassword:
      return l10n.pvWrongPasswordMsg;
    case WifiTestResult.localError:
      return l10n.pvLocalError;
    case WifiTestResult.success:
      return l10n.pvWifiVerified;
    case WifiTestResult.unknown:
      return l10n.pvWifiUnknown;
  }
}

/// Localized signal-strength word for a 0..3 bar bucket (see `rssiBars`).
String signalStrengthLabel(int bars, AppLocalizations l10n) {
  return switch (bars) {
    3 => l10n.pvSignalStrong,
    2 => l10n.pvSignalGood,
    1 => l10n.pvSignalFair,
    _ => l10n.pvSignalWeak,
  };
}

/// Localized configure-sweep step name for the technical slug in `_sweepSteps`.
String sweepStepName(String slug, AppLocalizations l10n) {
  return switch (slug) {
    'wifi-test' => l10n.pvSweepWifiTest,
    'broker' => l10n.pvSweepBroker,
    'topic' => l10n.pvSweepTopic,
    'module' => l10n.pvSweepModule,
    'name' => l10n.pvSweepName,
    'ssid' => l10n.pvSweepSsid,
    'verify' => l10n.pvSweepVerify,
    'restart' => l10n.pvSweepRestart,
    _ => slug,
  };
}

/// Short weekday name for a Monday-based [index] (0 = Monday .. 6 = Sunday),
/// formatted in [localeName] (e.g. `DateFormat.E('ar')`).
String weekdayLabel(int index, String localeName) {
  final monday = DateTime(2024, 1, 1).add(Duration(days: index.clamp(0, 6)));
  return DateFormat.E(localeName).format(monday);
}

/// Short month name for [month] (1..12) in [localeName].
String monthLabel(int month, String localeName) {
  final m = month.clamp(1, 12);
  return DateFormat.MMM(localeName).format(DateTime(2024, m, 1));
}

/// Maps an [ApiException] (or any other error) to a user-safe, localized
/// message WITHOUT changing the backend contract.
///
/// - Transport codes (`TIMEOUT`, network failures) map to localized strings.
/// - Known client-side fallback messages (the English literals ApiService uses
///   when the backend supplies no message) map to their localized equivalents.
/// - Anything else (server-supplied `error`/`message` bodies, validation text
///   from the backend) is returned verbatim: the Flutter app does not translate
///   server-generated content.
String friendlyError(Object e, AppLocalizations l10n) {
  if (e is! ApiException) return l10n.sharedSomethingWrong;
  switch (e.code) {
    case 'TIMEOUT':
      return l10n.apiTimeout;
    case 'NETWORK_ERROR':
      return l10n.apiUnreachable;
  }
  return _localizedFallback(e.message, l10n) ?? e.message;
}

/// Localized diagnostic for a claim-time local HTTP setup failure, keyed by
/// [kind] (see `LocalSetupErrorKind`) so technical identifiers (IPs, Tasmota
/// option names) stay intact while the surrounding prose is translated.
/// Falls back to [fallback] when the kind is unknown.
String localSetupErrorMessage(
  LocalSetupErrorKind? kind,
  String? detail,
  AppLocalizations l10n,
  String fallback,
) {
  return switch (kind) {
    LocalSetupErrorKind.badReportedIp => l10n.pvDiagBadIp(detail ?? ''),
    LocalSetupErrorKind.discoveryFailed => l10n.pvDiagDiscovery(detail ?? ''),
    LocalSetupErrorKind.noEndpoint => l10n.pvDiagNoEndpoint,
    LocalSetupErrorKind.enableRejected => l10n.pvDiagRejected(detail ?? ''),
    LocalSetupErrorKind.httpApiUnconfirmed => l10n.pvDiagHttpApi,
    LocalSetupErrorKind.finalCheckFailed => l10n.pvDiagFinalCheck(detail ?? ''),
    null => fallback,
  };
}

String? _localizedFallback(String message, AppLocalizations l10n) {
  return switch (message) {
    'The request timed out. Please try again.' => l10n.apiTimeout,
    'Could not reach the server. Check your connection.' =>
      l10n.apiUnreachable,
    'Signup failed' => l10n.apiSignup,
    'Login failed' => l10n.apiLogin,
    'Failed to fetch devices' => l10n.apiFetchDevices,
    'Could not register the device' => l10n.apiRegisterDevice,
    'Could not check device' => l10n.apiCheckDevice,
    'Could not check device status' => l10n.apiCheckDeviceStatus,
    'Failed to fetch status' => l10n.apiFetchStatus,
    'Could not load broker info' => l10n.apiBrokerInfo,
    'Broker info missing a host' => l10n.apiBrokerHost,
    'Broker info missing a port' => l10n.apiBrokerPort,
    'Control failed' => l10n.apiControl,
    'Failed to unclaim device' => l10n.apiUnclaim,
    'Failed to delete device' => l10n.apiDeleteDevice,
    'Failed to fetch sensors' => l10n.apiFetchSensors,
    'Failed to add sensor' => l10n.apiAddSensor,
    'Failed to delete sensor' => l10n.apiDeleteSensor,
    'Failed to fetch rules' => l10n.apiFetchRules,
    'Failed to create rule' => l10n.apiCreateRule,
    'Failed to update rule' => l10n.apiUpdateRule,
    'Failed to toggle rule' => l10n.apiToggleRule,
    'Failed to delete rule' => l10n.apiDeleteRule,
    'Failed to fetch schedules' => l10n.apiFetchSchedules,
    'Failed to create schedule' => l10n.apiCreateSchedule,
    'Failed to update schedule' => l10n.apiUpdateSchedule,
    'Failed to toggle schedule' => l10n.apiToggleSchedule,
    'Failed to delete schedule' => l10n.apiDeleteSchedule,
    'Failed to send MQTT command' => l10n.apiSendMqtt,
    'Failed to load weather' => l10n.apiLoadWeather,
    'Failed to load advisories' => l10n.apiLoadAdvisories,
    'Failed to update location' => l10n.apiUpdateLocation,
    'Failed to remove location' => l10n.apiRemoveLocation,
    'Failed to register push token' => l10n.apiRegisterToken,
    'Failed to delete push token' => l10n.apiDeleteToken,
    'Something went wrong. Please try again.' => l10n.sharedSomethingWrong,
    _ => null,
  };
}
