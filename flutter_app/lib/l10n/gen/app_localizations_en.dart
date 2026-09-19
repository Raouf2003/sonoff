// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'STEES';

  @override
  String get navDevices => 'Devices';

  @override
  String get navSensors => 'Sensors';

  @override
  String get navSchedules => 'Schedules';

  @override
  String get navRules => 'Rules';

  @override
  String get navWeather => 'Weather';

  @override
  String get appTagline => 'Smart Irrigation';

  @override
  String get actionToggleTheme => 'Toggle theme';

  @override
  String get actionLogout => 'Logout';

  @override
  String get actionLanguage => 'Language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageFrench => 'Français';

  @override
  String get sharedCancel => 'Cancel';

  @override
  String get sharedDelete => 'Delete';

  @override
  String get sharedEdit => 'Edit';

  @override
  String get sharedRemove => 'Remove';

  @override
  String get sharedOk => 'OK';

  @override
  String get sharedRetry => 'Retry';

  @override
  String get sharedAdd => 'Add';

  @override
  String get sharedClose => 'Close';

  @override
  String get sharedActive => 'Active';

  @override
  String get sharedOff => 'Off';

  @override
  String get sharedEnabled => 'Enabled';

  @override
  String get sharedDisabled => 'Disabled';

  @override
  String get sharedOnline => 'Online';

  @override
  String get sharedOffline => 'Offline';

  @override
  String get sharedDevice => 'Device';

  @override
  String get sharedChannel => 'Channel';

  @override
  String get sharedCheckConnection => 'Check your connection and try again.';

  @override
  String get sharedSomethingWrong => 'Something went wrong. Please try again.';

  @override
  String get sharedEveryDay => 'Every day';

  @override
  String get sharedEveryDayWord => 'every day';

  @override
  String get sharedToday => 'Today';

  @override
  String get sharedTomorrow => 'Tomorrow';

  @override
  String get sharedSaveChanges => 'Save Changes';

  @override
  String get sharedSelectChannel => 'Select at least one channel';

  @override
  String get sharedSignedOut =>
      'You appear to be signed out. Sign in again and retry.';

  @override
  String get sharedNoDevices => 'No devices yet';

  @override
  String sharedScheduleCount(String range, int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n schedules',
      one: '1 schedule',
    );
    return '$range  ·  $_temp0';
  }

  @override
  String sharedCustomDays(String days) {
    return 'Custom: $days';
  }

  @override
  String sharedIdValue(String id) {
    return 'ID: $id';
  }

  @override
  String sharedDeviceValue(String name) {
    return 'Device: $name';
  }

  @override
  String sharedSensorValue(String name) {
    return 'Sensor: $name';
  }

  @override
  String sharedChannelRange(int channels) {
    return 'CH1–CH$channels';
  }

  @override
  String zoneName(int index) {
    return 'Zone $index';
  }

  @override
  String channelCode(int index) {
    return 'CHANNEL $index';
  }

  @override
  String get channelPumpValve => 'Pump / Solenoid Valve';

  @override
  String get authFillAll => 'Fill in all fields';

  @override
  String get authUsername => 'Username';

  @override
  String get authPassword => 'Password';

  @override
  String get authConfirmPassword => 'Confirm Password';

  @override
  String get authSignIn => 'Sign In';

  @override
  String get authSignUp => 'Sign Up';

  @override
  String get authCreateAccount => 'Create Account';

  @override
  String get authJoinStees => 'Join STEES';

  @override
  String get authHaveAccount => 'Already have an account?  ';

  @override
  String get authNoAccount => 'Don\'t have an account?  ';

  @override
  String get authPwdMismatch => 'Passwords do not match';

  @override
  String get authPwdShort => 'Password must be at least 6 characters';

  @override
  String get devRelayBusy => 'Device is busy, try again';

  @override
  String get devRelayUnreachable => 'Could not reach the device';

  @override
  String devNoResponse(String channels) {
    return '$channels did not respond';
  }

  @override
  String get devFetchStatus => 'Failed to fetch status';

  @override
  String get devDeleteTitle => 'Delete Device';

  @override
  String get devDeleteConfirm =>
      'Are you sure you want to delete this device?\nYou can claim it again after deletion.';

  @override
  String get devDeleted => 'Device deleted.';

  @override
  String get devDeleteFailed =>
      'Could not delete the device. Check your connection and try again.';

  @override
  String get devLoadFailed => 'Could not load devices';

  @override
  String get devEmptyHint =>
      'Claim a Sonoff controller to start\nmanaging your irrigation zones.';

  @override
  String get devAdd => 'Add Device';

  @override
  String get devSectionTitle => 'DEVICES';

  @override
  String get devZonesTitle => 'ZONES';

  @override
  String get devSchedulesBtn => 'Schedules';

  @override
  String get devLan => 'LAN';

  @override
  String get devLanOnly => 'LAN ONLY';

  @override
  String get devSyncing => 'SYNCING';

  @override
  String get devTurningOn => 'TURNING ON…';

  @override
  String get devTurningOff => 'TURNING OFF…';

  @override
  String get devTurning => 'TURNING…';

  @override
  String get devOfflineBadge => 'OFFLINE';

  @override
  String get devFlowing => 'FLOWING';

  @override
  String get devDry => 'DRY';

  @override
  String get senLoadFailed => 'Could not load sensors';

  @override
  String get senEmptyTitle => 'No sensors yet';

  @override
  String get senEmptyHint =>
      'Add a soil moisture sensor to\nmonitor your irrigation zones.';

  @override
  String get senAdd => 'Add Sensor';

  @override
  String get senSection => 'SENSORS';

  @override
  String get senRuleBtn => 'Rule';

  @override
  String get schOfflineBanner =>
      'Device offline — schedules will sync automatically once it reconnects.';

  @override
  String get schSaved => 'Schedule saved';

  @override
  String get schDeleted => 'Schedule deleted';

  @override
  String get schUpdateFailed => 'Could not update the schedule';

  @override
  String get schDeleteFailed => 'Could not delete the schedule';

  @override
  String get schDeleteTitle => 'Delete schedule?';

  @override
  String schDeleteConfirm(String name) {
    return '\"$name\" will be removed.';
  }

  @override
  String get schLoadFailed => 'Could not load schedules';

  @override
  String get schEmptyDevicesHint => 'Claim a device to start scheduling.';

  @override
  String get schSection => 'SCHEDULES';

  @override
  String get schEmptyDevice => 'No schedules for this device';

  @override
  String schRangeInvalid(int index) {
    return 'Range $index: end must be after start (no overnight)';
  }

  @override
  String schConflict(String chans, String windows, String days) {
    return 'Schedule conflict: $chans is already scheduled $windows on $days.';
  }

  @override
  String schConflictNamed(
    String chans,
    String windows,
    String days,
    String name,
  ) {
    return 'Schedule conflict: $chans is already scheduled $windows on $days (\"$name\").';
  }

  @override
  String get schPickDay => 'Pick at least one day for custom recurrence';

  @override
  String get schSaveFailed => 'Could not save the schedule';

  @override
  String get schEditTitle => 'Edit Schedule';

  @override
  String get schNewTitle => 'New Schedule';

  @override
  String get schChannelsSection => 'CHANNELS';

  @override
  String get schChannelsDesc => 'Which outlets this schedule drives.';

  @override
  String get schRepeatsSection => 'REPEATS';

  @override
  String get schRepeatsDesc => 'When in the week this schedule runs.';

  @override
  String get schDaily => 'Daily';

  @override
  String get schCustomMode => 'Custom days';

  @override
  String get schWindowsSection => 'WINDOWS';

  @override
  String get schWindowsDesc =>
      'Channels are ON inside each window, OFF otherwise.';

  @override
  String get schAddWindow => 'Add window';

  @override
  String get schCreate => 'Create Schedule';

  @override
  String get schStarts => 'Starts';

  @override
  String get schEnds => 'Ends';

  @override
  String get schRemoveWindow => 'Remove window';

  @override
  String schWindowLabel(int index) {
    return 'W$index';
  }

  @override
  String get ruleUpdateFailed => 'Could not update the rule';

  @override
  String get ruleDeleteFailed => 'Could not delete the rule';

  @override
  String get ruleDeleteTitle => 'Delete rule?';

  @override
  String ruleDeleteConfirm(String name) {
    return '\"$name\" will be removed permanently.';
  }

  @override
  String get ruleNoSensors => 'No sensors available. Add a sensor first.';

  @override
  String get ruleChooseSensor => 'Choose a sensor';

  @override
  String get ruleChooseHint =>
      'Rules control relays based on this sensor\'s readings.';

  @override
  String get ruleLoadFailed => 'Could not load rules';

  @override
  String get ruleEmptyTitle => 'No rules yet';

  @override
  String ruleEmptyHint(String action) {
    return 'Tap \"$action\" to control a relay\nbased on a sensor\'s readings.';
  }

  @override
  String get ruleSection => 'RULES';

  @override
  String get ruleAdd => 'Add Rule';

  @override
  String get ruleAbove => 'above';

  @override
  String get ruleBelow => 'below';

  @override
  String ruleWhen(String cond, String threshold) {
    return 'When $cond $threshold';
  }

  @override
  String ruleActionTarget(String channels, String action) {
    return '$channels → $action';
  }

  @override
  String ruleOtherwise(String channels, String action) {
    return 'Otherwise → $channels → $action';
  }

  @override
  String get rfEnterName => 'Enter a rule name';

  @override
  String get rfEnterThreshold => 'Enter a numeric threshold';

  @override
  String get rfSaveFailed => 'Could not save the rule';

  @override
  String get rfEditTitle => 'Edit Rule';

  @override
  String get rfNewTitle => 'New Rule';

  @override
  String get rfIdentity => 'IDENTITY';

  @override
  String get rfNameHint => 'Rule name';

  @override
  String get rfNameHelper => 'e.g. Auto-water when dry';

  @override
  String get rfChannelsSection => 'CHANNELS';

  @override
  String get rfChannelsDesc => 'Pick every relay this rule should control.';

  @override
  String get rfConditionSection => 'CONDITION';

  @override
  String get rfConditionDesc => 'The sensor reading that triggers the rule.';

  @override
  String get rfBelow => 'Below';

  @override
  String get rfAbove => 'Above';

  @override
  String get rfThresholdHint => 'Threshold value';

  @override
  String get rfThresholdHelper => 'e.g. 30';

  @override
  String get rfActionSection => 'ACTION';

  @override
  String get rfActionDesc => 'What happens when the condition is true.';

  @override
  String get rfTurnOn => 'Turn ON';

  @override
  String get rfTurnOff => 'Turn OFF';

  @override
  String get actionOn => 'ON';

  @override
  String get actionOff => 'OFF';

  @override
  String get rfCreate => 'Create Rule';

  @override
  String get rfLogic => 'LOGIC';

  @override
  String rfIf(String cond, String threshold) {
    return 'IF soil $cond $threshold';
  }

  @override
  String get rfOtherwise => 'OTHERWISE';

  @override
  String get srUpdateFailed => 'Failed to update rule';

  @override
  String get srDeleteFailed => 'Failed to delete rule';

  @override
  String get srLoadFailed => 'Could not load the rule';

  @override
  String get srEmptyTitle => 'No rule yet';

  @override
  String get srEmptyHint =>
      'Create a rule to automatically control a relay based on this sensor\'s readings.';

  @override
  String get srTitle => 'Rule';

  @override
  String srElse(String channels, String action) {
    return 'Else → $channels → $action';
  }

  @override
  String get slLoadFailed => 'Failed to load schedules';

  @override
  String get slUpdateFailed => 'Failed to update schedule';

  @override
  String get slDeleteFailed => 'Failed to delete schedule';

  @override
  String get slTitle => 'Schedules';

  @override
  String slChannels(String channels) {
    return 'Channels: $channels';
  }

  @override
  String get wLoadFailed => 'Could not load weather.';

  @override
  String get wNoDevicesHint => 'Claim a device to enable weather forecasts.';

  @override
  String get wLoadTitle => 'Could not load weather';

  @override
  String get wSection => 'WEATHER';

  @override
  String get wRefresh => 'Refresh';

  @override
  String get wNoLocation => 'Weather location not configured';

  @override
  String get wNoLocationHint =>
      'This device does not have a farm location yet. Select a location on the map to enable weather for this device.';

  @override
  String get wFeatForecast => 'Local\nforecast';

  @override
  String get wFeatAdvisories => 'Rain\nadvisories';

  @override
  String get wFeatUnaffected => 'Schedules\nunaffected';

  @override
  String get wSetLocation => 'Set Location';

  @override
  String wPinDefaults(String tz) {
    return 'Pin defaults to your current location • $tz';
  }

  @override
  String get wForecastUnavailable => 'Forecast unavailable';

  @override
  String get wForecastHint =>
      'Your irrigation schedules are unaffected and will run as programmed.';

  @override
  String get wPrecipitation => 'Precipitation';

  @override
  String get wLastHour => 'Last hour';

  @override
  String get wCurrent => 'CURRENT CONDITIONS';

  @override
  String get wTemperature => 'Temperature';

  @override
  String get wNoHourly => 'No hourly data for this day.';

  @override
  String get wSignificantRain => 'Significant rain: ≥2 mm with ≥50% chance';

  @override
  String get wForecast => 'FORECAST';

  @override
  String get wRainDuring => 'Rain during irrigation';

  @override
  String get wRainNear => 'Rain near irrigation';

  @override
  String get wIrrigation => 'Irrigation';

  @override
  String get wRain => 'Rain';

  @override
  String get wDirectOverlap => 'Direct overlap';

  @override
  String wDirectOverlapWith(String duration) {
    return 'Direct overlap · $duration';
  }

  @override
  String get wCloseToWindow => 'Close to irrigation window';

  @override
  String wAlsoNear(String windows) {
    return 'Also near: $windows';
  }

  @override
  String wMoreOverlaps(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n more overlaps',
      one: '1 more overlap',
    );
    return '+$_temp0 same day';
  }

  @override
  String get wReviewSchedule => 'Review Schedule';

  @override
  String get hourNow => 'NOW';

  @override
  String get unitMm => 'mm';

  @override
  String get wNoSchedules => 'No irrigation schedules for this device.';

  @override
  String get wTodayIrrigation => 'TODAY’S IRRIGATION';

  @override
  String wDurationMin(int minutes) {
    return '~$minutes min';
  }

  @override
  String wDurationHour(int h) {
    return '~$h h';
  }

  @override
  String wDurationHourMin(int h, int m) {
    return '~$h h $m min';
  }

  @override
  String wRainChip(String start, String end, String mm, String prob) {
    return 'Rain $start–$end · $mm mm · $prob%';
  }

  @override
  String wUpdated(String time, String tz) {
    return 'Updated $time · $tz';
  }

  @override
  String get pkRemoveTitle => 'Remove location?';

  @override
  String get pkRemoveConfirm =>
      'Weather forecasts will be disabled for this device. Your irrigation schedules are unaffected.';

  @override
  String get pkTitle => 'Select weather location';

  @override
  String get pkTapHint => 'Tap map or drag pin';

  @override
  String get pkTapChoose => 'Tap the map to choose the farm location';

  @override
  String get pkResolving => 'Resolving place…';

  @override
  String get pkCustom => 'Custom map point';

  @override
  String get pkUseFor => 'Use for device';

  @override
  String get pkSaving => 'Saving…';

  @override
  String get pkConfirm => 'Confirm Location';

  @override
  String get pkRemoveFailed => 'Could not remove location.';

  @override
  String get pkChooseFirst => 'Tap the map to choose a location first.';

  @override
  String get pkSaveFailed => 'Could not save location.';

  @override
  String get pvTitle => 'Provision Device';

  @override
  String get pvReconnect => 'Reconnect device Wi-Fi';

  @override
  String get pvJoinNetwork => 'Join the device network';

  @override
  String get pvStep1 => 'STEP 1 OF 3';

  @override
  String get pvStep1a =>
      'Power on the device — its setup network starts with \"tasmota-\" or shows its device ID.';

  @override
  String get pvStep1bJoin => 'Join tasmota-XXXX in Wi-Fi Settings.';

  @override
  String get pvStep1bPick => 'Pick that network from the list below.';

  @override
  String get pvStep1bOpen => 'Open Wi-Fi Settings and join that network.';

  @override
  String get pvStep1cRecovery =>
      'Return here — your device ID is kept; this is a Wi-Fi correction, not a new registration.';

  @override
  String get pvStep1cNormal => 'Return here and continue.';

  @override
  String get pvSelectAp => 'Select Device Wi-Fi';

  @override
  String get pvContinue => 'Continue';

  @override
  String get pvDeviceNetwork => 'Device network';

  @override
  String get pvJoinAp => 'Join Device Network';

  @override
  String get pvOpenSettings => 'Open Wi-Fi Settings';

  @override
  String get pvNotFoundHint =>
      'If you do not find the device, turn Wi-Fi off and back on, then try again. If you still do not find it, turn the device’s power off and on rapidly 6 to 7 times to reset it.';

  @override
  String get pvSearchAgain => 'Search Again';

  @override
  String get pvRecoveryBtn => 'Recovery Instructions';

  @override
  String get pvRecoveryTitle => 'Recovery steps';

  @override
  String get pvRecoverySteps =>
      '1. Power-cycle the device and wait 30 seconds for its setup AP (tasmota-XXXX) to appear.\n\n2. Open Wi-Fi Settings and connect to the tasmota-XXXX network.\n\n3. Return here and tap Continue.\n\n4. Make sure the home Wi-Fi name and password are correct, then tap Provision Device.';

  @override
  String get pvConfigure => 'Configure the device';

  @override
  String get pvStep2 => 'STEP 2 OF 3';

  @override
  String get pvHomeWifi => 'HOME WI-FI';

  @override
  String get pvSsidHint => 'Network name (SSID)';

  @override
  String get pvWifiPwdHint => 'Wi-Fi Password';

  @override
  String get pvWrongPwd => 'Wrong password. Check it and try again.';

  @override
  String get pvDeviceSection => 'DEVICE';

  @override
  String get pvDeviceNameHint => 'Device Name';

  @override
  String get pvDeviceIdLbl => 'Device ID';

  @override
  String get pvDeviceIdPending => 'read from the device when it connects';

  @override
  String get pvMac => 'MAC';

  @override
  String get pvWifiFailed => 'Wi-Fi connection failed';

  @override
  String get pvWifiFailedGeneric =>
      'The device couldn\'t connect to this Wi-Fi network. Check the Wi-Fi name and password and try again.';

  @override
  String get pvWifiFailedHint =>
      'Your device is still connected to the setup Wi-Fi, so you can correct the credentials and test again.';

  @override
  String get pvTryAgain => 'Try Again';

  @override
  String get pvChangeWifi => 'Change Wi-Fi';

  @override
  String get pvTestContinue => 'Test Wi-Fi & Continue';

  @override
  String get pvTestingWifi =>
      'Testing Wi-Fi connection…\nPlease keep your phone connected to the device.';

  @override
  String get pvWifiNetworkLbl => 'Wi-Fi Network';

  @override
  String get pvSelectWifi => 'Select Wi-Fi network';

  @override
  String get pvWaiting => 'Waiting for device';

  @override
  String get pvStep3 => 'STEP 3 OF 3';

  @override
  String get pvWaitHint =>
      'The device will join your Wi-Fi and connect to the cloud automatically.';

  @override
  String get pvReconfigure => 'Reconfigure Wi-Fi';

  @override
  String get pvWaitLonger => 'Wait a bit longer';

  @override
  String get pvWaitLongerHint =>
      'You can also power-cycle the device so it reconnects, then continue waiting here.';

  @override
  String get pvLocalNotReady => 'Local control not ready';

  @override
  String get pvPreparingLocal => 'Preparing local control…';

  @override
  String get pvLocalSection => 'LOCAL CONTROL';

  @override
  String get pvEnabling => 'ENABLING…';

  @override
  String get pvLocalAddedHint =>
      'The device is already added to your account — you can control it through the cloud while local control is pending. Retry enables direct local control without claiming the device again.';

  @override
  String get pvLocalAddedBody =>
      'The device has been added to your account. Enabling direct local control…';

  @override
  String get pvRetryLocal => 'Retry Local Control';

  @override
  String get pvContinueBg => 'Continue in background';

  @override
  String get pvTerminalAdded => 'Device Already Added';

  @override
  String get pvTerminalRegistered => 'Device Already Registered';

  @override
  String get pvTerminalUnreadable => 'Device identity not readable';

  @override
  String get pvTerminalGeneric => 'Device is not connected yet';

  @override
  String get pvPhaseConnect => 'Connect';

  @override
  String get pvPhaseConfigure => 'Configure';

  @override
  String get pvPhaseWait => 'Wait';

  @override
  String get pvWaitRebooting => 'REBOOTING';

  @override
  String get pvWaitJoining => 'JOINING WI-FI';

  @override
  String get pvWaitMqtt => 'CONNECTING TO MQTT';

  @override
  String get pvWaitDetected => 'DEVICE DETECTED';

  @override
  String get pvWaitVerifying => 'VERIFYING';

  @override
  String get pvWaitClaiming => 'CLAIMING';

  @override
  String get pvWaitFinalizing => 'FINALIZING';

  @override
  String get pvWaitDone => 'DONE';

  @override
  String get pvWaitFailed => 'FAILED';

  @override
  String get pvWaitWaiting => 'WAITING';

  @override
  String get pvChecklistReboot => 'Device rebooting...';

  @override
  String get pvChecklistWifi => 'Joining your Wi-Fi...';

  @override
  String get pvChecklistCloud => 'Connecting to cloud...';

  @override
  String get pvSelectWifiTitle => 'Select Wi-Fi Network';

  @override
  String get pvRescan => 'Rescan';

  @override
  String get pvScanUnavailable =>
      'Wi-Fi scan unavailable. Enter your network manually.';

  @override
  String get pvNoNetworks => 'No Wi-Fi networks found.';

  @override
  String get pvScanTimeout => 'Wi-Fi scan timed out. Tap refresh to try again.';

  @override
  String get pvEnterManual => 'Enter network manually';

  @override
  String get pvSelectApTitle => 'Select Device Wi-Fi';

  @override
  String get pvTapAp => 'Tap your device’s setup network below to connect.';

  @override
  String get pvScanUnavailableSettings =>
      'Wi-Fi scan unavailable. Use Open Wi-Fi Settings instead.';

  @override
  String get pvNoNetworksNearby => 'No Wi-Fi networks found nearby.';

  @override
  String get pvLocationOff =>
      'Android hides nearby Wi-Fi networks from apps until Location is turned on.';

  @override
  String get pvTurnOnLocation => 'Turn on Location';

  @override
  String get pvPermDenied =>
      'Wi-Fi scanning needs this app’s location permission.';

  @override
  String get pvAllowSettings => 'Allow in App Settings';

  @override
  String get pvDeviceNets => 'DEVICE SETUP NETWORKS';

  @override
  String get pvOtherNets => 'OTHER WI-FI NETWORKS';

  @override
  String get pvApChip => 'DEVICE';

  @override
  String get pvManualJoin =>
      'Manual: join the device\'s network in Android settings yourself';

  @override
  String get pvDetectedTap => 'Detected — tap to connect';

  @override
  String pvSignalLine(String signal, String id) {
    return '$signal signal  ·  ID …$id';
  }

  @override
  String get pvSignalStrong => 'Strong';

  @override
  String get pvSignalGood => 'Good';

  @override
  String get pvSignalFair => 'Fair';

  @override
  String get pvSignalWeak => 'Weak';

  @override
  String pvSweepHeader(int step, int total, String name) {
    return 'Step $step/$total — $name';
  }

  @override
  String pvSweepBusy(String name, int step, int total, int secs) {
    return 'Configuring device — step $step/$total ($name) · ${secs}s';
  }

  @override
  String get pvEnterDeviceName => 'Enter a Device Name.';

  @override
  String get pvEnterHomeWifi => 'Select or enter your home Wi-Fi network.';

  @override
  String get pvDeviceUnreachable =>
      'The device is not reachable on its setup Wi-Fi anymore. It likely already connected to your home network; power-cycle it and, if it reconnects instead of showing the tasmota-XXXX AP, factory-reset it (hold its button ~10s), then try again.';

  @override
  String get pvIdentityUnreadable =>
      'The device\'s identity couldn\'t be read. Power-cycle the device and try again.';

  @override
  String get pvIdentityLost => 'Device identity was lost. Please try again.';

  @override
  String get pvReachStees => 'Could not reach STEES. Waiting and retrying…';

  @override
  String get pvAlreadyExists =>
      'The device already exists. You must delete it before claiming it again.';

  @override
  String get pvAlreadyRegistered =>
      'This device is already registered to another account and cannot be added to this one.';

  @override
  String get pvInvalidMac =>
      'The device didn\'t report its identity correctly. Close this window and try again.';

  @override
  String get pvBadRequest =>
      'This device could not be registered with STEES. Close and try again.';

  @override
  String get pvAccessDenied => 'Access was denied. Sign in again and retry.';

  @override
  String get pvSteesRejected =>
      'STEES rejected this device. Close and try again.';

  @override
  String get pvNotSeen =>
      'The device is not on the cloud yet. Waiting and retrying…';

  @override
  String get pvRateLimited =>
      'Too many requests to STEES. Waiting a moment and retrying…';

  @override
  String get pvSteesBusy => 'STEES was busy. Waiting and retrying…';

  @override
  String get pvNoLongerConnected =>
      'You’re no longer connected to the device setup network — reconnect to it and continue.';

  @override
  String pvSettingRetry(String step) {
    return 'The device didn’t accept a setting (failed step: $step). It’s still reachable — try again.';
  }

  @override
  String pvSettingReset(String step) {
    return 'The device did not accept all settings (failed step: $step). Power-cycle it (hold its button ~10s to factory-reset if it no longer shows the tasmota-XXXX access point), then try again.';
  }

  @override
  String pvConnectingTo(String ssid, int secs) {
    return 'Connecting to $ssid… (${secs}s)';
  }

  @override
  String pvCheckingDevice(int secs) {
    return 'Checking device… (${secs}s)';
  }

  @override
  String pvApLost(String ssid) {
    return 'The connection to \"$ssid\" was dropped before setup could start. Stay close to the device and try again.';
  }

  @override
  String get pvBindFailed =>
      'The phone couldn’t route traffic to the device network. Toggle Wi-Fi off/on, then try again.';

  @override
  String pvApTimeout(String ssid) {
    return 'The system took too long to join \"$ssid\". Make sure the device is powered on and in pairing mode, then try again.';
  }

  @override
  String pvApFailed(String ssid) {
    return 'Could not connect to the device setup network $ssid. Make sure the device is powered on and in setup mode. If the join prompt was declined or the AP is password-protected, use Open Wi-Fi Settings instead.';
  }

  @override
  String get pvDefaultName => 'STEES Smart Device';

  @override
  String get pvLocalFallback =>
      'Local HTTP control could not be enabled and verified on the device. Make sure this phone is on the same Wi-Fi as the device, then try again.';

  @override
  String get pvLocalUnknownIp =>
      'The device address is not known to this phone yet — make sure it is on the same Wi-Fi network as the device, then retry.';

  @override
  String pvDiagBadIp(String ip) {
    return 'The backend-reported LAN IP $ip was invalid.';
  }

  @override
  String pvDiagDiscovery(String detail) {
    return 'Local discovery failed ($detail). Make sure this phone is on the same Wi-Fi as the device.';
  }

  @override
  String get pvDiagNoEndpoint =>
      'No local HTTP endpoint was reachable for the device. Make sure this phone is on the same Wi-Fi as the device, then try again.';

  @override
  String pvDiagRejected(String detail) {
    return 'The device rejected or did not confirm the SetOption128 enable ($detail).';
  }

  @override
  String get pvDiagHttpApi =>
      'The device did not confirm its HTTP API is enabled (StatusNET.HTTP_API != 1). Restart the wizard or check the device console.';

  @override
  String pvDiagFinalCheck(String detail) {
    return 'The final referer-less state check failed ($detail).';
  }

  @override
  String get pvBrokerFailed =>
      'Could not load the MQTT broker address. Reopen Add Device while you have an internet connection.';

  @override
  String get pvBrokerLoadFailed =>
      'Could not load the MQTT broker address from the backend. Make sure you are online, then reopen Add Device.';

  @override
  String get pvWifiSettingsFailed => 'Could not open Wi-Fi settings.';

  @override
  String get pvNoIp =>
      'The device connected to the network but did not receive an IP address. The Wi-Fi name and password are correct; check that the network allows new devices.';

  @override
  String get pvSsidNotFound =>
      'The device could not find this Wi-Fi network. Check the Wi-Fi name and try again.';

  @override
  String get pvWrongPasswordMsg =>
      'The device could not connect to this Wi-Fi network. The Wi-Fi password may be incorrect.';

  @override
  String get pvLocalError =>
      'The device didn\'t respond to the Wi-Fi test. Make sure your phone is still connected to the device Wi-Fi and try again.';

  @override
  String get pvWifiVerified => 'Wi-Fi connection verified.';

  @override
  String get pvWifiUnknown =>
      'The device couldn\'t connect to this Wi-Fi network. Check the Wi-Fi name and password and try again.';

  @override
  String get pvGettingReady => 'Getting ready…';

  @override
  String get pvConnecting => 'Connecting to device';

  @override
  String get pvReconnecting => 'Reconnecting to device';

  @override
  String get pvConfiguring => 'Configuring device';

  @override
  String get pvTesting => 'Testing Wi-Fi connection…';

  @override
  String get pvWifiFailedShort => 'Wi-Fi connection failed';

  @override
  String get pvWifiVerifiedShort => 'Wi-Fi verified';

  @override
  String get pvRestarting => 'Connecting device to Wi-Fi…';

  @override
  String get pvRebooting => 'Rebooting device…';

  @override
  String get pvConnectingMqtt => 'Connecting device to MQTT…';

  @override
  String get pvRegistering => 'Registering device…';

  @override
  String get pvEnablingLocal => 'Enabling local control…';

  @override
  String get pvWaitingWifi => 'Waiting for your Wi-Fi…';

  @override
  String get pvDeviceReady => 'Device ready';

  @override
  String get pvProvisionFailed => 'Provisioning failed';

  @override
  String get pvCancelled => 'Cancelled';

  @override
  String get pvSweepWifiTest => 'wifi-test';

  @override
  String get pvSweepBroker => 'broker';

  @override
  String get pvSweepTopic => 'topic';

  @override
  String get pvSweepModule => 'module';

  @override
  String get pvSweepName => 'name';

  @override
  String get pvSweepSsid => 'ssid';

  @override
  String get pvSweepVerify => 'verify';

  @override
  String get pvSweepRestart => 'restart';

  @override
  String get pvTryDifferent => 'Try a different network';

  @override
  String get pvShowPassword => 'Show password';

  @override
  String get pvHidePassword => 'Hide password';

  @override
  String get adWifiOff => 'Wi-Fi is off';

  @override
  String get adWifiOffHint =>
      'Your phone needs Wi-Fi turned on to find and join the device’s setup network.';

  @override
  String get adTurnOn => 'Turn on Wi-Fi';

  @override
  String get adTitle => 'Add Device';

  @override
  String get adHeading => 'Add a device';

  @override
  String get adGuided => 'GUIDED SETUP';

  @override
  String get adWizardHint =>
      'Wi-Fi must be turned on on your phone — the wizard needs it to find and join the device’s setup network.';

  @override
  String get adProvision => 'Provision New Device';

  @override
  String get asEnterNameId => 'Enter a Sensor Name and Sensor ID';

  @override
  String get asSelectDevice => 'Select the Sonoff device for this sensor';

  @override
  String get asAdded => 'Sensor connected successfully.';

  @override
  String get asAddedHint => 'Your sensor is now linked to the Sonoff device.';

  @override
  String get asCheckId =>
      'Check the Sensor ID and make sure the ESP32 is connected.';

  @override
  String get asNotFound => 'Sensor not found';

  @override
  String get asTitle => 'Add Sensor';

  @override
  String get asLink => 'LINK A SENSOR';

  @override
  String get asLinkHint =>
      'The sensor will be verified on MQTT before it is added. Make sure your ESP32 is powered on so it can be found.';

  @override
  String get asDetails => 'Sensor details';

  @override
  String get asDetailsHint =>
      'Enter the Sensor ID exactly as configured on the device, then choose which Sonoff controller it belongs to.';

  @override
  String get asNameHint => 'Sensor Name';

  @override
  String get asNameHelper => 'e.g. Soil Moisture';

  @override
  String get asIdHint => 'Sensor ID';

  @override
  String get asIdHelper => 'e.g. soil_1';

  @override
  String get asSearching => 'Searching for sensor...';

  @override
  String get asSearchingHint =>
      'Waiting for the sensor to report on MQTT. This can take a few seconds.';

  @override
  String get asDeviceLbl => 'Device';

  @override
  String get asNoDevices => 'No Sonoff devices yet';

  @override
  String get asSelectHint => 'Select the Sonoff device';

  @override
  String get asDeviceHelper => 'e.g. Greenhouse Sonoff';

  @override
  String get apiTimeout => 'The request timed out. Please try again.';

  @override
  String get apiUnreachable =>
      'Could not reach the server. Check your connection.';

  @override
  String get apiSignup => 'Signup failed';

  @override
  String get apiLogin => 'Login failed';

  @override
  String get apiFetchDevices => 'Failed to fetch devices';

  @override
  String get apiRegisterDevice => 'Could not register the device';

  @override
  String get apiCheckDevice => 'Could not check device';

  @override
  String get apiCheckDeviceStatus => 'Could not check device status';

  @override
  String get apiFetchStatus => 'Failed to fetch status';

  @override
  String get apiBrokerInfo => 'Could not load broker info';

  @override
  String get apiBrokerHost => 'Broker info missing a host';

  @override
  String get apiBrokerPort => 'Broker info missing a port';

  @override
  String get apiControl => 'Control failed';

  @override
  String get apiUnclaim => 'Failed to unclaim device';

  @override
  String get apiDeleteDevice => 'Failed to delete device';

  @override
  String get apiFetchSensors => 'Failed to fetch sensors';

  @override
  String get apiAddSensor => 'Failed to add sensor';

  @override
  String get apiDeleteSensor => 'Failed to delete sensor';

  @override
  String get apiFetchRules => 'Failed to fetch rules';

  @override
  String get apiCreateRule => 'Failed to create rule';

  @override
  String get apiUpdateRule => 'Failed to update rule';

  @override
  String get apiToggleRule => 'Failed to toggle rule';

  @override
  String get apiDeleteRule => 'Failed to delete rule';

  @override
  String get apiFetchSchedules => 'Failed to fetch schedules';

  @override
  String get apiCreateSchedule => 'Failed to create schedule';

  @override
  String get apiUpdateSchedule => 'Failed to update schedule';

  @override
  String get apiToggleSchedule => 'Failed to toggle schedule';

  @override
  String get apiDeleteSchedule => 'Failed to delete schedule';

  @override
  String get apiSendMqtt => 'Failed to send MQTT command';

  @override
  String get apiLoadWeather => 'Failed to load weather';

  @override
  String get apiLoadAdvisories => 'Failed to load advisories';

  @override
  String get apiUpdateLocation => 'Failed to update location';

  @override
  String get apiRemoveLocation => 'Failed to remove location';

  @override
  String get apiRegisterToken => 'Failed to register push token';

  @override
  String get apiDeleteToken => 'Failed to delete push token';

  @override
  String get apiAuthRequired => 'username and password are required';

  @override
  String get apiUsernameShort => 'username must be at least 3 characters';

  @override
  String get apiPasswordShort => 'password must be at least 6 characters';

  @override
  String get apiUsernameTaken => 'username already taken';

  @override
  String get apiInvalidCredentials => 'Invalid username or password';

  @override
  String get apiAuthHeader => 'Missing or invalid Authorization header';

  @override
  String get apiTokenExpired => 'Invalid or expired token';

  @override
  String get apiServerError => 'Internal server error';

  @override
  String get apiNotOwner => 'You do not own this device';

  @override
  String get apiDeviceNotOwned => 'Device not found or not owned by you';

  @override
  String get apiDeviceNotFound => 'Device not found';

  @override
  String get apiRuleNotFound => 'Rule not found';

  @override
  String get apiScheduleNotFound => 'Schedule not found';

  @override
  String get apiSensorNotFound => 'Sensor not found';

  @override
  String get apiSensorIdTaken => 'This Sensor ID is already added';

  @override
  String get apiSensorNotFoundDetail =>
      'Sensor not found. Make sure the ESP32 is online and the Sensor ID is correct.';

  @override
  String get apiSensorIdInvalid =>
      'sensorId must be 1-40 characters (letters, numbers, _ . -)';

  @override
  String get apiSensorRequired => 'name, sensorId, and deviceId are required';

  @override
  String get ntChannel => 'STEES Weather';

  @override
  String get ntChannelDesc =>
      'Rain overlap advisories — alerts when irrigation overlaps forecast rain';

  @override
  String get ntRainExpected => 'Rain expected';

  @override
  String get ntCheckSchedule => 'Check your irrigation schedule';

  @override
  String get relayTypeOne => '1 Relay';

  @override
  String get relayTypeFour => '4 Relays';
}
