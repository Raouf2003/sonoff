import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('fr'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'STEES'**
  String get appTitle;

  /// No description provided for @navDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get navDevices;

  /// No description provided for @navSensors.
  ///
  /// In en, this message translates to:
  /// **'Sensors'**
  String get navSensors;

  /// No description provided for @navSchedules.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get navSchedules;

  /// No description provided for @navRules.
  ///
  /// In en, this message translates to:
  /// **'Rules'**
  String get navRules;

  /// No description provided for @navWeather.
  ///
  /// In en, this message translates to:
  /// **'Weather'**
  String get navWeather;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'Smart Irrigation'**
  String get appTagline;

  /// No description provided for @actionToggleTheme.
  ///
  /// In en, this message translates to:
  /// **'Toggle theme'**
  String get actionToggleTheme;

  /// No description provided for @actionLogout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get actionLogout;

  /// No description provided for @actionLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get actionLanguage;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageArabic.
  ///
  /// In en, this message translates to:
  /// **'العربية'**
  String get languageArabic;

  /// No description provided for @languageFrench.
  ///
  /// In en, this message translates to:
  /// **'Français'**
  String get languageFrench;

  /// No description provided for @sharedCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sharedCancel;

  /// No description provided for @sharedDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sharedDelete;

  /// No description provided for @sharedEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get sharedEdit;

  /// No description provided for @sharedRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get sharedRemove;

  /// No description provided for @sharedOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get sharedOk;

  /// No description provided for @sharedRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get sharedRetry;

  /// No description provided for @sharedAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get sharedAdd;

  /// No description provided for @sharedClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get sharedClose;

  /// No description provided for @sharedActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get sharedActive;

  /// No description provided for @sharedOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get sharedOff;

  /// No description provided for @sharedEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get sharedEnabled;

  /// No description provided for @sharedDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get sharedDisabled;

  /// No description provided for @sharedOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get sharedOnline;

  /// No description provided for @sharedOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get sharedOffline;

  /// No description provided for @sharedDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get sharedDevice;

  /// No description provided for @sharedChannel.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get sharedChannel;

  /// No description provided for @sharedCheckConnection.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get sharedCheckConnection;

  /// No description provided for @sharedSomethingWrong.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get sharedSomethingWrong;

  /// No description provided for @sharedEveryDay.
  ///
  /// In en, this message translates to:
  /// **'Every day'**
  String get sharedEveryDay;

  /// No description provided for @sharedEveryDayWord.
  ///
  /// In en, this message translates to:
  /// **'every day'**
  String get sharedEveryDayWord;

  /// No description provided for @sharedToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get sharedToday;

  /// No description provided for @sharedTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow'**
  String get sharedTomorrow;

  /// No description provided for @sharedSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save Changes'**
  String get sharedSaveChanges;

  /// No description provided for @sharedSelectChannel.
  ///
  /// In en, this message translates to:
  /// **'Select at least one channel'**
  String get sharedSelectChannel;

  /// No description provided for @sharedSignedOut.
  ///
  /// In en, this message translates to:
  /// **'You appear to be signed out. Sign in again and retry.'**
  String get sharedSignedOut;

  /// No description provided for @sharedNoDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices yet'**
  String get sharedNoDevices;

  /// Device schedule subtitle: channel range plus schedule count
  ///
  /// In en, this message translates to:
  /// **'{range}  ·  {n, plural, =1{1 schedule} other{{n} schedules}}'**
  String sharedScheduleCount(String range, int n);

  /// No description provided for @sharedCustomDays.
  ///
  /// In en, this message translates to:
  /// **'Custom: {days}'**
  String sharedCustomDays(String days);

  /// No description provided for @sharedIdValue.
  ///
  /// In en, this message translates to:
  /// **'ID: {id}'**
  String sharedIdValue(String id);

  /// No description provided for @sharedDeviceValue.
  ///
  /// In en, this message translates to:
  /// **'Device: {name}'**
  String sharedDeviceValue(String name);

  /// No description provided for @sharedSensorValue.
  ///
  /// In en, this message translates to:
  /// **'Sensor: {name}'**
  String sharedSensorValue(String name);

  /// No description provided for @sharedChannelRange.
  ///
  /// In en, this message translates to:
  /// **'CH1–CH{channels}'**
  String sharedChannelRange(int channels);

  /// No description provided for @zoneName.
  ///
  /// In en, this message translates to:
  /// **'Zone {index}'**
  String zoneName(int index);

  /// No description provided for @channelCode.
  ///
  /// In en, this message translates to:
  /// **'CHANNEL {index}'**
  String channelCode(int index);

  /// No description provided for @authFillAll.
  ///
  /// In en, this message translates to:
  /// **'Fill in all fields'**
  String get authFillAll;

  /// No description provided for @authUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get authUsername;

  /// No description provided for @authPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPassword;

  /// No description provided for @authConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get authConfirmPassword;

  /// No description provided for @authSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get authSignIn;

  /// No description provided for @authSignUp.
  ///
  /// In en, this message translates to:
  /// **'Sign Up'**
  String get authSignUp;

  /// No description provided for @authCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get authCreateAccount;

  /// No description provided for @authJoinStees.
  ///
  /// In en, this message translates to:
  /// **'Join STEES'**
  String get authJoinStees;

  /// No description provided for @authHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Already have an account?  '**
  String get authHaveAccount;

  /// No description provided for @authNoAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account?  '**
  String get authNoAccount;

  /// No description provided for @authPwdMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get authPwdMismatch;

  /// No description provided for @authPwdShort.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 6 characters'**
  String get authPwdShort;

  /// No description provided for @devRelayBusy.
  ///
  /// In en, this message translates to:
  /// **'Device is busy, try again'**
  String get devRelayBusy;

  /// No description provided for @devRelayUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the device'**
  String get devRelayUnreachable;

  /// No description provided for @devNoResponse.
  ///
  /// In en, this message translates to:
  /// **'{channels} did not respond'**
  String devNoResponse(String channels);

  /// No description provided for @devFetchStatus.
  ///
  /// In en, this message translates to:
  /// **'Failed to fetch status'**
  String get devFetchStatus;

  /// No description provided for @devDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Device'**
  String get devDeleteTitle;

  /// No description provided for @devDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this device?\nYou can claim it again after deletion.'**
  String get devDeleteConfirm;

  /// No description provided for @devDeleted.
  ///
  /// In en, this message translates to:
  /// **'Device deleted.'**
  String get devDeleted;

  /// No description provided for @devDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the device. Check your connection and try again.'**
  String get devDeleteFailed;

  /// No description provided for @devLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load devices'**
  String get devLoadFailed;

  /// No description provided for @devEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Claim a Sonoff controller to start\nmanaging your irrigation zones.'**
  String get devEmptyHint;

  /// No description provided for @devAdd.
  ///
  /// In en, this message translates to:
  /// **'Add Device'**
  String get devAdd;

  /// No description provided for @devSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'DEVICES'**
  String get devSectionTitle;

  /// No description provided for @devZonesTitle.
  ///
  /// In en, this message translates to:
  /// **'ZONES'**
  String get devZonesTitle;

  /// No description provided for @devSchedulesBtn.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get devSchedulesBtn;

  /// No description provided for @devLan.
  ///
  /// In en, this message translates to:
  /// **'LAN'**
  String get devLan;

  /// No description provided for @devLanOnly.
  ///
  /// In en, this message translates to:
  /// **'LAN ONLY'**
  String get devLanOnly;

  /// No description provided for @devSyncing.
  ///
  /// In en, this message translates to:
  /// **'SYNCING'**
  String get devSyncing;

  /// No description provided for @devTurningOn.
  ///
  /// In en, this message translates to:
  /// **'TURNING ON…'**
  String get devTurningOn;

  /// No description provided for @devTurningOff.
  ///
  /// In en, this message translates to:
  /// **'TURNING OFF…'**
  String get devTurningOff;

  /// No description provided for @devTurning.
  ///
  /// In en, this message translates to:
  /// **'TURNING…'**
  String get devTurning;

  /// No description provided for @devOfflineBadge.
  ///
  /// In en, this message translates to:
  /// **'OFFLINE'**
  String get devOfflineBadge;

  /// No description provided for @devFlowing.
  ///
  /// In en, this message translates to:
  /// **'FLOWING'**
  String get devFlowing;

  /// No description provided for @devDry.
  ///
  /// In en, this message translates to:
  /// **'DRY'**
  String get devDry;

  /// No description provided for @senLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load sensors'**
  String get senLoadFailed;

  /// No description provided for @senEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No sensors yet'**
  String get senEmptyTitle;

  /// No description provided for @senEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Add a soil moisture sensor to\nmonitor your irrigation zones.'**
  String get senEmptyHint;

  /// No description provided for @senAdd.
  ///
  /// In en, this message translates to:
  /// **'Add Sensor'**
  String get senAdd;

  /// No description provided for @senSection.
  ///
  /// In en, this message translates to:
  /// **'SENSORS'**
  String get senSection;

  /// No description provided for @senRuleBtn.
  ///
  /// In en, this message translates to:
  /// **'Rule'**
  String get senRuleBtn;

  /// No description provided for @schOfflineBanner.
  ///
  /// In en, this message translates to:
  /// **'Device offline — schedules will sync automatically once it reconnects.'**
  String get schOfflineBanner;

  /// No description provided for @schSaved.
  ///
  /// In en, this message translates to:
  /// **'Schedule saved'**
  String get schSaved;

  /// No description provided for @schDeleted.
  ///
  /// In en, this message translates to:
  /// **'Schedule deleted'**
  String get schDeleted;

  /// No description provided for @schUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the schedule'**
  String get schUpdateFailed;

  /// No description provided for @schDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the schedule'**
  String get schDeleteFailed;

  /// No description provided for @schDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete schedule?'**
  String get schDeleteTitle;

  /// No description provided for @schDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" will be removed.'**
  String schDeleteConfirm(String name);

  /// No description provided for @schLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load schedules'**
  String get schLoadFailed;

  /// No description provided for @schEmptyDevicesHint.
  ///
  /// In en, this message translates to:
  /// **'Claim a device to start scheduling.'**
  String get schEmptyDevicesHint;

  /// No description provided for @schSection.
  ///
  /// In en, this message translates to:
  /// **'SCHEDULES'**
  String get schSection;

  /// No description provided for @schEmptyDevice.
  ///
  /// In en, this message translates to:
  /// **'No schedules for this device'**
  String get schEmptyDevice;

  /// No description provided for @schRangeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Range {index}: end must be after start (no overnight)'**
  String schRangeInvalid(int index);

  /// No description provided for @schConflict.
  ///
  /// In en, this message translates to:
  /// **'Schedule conflict: {chans} is already scheduled {windows} on {days}.'**
  String schConflict(String chans, String windows, String days);

  /// No description provided for @schConflictNamed.
  ///
  /// In en, this message translates to:
  /// **'Schedule conflict: {chans} is already scheduled {windows} on {days} (\"{name}\").'**
  String schConflictNamed(
    String chans,
    String windows,
    String days,
    String name,
  );

  /// No description provided for @schPickDay.
  ///
  /// In en, this message translates to:
  /// **'Pick at least one day for custom recurrence'**
  String get schPickDay;

  /// No description provided for @schSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the schedule'**
  String get schSaveFailed;

  /// No description provided for @schEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Schedule'**
  String get schEditTitle;

  /// No description provided for @schNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New Schedule'**
  String get schNewTitle;

  /// No description provided for @schChannelsSection.
  ///
  /// In en, this message translates to:
  /// **'CHANNELS'**
  String get schChannelsSection;

  /// No description provided for @schChannelsDesc.
  ///
  /// In en, this message translates to:
  /// **'Which outlets this schedule drives.'**
  String get schChannelsDesc;

  /// No description provided for @schRepeatsSection.
  ///
  /// In en, this message translates to:
  /// **'REPEATS'**
  String get schRepeatsSection;

  /// No description provided for @schRepeatsDesc.
  ///
  /// In en, this message translates to:
  /// **'When in the week this schedule runs.'**
  String get schRepeatsDesc;

  /// No description provided for @schDaily.
  ///
  /// In en, this message translates to:
  /// **'Daily'**
  String get schDaily;

  /// No description provided for @schCustomMode.
  ///
  /// In en, this message translates to:
  /// **'Custom days'**
  String get schCustomMode;

  /// No description provided for @schWindowsSection.
  ///
  /// In en, this message translates to:
  /// **'WINDOWS'**
  String get schWindowsSection;

  /// No description provided for @schWindowsDesc.
  ///
  /// In en, this message translates to:
  /// **'Channels are ON inside each window, OFF otherwise.'**
  String get schWindowsDesc;

  /// No description provided for @schAddWindow.
  ///
  /// In en, this message translates to:
  /// **'Add window'**
  String get schAddWindow;

  /// No description provided for @schCreate.
  ///
  /// In en, this message translates to:
  /// **'Create Schedule'**
  String get schCreate;

  /// No description provided for @schStarts.
  ///
  /// In en, this message translates to:
  /// **'Starts'**
  String get schStarts;

  /// No description provided for @schEnds.
  ///
  /// In en, this message translates to:
  /// **'Ends'**
  String get schEnds;

  /// No description provided for @schRemoveWindow.
  ///
  /// In en, this message translates to:
  /// **'Remove window'**
  String get schRemoveWindow;

  /// No description provided for @schWindowLabel.
  ///
  /// In en, this message translates to:
  /// **'W{index}'**
  String schWindowLabel(int index);

  /// No description provided for @ruleUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the rule'**
  String get ruleUpdateFailed;

  /// No description provided for @ruleDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the rule'**
  String get ruleDeleteFailed;

  /// No description provided for @ruleDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete rule?'**
  String get ruleDeleteTitle;

  /// No description provided for @ruleDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" will be removed permanently.'**
  String ruleDeleteConfirm(String name);

  /// No description provided for @ruleNoSensors.
  ///
  /// In en, this message translates to:
  /// **'No sensors available. Add a sensor first.'**
  String get ruleNoSensors;

  /// No description provided for @ruleChooseSensor.
  ///
  /// In en, this message translates to:
  /// **'Choose a sensor'**
  String get ruleChooseSensor;

  /// No description provided for @ruleChooseHint.
  ///
  /// In en, this message translates to:
  /// **'Rules control relays based on this sensor\'s readings.'**
  String get ruleChooseHint;

  /// No description provided for @ruleLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load rules'**
  String get ruleLoadFailed;

  /// No description provided for @ruleEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No rules yet'**
  String get ruleEmptyTitle;

  /// No description provided for @ruleEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Tap \"{action}\" to control a relay\nbased on a sensor\'s readings.'**
  String ruleEmptyHint(String action);

  /// No description provided for @ruleSection.
  ///
  /// In en, this message translates to:
  /// **'RULES'**
  String get ruleSection;

  /// No description provided for @ruleAdd.
  ///
  /// In en, this message translates to:
  /// **'Add Rule'**
  String get ruleAdd;

  /// No description provided for @ruleAbove.
  ///
  /// In en, this message translates to:
  /// **'above'**
  String get ruleAbove;

  /// No description provided for @ruleBelow.
  ///
  /// In en, this message translates to:
  /// **'below'**
  String get ruleBelow;

  /// No description provided for @ruleWhen.
  ///
  /// In en, this message translates to:
  /// **'When {cond} {threshold}'**
  String ruleWhen(String cond, String threshold);

  /// No description provided for @ruleActionTarget.
  ///
  /// In en, this message translates to:
  /// **'{channels} → {action}'**
  String ruleActionTarget(String channels, String action);

  /// No description provided for @ruleOtherwise.
  ///
  /// In en, this message translates to:
  /// **'Otherwise → {channels} → {action}'**
  String ruleOtherwise(String channels, String action);

  /// No description provided for @rfEnterName.
  ///
  /// In en, this message translates to:
  /// **'Enter a rule name'**
  String get rfEnterName;

  /// No description provided for @rfEnterThreshold.
  ///
  /// In en, this message translates to:
  /// **'Enter a numeric threshold'**
  String get rfEnterThreshold;

  /// No description provided for @rfSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the rule'**
  String get rfSaveFailed;

  /// No description provided for @rfEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Rule'**
  String get rfEditTitle;

  /// No description provided for @rfNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New Rule'**
  String get rfNewTitle;

  /// No description provided for @rfIdentity.
  ///
  /// In en, this message translates to:
  /// **'IDENTITY'**
  String get rfIdentity;

  /// No description provided for @rfNameHint.
  ///
  /// In en, this message translates to:
  /// **'Rule name'**
  String get rfNameHint;

  /// No description provided for @rfNameHelper.
  ///
  /// In en, this message translates to:
  /// **'e.g. Auto-water when dry'**
  String get rfNameHelper;

  /// No description provided for @rfChannelsSection.
  ///
  /// In en, this message translates to:
  /// **'CHANNELS'**
  String get rfChannelsSection;

  /// No description provided for @rfChannelsDesc.
  ///
  /// In en, this message translates to:
  /// **'Pick every relay this rule should control.'**
  String get rfChannelsDesc;

  /// No description provided for @rfConditionSection.
  ///
  /// In en, this message translates to:
  /// **'CONDITION'**
  String get rfConditionSection;

  /// No description provided for @rfConditionDesc.
  ///
  /// In en, this message translates to:
  /// **'The sensor reading that triggers the rule.'**
  String get rfConditionDesc;

  /// No description provided for @rfBelow.
  ///
  /// In en, this message translates to:
  /// **'Below'**
  String get rfBelow;

  /// No description provided for @rfAbove.
  ///
  /// In en, this message translates to:
  /// **'Above'**
  String get rfAbove;

  /// No description provided for @rfThresholdHint.
  ///
  /// In en, this message translates to:
  /// **'Threshold value'**
  String get rfThresholdHint;

  /// No description provided for @rfThresholdHelper.
  ///
  /// In en, this message translates to:
  /// **'e.g. 30'**
  String get rfThresholdHelper;

  /// No description provided for @rfActionSection.
  ///
  /// In en, this message translates to:
  /// **'ACTION'**
  String get rfActionSection;

  /// No description provided for @rfActionDesc.
  ///
  /// In en, this message translates to:
  /// **'What happens when the condition is true.'**
  String get rfActionDesc;

  /// No description provided for @rfTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn ON'**
  String get rfTurnOn;

  /// No description provided for @rfTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn OFF'**
  String get rfTurnOff;

  /// No description provided for @rfCreate.
  ///
  /// In en, this message translates to:
  /// **'Create Rule'**
  String get rfCreate;

  /// No description provided for @rfLogic.
  ///
  /// In en, this message translates to:
  /// **'LOGIC'**
  String get rfLogic;

  /// No description provided for @rfIf.
  ///
  /// In en, this message translates to:
  /// **'IF soil {cond} {threshold}'**
  String rfIf(String cond, String threshold);

  /// No description provided for @rfOtherwise.
  ///
  /// In en, this message translates to:
  /// **'OTHERWISE'**
  String get rfOtherwise;

  /// No description provided for @srUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update rule'**
  String get srUpdateFailed;

  /// No description provided for @srDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete rule'**
  String get srDeleteFailed;

  /// No description provided for @srLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the rule'**
  String get srLoadFailed;

  /// No description provided for @srEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No rule yet'**
  String get srEmptyTitle;

  /// No description provided for @srEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Create a rule to automatically control a relay based on this sensor\'s readings.'**
  String get srEmptyHint;

  /// No description provided for @srTitle.
  ///
  /// In en, this message translates to:
  /// **'Rule'**
  String get srTitle;

  /// No description provided for @srElse.
  ///
  /// In en, this message translates to:
  /// **'Else → {channels} → {action}'**
  String srElse(String channels, String action);

  /// No description provided for @slLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load schedules'**
  String get slLoadFailed;

  /// No description provided for @slUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update schedule'**
  String get slUpdateFailed;

  /// No description provided for @slDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete schedule'**
  String get slDeleteFailed;

  /// No description provided for @slTitle.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get slTitle;

  /// No description provided for @slChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels: {channels}'**
  String slChannels(String channels);

  /// No description provided for @wLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load weather.'**
  String get wLoadFailed;

  /// No description provided for @wNoDevicesHint.
  ///
  /// In en, this message translates to:
  /// **'Claim a device to enable weather forecasts.'**
  String get wNoDevicesHint;

  /// No description provided for @wLoadTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load weather'**
  String get wLoadTitle;

  /// No description provided for @wSection.
  ///
  /// In en, this message translates to:
  /// **'WEATHER'**
  String get wSection;

  /// No description provided for @wRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get wRefresh;

  /// No description provided for @wNoLocation.
  ///
  /// In en, this message translates to:
  /// **'Weather location not configured'**
  String get wNoLocation;

  /// No description provided for @wNoLocationHint.
  ///
  /// In en, this message translates to:
  /// **'This device does not have a farm location yet. Select a location on the map to enable weather for this device.'**
  String get wNoLocationHint;

  /// No description provided for @wFeatForecast.
  ///
  /// In en, this message translates to:
  /// **'Local\nforecast'**
  String get wFeatForecast;

  /// No description provided for @wFeatAdvisories.
  ///
  /// In en, this message translates to:
  /// **'Rain\nadvisories'**
  String get wFeatAdvisories;

  /// No description provided for @wFeatUnaffected.
  ///
  /// In en, this message translates to:
  /// **'Schedules\nunaffected'**
  String get wFeatUnaffected;

  /// No description provided for @wSetLocation.
  ///
  /// In en, this message translates to:
  /// **'Set Location'**
  String get wSetLocation;

  /// No description provided for @wPinDefaults.
  ///
  /// In en, this message translates to:
  /// **'Pin defaults to your current location • {tz}'**
  String wPinDefaults(String tz);

  /// No description provided for @wForecastUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Forecast unavailable'**
  String get wForecastUnavailable;

  /// No description provided for @wForecastHint.
  ///
  /// In en, this message translates to:
  /// **'Your irrigation schedules are unaffected and will run as programmed.'**
  String get wForecastHint;

  /// No description provided for @wPrecipitation.
  ///
  /// In en, this message translates to:
  /// **'Precipitation'**
  String get wPrecipitation;

  /// No description provided for @wLastHour.
  ///
  /// In en, this message translates to:
  /// **'Last hour'**
  String get wLastHour;

  /// No description provided for @wCurrent.
  ///
  /// In en, this message translates to:
  /// **'CURRENT CONDITIONS'**
  String get wCurrent;

  /// No description provided for @wTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get wTemperature;

  /// No description provided for @wNoHourly.
  ///
  /// In en, this message translates to:
  /// **'No hourly data for this day.'**
  String get wNoHourly;

  /// No description provided for @wSignificantRain.
  ///
  /// In en, this message translates to:
  /// **'Significant rain: ≥2 mm with ≥50% chance'**
  String get wSignificantRain;

  /// No description provided for @wForecast.
  ///
  /// In en, this message translates to:
  /// **'FORECAST'**
  String get wForecast;

  /// No description provided for @wRainDuring.
  ///
  /// In en, this message translates to:
  /// **'Rain during irrigation'**
  String get wRainDuring;

  /// No description provided for @wRainNear.
  ///
  /// In en, this message translates to:
  /// **'Rain near irrigation'**
  String get wRainNear;

  /// No description provided for @wIrrigation.
  ///
  /// In en, this message translates to:
  /// **'Irrigation'**
  String get wIrrigation;

  /// No description provided for @wRain.
  ///
  /// In en, this message translates to:
  /// **'Rain'**
  String get wRain;

  /// No description provided for @wDirectOverlap.
  ///
  /// In en, this message translates to:
  /// **'Direct overlap'**
  String get wDirectOverlap;

  /// No description provided for @wDirectOverlapWith.
  ///
  /// In en, this message translates to:
  /// **'Direct overlap · {duration}'**
  String wDirectOverlapWith(String duration);

  /// No description provided for @wCloseToWindow.
  ///
  /// In en, this message translates to:
  /// **'Close to irrigation window'**
  String get wCloseToWindow;

  /// No description provided for @wAlsoNear.
  ///
  /// In en, this message translates to:
  /// **'Also near: {windows}'**
  String wAlsoNear(String windows);

  /// No description provided for @wMoreOverlaps.
  ///
  /// In en, this message translates to:
  /// **'+{n, plural, =1{1 more overlap} other{{n} more overlaps}} same day'**
  String wMoreOverlaps(int n);

  /// No description provided for @wReviewSchedule.
  ///
  /// In en, this message translates to:
  /// **'Review Schedule'**
  String get wReviewSchedule;

  /// No description provided for @hourNow.
  ///
  /// In en, this message translates to:
  /// **'NOW'**
  String get hourNow;

  /// No description provided for @unitMm.
  ///
  /// In en, this message translates to:
  /// **'mm'**
  String get unitMm;

  /// No description provided for @wNoSchedules.
  ///
  /// In en, this message translates to:
  /// **'No irrigation schedules for this device.'**
  String get wNoSchedules;

  /// No description provided for @wTodayIrrigation.
  ///
  /// In en, this message translates to:
  /// **'TODAY’S IRRIGATION'**
  String get wTodayIrrigation;

  /// No description provided for @wDurationMin.
  ///
  /// In en, this message translates to:
  /// **'~{minutes} min'**
  String wDurationMin(int minutes);

  /// No description provided for @wDurationHour.
  ///
  /// In en, this message translates to:
  /// **'~{h} h'**
  String wDurationHour(int h);

  /// No description provided for @wDurationHourMin.
  ///
  /// In en, this message translates to:
  /// **'~{h} h {m} min'**
  String wDurationHourMin(int h, int m);

  /// No description provided for @wRainChip.
  ///
  /// In en, this message translates to:
  /// **'Rain {start}–{end} · {mm} mm · {prob}%'**
  String wRainChip(String start, String end, String mm, String prob);

  /// No description provided for @wUpdated.
  ///
  /// In en, this message translates to:
  /// **'Updated {time} · {tz}'**
  String wUpdated(String time, String tz);

  /// No description provided for @pkRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove location?'**
  String get pkRemoveTitle;

  /// No description provided for @pkRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Weather forecasts will be disabled for this device. Your irrigation schedules are unaffected.'**
  String get pkRemoveConfirm;

  /// No description provided for @pkTitle.
  ///
  /// In en, this message translates to:
  /// **'Select weather location'**
  String get pkTitle;

  /// No description provided for @pkTapHint.
  ///
  /// In en, this message translates to:
  /// **'Tap map or drag pin'**
  String get pkTapHint;

  /// No description provided for @pkTapChoose.
  ///
  /// In en, this message translates to:
  /// **'Tap the map to choose the farm location'**
  String get pkTapChoose;

  /// No description provided for @pkResolving.
  ///
  /// In en, this message translates to:
  /// **'Resolving place…'**
  String get pkResolving;

  /// No description provided for @pkCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom map point'**
  String get pkCustom;

  /// No description provided for @pkUseFor.
  ///
  /// In en, this message translates to:
  /// **'Use for device'**
  String get pkUseFor;

  /// No description provided for @pkSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get pkSaving;

  /// No description provided for @pkConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm Location'**
  String get pkConfirm;

  /// No description provided for @pkRemoveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove location.'**
  String get pkRemoveFailed;

  /// No description provided for @pkChooseFirst.
  ///
  /// In en, this message translates to:
  /// **'Tap the map to choose a location first.'**
  String get pkChooseFirst;

  /// No description provided for @pkSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save location.'**
  String get pkSaveFailed;

  /// No description provided for @pvTitle.
  ///
  /// In en, this message translates to:
  /// **'Provision Device'**
  String get pvTitle;

  /// No description provided for @pvReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect device Wi-Fi'**
  String get pvReconnect;

  /// No description provided for @pvJoinNetwork.
  ///
  /// In en, this message translates to:
  /// **'Join the device network'**
  String get pvJoinNetwork;

  /// No description provided for @pvStep1.
  ///
  /// In en, this message translates to:
  /// **'STEP 1 OF 3'**
  String get pvStep1;

  /// No description provided for @pvStep1a.
  ///
  /// In en, this message translates to:
  /// **'Power on the device — its setup network starts with \"tasmota-\" or shows its device ID.'**
  String get pvStep1a;

  /// No description provided for @pvStep1bJoin.
  ///
  /// In en, this message translates to:
  /// **'Join tasmota-XXXX in Wi-Fi Settings.'**
  String get pvStep1bJoin;

  /// No description provided for @pvStep1bPick.
  ///
  /// In en, this message translates to:
  /// **'Pick that network from the list below.'**
  String get pvStep1bPick;

  /// No description provided for @pvStep1bOpen.
  ///
  /// In en, this message translates to:
  /// **'Open Wi-Fi Settings and join that network.'**
  String get pvStep1bOpen;

  /// No description provided for @pvStep1cRecovery.
  ///
  /// In en, this message translates to:
  /// **'Return here — your device ID is kept; this is a Wi-Fi correction, not a new registration.'**
  String get pvStep1cRecovery;

  /// No description provided for @pvStep1cNormal.
  ///
  /// In en, this message translates to:
  /// **'Return here and continue.'**
  String get pvStep1cNormal;

  /// No description provided for @pvSelectAp.
  ///
  /// In en, this message translates to:
  /// **'Select Device Wi-Fi'**
  String get pvSelectAp;

  /// No description provided for @pvContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get pvContinue;

  /// No description provided for @pvDeviceNetwork.
  ///
  /// In en, this message translates to:
  /// **'Device network'**
  String get pvDeviceNetwork;

  /// No description provided for @pvJoinAp.
  ///
  /// In en, this message translates to:
  /// **'Join Device Network'**
  String get pvJoinAp;

  /// No description provided for @pvOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Wi-Fi Settings'**
  String get pvOpenSettings;

  /// No description provided for @pvNotFoundHint.
  ///
  /// In en, this message translates to:
  /// **'If you do not find the device, turn Wi-Fi off and back on, then try again. If you still do not find it, turn the device’s power off and on rapidly 6 to 7 times to reset it.'**
  String get pvNotFoundHint;

  /// No description provided for @pvSearchAgain.
  ///
  /// In en, this message translates to:
  /// **'Search Again'**
  String get pvSearchAgain;

  /// No description provided for @pvRecoveryBtn.
  ///
  /// In en, this message translates to:
  /// **'Recovery Instructions'**
  String get pvRecoveryBtn;

  /// No description provided for @pvRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery steps'**
  String get pvRecoveryTitle;

  /// No description provided for @pvRecoverySteps.
  ///
  /// In en, this message translates to:
  /// **'1. Power-cycle the device and wait 30 seconds for its setup AP (tasmota-XXXX) to appear.\n\n2. Open Wi-Fi Settings and connect to the tasmota-XXXX network.\n\n3. Return here and tap Continue.\n\n4. Make sure the home Wi-Fi name and password are correct, then tap Provision Device.'**
  String get pvRecoverySteps;

  /// No description provided for @pvConfigure.
  ///
  /// In en, this message translates to:
  /// **'Configure the device'**
  String get pvConfigure;

  /// No description provided for @pvStep2.
  ///
  /// In en, this message translates to:
  /// **'STEP 2 OF 3'**
  String get pvStep2;

  /// No description provided for @pvHomeWifi.
  ///
  /// In en, this message translates to:
  /// **'HOME WI-FI'**
  String get pvHomeWifi;

  /// No description provided for @pvSsidHint.
  ///
  /// In en, this message translates to:
  /// **'Network name (SSID)'**
  String get pvSsidHint;

  /// No description provided for @pvWifiPwdHint.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi Password'**
  String get pvWifiPwdHint;

  /// No description provided for @pvWrongPwd.
  ///
  /// In en, this message translates to:
  /// **'Wrong password. Check it and try again.'**
  String get pvWrongPwd;

  /// No description provided for @pvDeviceSection.
  ///
  /// In en, this message translates to:
  /// **'DEVICE'**
  String get pvDeviceSection;

  /// No description provided for @pvDeviceNameHint.
  ///
  /// In en, this message translates to:
  /// **'Device Name'**
  String get pvDeviceNameHint;

  /// No description provided for @pvDeviceIdLbl.
  ///
  /// In en, this message translates to:
  /// **'Device ID'**
  String get pvDeviceIdLbl;

  /// No description provided for @pvDeviceIdPending.
  ///
  /// In en, this message translates to:
  /// **'read from the device when it connects'**
  String get pvDeviceIdPending;

  /// No description provided for @pvMac.
  ///
  /// In en, this message translates to:
  /// **'MAC'**
  String get pvMac;

  /// No description provided for @pvWifiFailed.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi connection failed'**
  String get pvWifiFailed;

  /// No description provided for @pvWifiFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'The device couldn\'t connect to this Wi-Fi network. Check the Wi-Fi name and password and try again.'**
  String get pvWifiFailedGeneric;

  /// No description provided for @pvWifiFailedHint.
  ///
  /// In en, this message translates to:
  /// **'Your device is still connected to the setup Wi-Fi, so you can correct the credentials and test again.'**
  String get pvWifiFailedHint;

  /// No description provided for @pvTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get pvTryAgain;

  /// No description provided for @pvChangeWifi.
  ///
  /// In en, this message translates to:
  /// **'Change Wi-Fi'**
  String get pvChangeWifi;

  /// No description provided for @pvTestContinue.
  ///
  /// In en, this message translates to:
  /// **'Test Wi-Fi & Continue'**
  String get pvTestContinue;

  /// No description provided for @pvTestingWifi.
  ///
  /// In en, this message translates to:
  /// **'Testing Wi-Fi connection…\nPlease keep your phone connected to the device.'**
  String get pvTestingWifi;

  /// No description provided for @pvWifiNetworkLbl.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi Network'**
  String get pvWifiNetworkLbl;

  /// No description provided for @pvSelectWifi.
  ///
  /// In en, this message translates to:
  /// **'Select Wi-Fi network'**
  String get pvSelectWifi;

  /// No description provided for @pvWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for device'**
  String get pvWaiting;

  /// No description provided for @pvStep3.
  ///
  /// In en, this message translates to:
  /// **'STEP 3 OF 3'**
  String get pvStep3;

  /// No description provided for @pvWaitHint.
  ///
  /// In en, this message translates to:
  /// **'The device will join your Wi-Fi and connect to the cloud automatically.'**
  String get pvWaitHint;

  /// No description provided for @pvReconfigure.
  ///
  /// In en, this message translates to:
  /// **'Reconfigure Wi-Fi'**
  String get pvReconfigure;

  /// No description provided for @pvWaitLonger.
  ///
  /// In en, this message translates to:
  /// **'Wait a bit longer'**
  String get pvWaitLonger;

  /// No description provided for @pvWaitLongerHint.
  ///
  /// In en, this message translates to:
  /// **'You can also power-cycle the device so it reconnects, then continue waiting here.'**
  String get pvWaitLongerHint;

  /// No description provided for @pvLocalNotReady.
  ///
  /// In en, this message translates to:
  /// **'Local control not ready'**
  String get pvLocalNotReady;

  /// No description provided for @pvPreparingLocal.
  ///
  /// In en, this message translates to:
  /// **'Preparing local control…'**
  String get pvPreparingLocal;

  /// No description provided for @pvLocalSection.
  ///
  /// In en, this message translates to:
  /// **'LOCAL CONTROL'**
  String get pvLocalSection;

  /// No description provided for @pvEnabling.
  ///
  /// In en, this message translates to:
  /// **'ENABLING…'**
  String get pvEnabling;

  /// No description provided for @pvLocalAddedHint.
  ///
  /// In en, this message translates to:
  /// **'The device is already added to your account — you can control it through the cloud while local control is pending. Retry enables direct local control without claiming the device again.'**
  String get pvLocalAddedHint;

  /// No description provided for @pvLocalAddedBody.
  ///
  /// In en, this message translates to:
  /// **'The device has been added to your account. Enabling direct local control…'**
  String get pvLocalAddedBody;

  /// No description provided for @pvRetryLocal.
  ///
  /// In en, this message translates to:
  /// **'Retry Local Control'**
  String get pvRetryLocal;

  /// No description provided for @pvContinueBg.
  ///
  /// In en, this message translates to:
  /// **'Continue in background'**
  String get pvContinueBg;

  /// No description provided for @pvTerminalAdded.
  ///
  /// In en, this message translates to:
  /// **'Device Already Added'**
  String get pvTerminalAdded;

  /// No description provided for @pvTerminalRegistered.
  ///
  /// In en, this message translates to:
  /// **'Device Already Registered'**
  String get pvTerminalRegistered;

  /// No description provided for @pvTerminalUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Device identity not readable'**
  String get pvTerminalUnreadable;

  /// No description provided for @pvTerminalGeneric.
  ///
  /// In en, this message translates to:
  /// **'Device is not connected yet'**
  String get pvTerminalGeneric;

  /// No description provided for @pvPhaseConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get pvPhaseConnect;

  /// No description provided for @pvPhaseConfigure.
  ///
  /// In en, this message translates to:
  /// **'Configure'**
  String get pvPhaseConfigure;

  /// No description provided for @pvPhaseWait.
  ///
  /// In en, this message translates to:
  /// **'Wait'**
  String get pvPhaseWait;

  /// No description provided for @pvWaitRebooting.
  ///
  /// In en, this message translates to:
  /// **'REBOOTING'**
  String get pvWaitRebooting;

  /// No description provided for @pvWaitJoining.
  ///
  /// In en, this message translates to:
  /// **'JOINING WI-FI'**
  String get pvWaitJoining;

  /// No description provided for @pvWaitMqtt.
  ///
  /// In en, this message translates to:
  /// **'CONNECTING TO MQTT'**
  String get pvWaitMqtt;

  /// No description provided for @pvWaitDetected.
  ///
  /// In en, this message translates to:
  /// **'DEVICE DETECTED'**
  String get pvWaitDetected;

  /// No description provided for @pvWaitVerifying.
  ///
  /// In en, this message translates to:
  /// **'VERIFYING'**
  String get pvWaitVerifying;

  /// No description provided for @pvWaitClaiming.
  ///
  /// In en, this message translates to:
  /// **'CLAIMING'**
  String get pvWaitClaiming;

  /// No description provided for @pvWaitFinalizing.
  ///
  /// In en, this message translates to:
  /// **'FINALIZING'**
  String get pvWaitFinalizing;

  /// No description provided for @pvWaitDone.
  ///
  /// In en, this message translates to:
  /// **'DONE'**
  String get pvWaitDone;

  /// No description provided for @pvWaitFailed.
  ///
  /// In en, this message translates to:
  /// **'FAILED'**
  String get pvWaitFailed;

  /// No description provided for @pvWaitWaiting.
  ///
  /// In en, this message translates to:
  /// **'WAITING'**
  String get pvWaitWaiting;

  /// No description provided for @pvChecklistReboot.
  ///
  /// In en, this message translates to:
  /// **'Device rebooting...'**
  String get pvChecklistReboot;

  /// No description provided for @pvChecklistWifi.
  ///
  /// In en, this message translates to:
  /// **'Joining your Wi-Fi...'**
  String get pvChecklistWifi;

  /// No description provided for @pvChecklistCloud.
  ///
  /// In en, this message translates to:
  /// **'Connecting to cloud...'**
  String get pvChecklistCloud;

  /// No description provided for @pvSelectWifiTitle.
  ///
  /// In en, this message translates to:
  /// **'Select Wi-Fi Network'**
  String get pvSelectWifiTitle;

  /// No description provided for @pvRescan.
  ///
  /// In en, this message translates to:
  /// **'Rescan'**
  String get pvRescan;

  /// No description provided for @pvScanUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi scan unavailable. Enter your network manually.'**
  String get pvScanUnavailable;

  /// No description provided for @pvNoNetworks.
  ///
  /// In en, this message translates to:
  /// **'No Wi-Fi networks found.'**
  String get pvNoNetworks;

  /// No description provided for @pvScanTimeout.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi scan timed out. Tap refresh to try again.'**
  String get pvScanTimeout;

  /// No description provided for @pvEnterManual.
  ///
  /// In en, this message translates to:
  /// **'Enter network manually'**
  String get pvEnterManual;

  /// No description provided for @pvSelectApTitle.
  ///
  /// In en, this message translates to:
  /// **'Select Device Wi-Fi'**
  String get pvSelectApTitle;

  /// No description provided for @pvTapAp.
  ///
  /// In en, this message translates to:
  /// **'Tap your device’s setup network below to connect.'**
  String get pvTapAp;

  /// No description provided for @pvScanUnavailableSettings.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi scan unavailable. Use Open Wi-Fi Settings instead.'**
  String get pvScanUnavailableSettings;

  /// No description provided for @pvNoNetworksNearby.
  ///
  /// In en, this message translates to:
  /// **'No Wi-Fi networks found nearby.'**
  String get pvNoNetworksNearby;

  /// No description provided for @pvLocationOff.
  ///
  /// In en, this message translates to:
  /// **'Android hides nearby Wi-Fi networks from apps until Location is turned on.'**
  String get pvLocationOff;

  /// No description provided for @pvTurnOnLocation.
  ///
  /// In en, this message translates to:
  /// **'Turn on Location'**
  String get pvTurnOnLocation;

  /// No description provided for @pvPermDenied.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi scanning needs this app’s location permission.'**
  String get pvPermDenied;

  /// No description provided for @pvAllowSettings.
  ///
  /// In en, this message translates to:
  /// **'Allow in App Settings'**
  String get pvAllowSettings;

  /// No description provided for @pvDeviceNets.
  ///
  /// In en, this message translates to:
  /// **'DEVICE SETUP NETWORKS'**
  String get pvDeviceNets;

  /// No description provided for @pvOtherNets.
  ///
  /// In en, this message translates to:
  /// **'OTHER WI-FI NETWORKS'**
  String get pvOtherNets;

  /// No description provided for @pvApChip.
  ///
  /// In en, this message translates to:
  /// **'DEVICE'**
  String get pvApChip;

  /// No description provided for @pvManualJoin.
  ///
  /// In en, this message translates to:
  /// **'Manual: join the device\'s network in Android settings yourself'**
  String get pvManualJoin;

  /// No description provided for @pvDetectedTap.
  ///
  /// In en, this message translates to:
  /// **'Detected — tap to connect'**
  String get pvDetectedTap;

  /// No description provided for @pvSignalLine.
  ///
  /// In en, this message translates to:
  /// **'{signal} signal  ·  ID …{id}'**
  String pvSignalLine(String signal, String id);

  /// No description provided for @pvSignalStrong.
  ///
  /// In en, this message translates to:
  /// **'Strong'**
  String get pvSignalStrong;

  /// No description provided for @pvSignalGood.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get pvSignalGood;

  /// No description provided for @pvSignalFair.
  ///
  /// In en, this message translates to:
  /// **'Fair'**
  String get pvSignalFair;

  /// No description provided for @pvSignalWeak.
  ///
  /// In en, this message translates to:
  /// **'Weak'**
  String get pvSignalWeak;

  /// No description provided for @pvSweepHeader.
  ///
  /// In en, this message translates to:
  /// **'Step {step}/{total} — {name}'**
  String pvSweepHeader(int step, int total, String name);

  /// No description provided for @pvSweepBusy.
  ///
  /// In en, this message translates to:
  /// **'Configuring device — step {step}/{total} ({name}) · {secs}s'**
  String pvSweepBusy(String name, int step, int total, int secs);

  /// No description provided for @pvEnterDeviceName.
  ///
  /// In en, this message translates to:
  /// **'Enter a Device Name.'**
  String get pvEnterDeviceName;

  /// No description provided for @pvEnterHomeWifi.
  ///
  /// In en, this message translates to:
  /// **'Select or enter your home Wi-Fi network.'**
  String get pvEnterHomeWifi;

  /// No description provided for @pvDeviceUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The device is not reachable on its setup Wi-Fi anymore. It likely already connected to your home network; power-cycle it and, if it reconnects instead of showing the tasmota-XXXX AP, factory-reset it (hold its button ~10s), then try again.'**
  String get pvDeviceUnreachable;

  /// No description provided for @pvIdentityUnreadable.
  ///
  /// In en, this message translates to:
  /// **'The device\'s identity couldn\'t be read. Power-cycle the device and try again.'**
  String get pvIdentityUnreadable;

  /// No description provided for @pvIdentityLost.
  ///
  /// In en, this message translates to:
  /// **'Device identity was lost. Please try again.'**
  String get pvIdentityLost;

  /// No description provided for @pvReachStees.
  ///
  /// In en, this message translates to:
  /// **'Could not reach STEES. Waiting and retrying…'**
  String get pvReachStees;

  /// No description provided for @pvAlreadyExists.
  ///
  /// In en, this message translates to:
  /// **'The device already exists. You must delete it before claiming it again.'**
  String get pvAlreadyExists;

  /// No description provided for @pvAlreadyRegistered.
  ///
  /// In en, this message translates to:
  /// **'This device is already registered to another account and cannot be added to this one.'**
  String get pvAlreadyRegistered;

  /// No description provided for @pvInvalidMac.
  ///
  /// In en, this message translates to:
  /// **'The device didn\'t report its identity correctly. Close this window and try again.'**
  String get pvInvalidMac;

  /// No description provided for @pvBadRequest.
  ///
  /// In en, this message translates to:
  /// **'This device could not be registered with STEES. Close and try again.'**
  String get pvBadRequest;

  /// No description provided for @pvAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'Access was denied. Sign in again and retry.'**
  String get pvAccessDenied;

  /// No description provided for @pvSteesRejected.
  ///
  /// In en, this message translates to:
  /// **'STEES rejected this device. Close and try again.'**
  String get pvSteesRejected;

  /// No description provided for @pvNotSeen.
  ///
  /// In en, this message translates to:
  /// **'The device is not on the cloud yet. Waiting and retrying…'**
  String get pvNotSeen;

  /// No description provided for @pvRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many requests to STEES. Waiting a moment and retrying…'**
  String get pvRateLimited;

  /// No description provided for @pvSteesBusy.
  ///
  /// In en, this message translates to:
  /// **'STEES was busy. Waiting and retrying…'**
  String get pvSteesBusy;

  /// No description provided for @pvNoLongerConnected.
  ///
  /// In en, this message translates to:
  /// **'You’re no longer connected to the device setup network — reconnect to it and continue.'**
  String get pvNoLongerConnected;

  /// No description provided for @pvSettingRetry.
  ///
  /// In en, this message translates to:
  /// **'The device didn’t accept a setting (failed step: {step}). It’s still reachable — try again.'**
  String pvSettingRetry(String step);

  /// No description provided for @pvSettingReset.
  ///
  /// In en, this message translates to:
  /// **'The device did not accept all settings (failed step: {step}). Power-cycle it (hold its button ~10s to factory-reset if it no longer shows the tasmota-XXXX access point), then try again.'**
  String pvSettingReset(String step);

  /// No description provided for @pvConnectingTo.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {ssid}… ({secs}s)'**
  String pvConnectingTo(String ssid, int secs);

  /// No description provided for @pvCheckingDevice.
  ///
  /// In en, this message translates to:
  /// **'Checking device… ({secs}s)'**
  String pvCheckingDevice(int secs);

  /// No description provided for @pvApLost.
  ///
  /// In en, this message translates to:
  /// **'The connection to \"{ssid}\" was dropped before setup could start. Stay close to the device and try again.'**
  String pvApLost(String ssid);

  /// No description provided for @pvBindFailed.
  ///
  /// In en, this message translates to:
  /// **'The phone couldn’t route traffic to the device network. Toggle Wi-Fi off/on, then try again.'**
  String get pvBindFailed;

  /// No description provided for @pvApTimeout.
  ///
  /// In en, this message translates to:
  /// **'The system took too long to join \"{ssid}\". Make sure the device is powered on and in pairing mode, then try again.'**
  String pvApTimeout(String ssid);

  /// No description provided for @pvApFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to the device setup network {ssid}. Make sure the device is powered on and in setup mode. If the join prompt was declined or the AP is password-protected, use Open Wi-Fi Settings instead.'**
  String pvApFailed(String ssid);

  /// No description provided for @pvDefaultName.
  ///
  /// In en, this message translates to:
  /// **'STEES Smart Device'**
  String get pvDefaultName;

  /// No description provided for @pvLocalFallback.
  ///
  /// In en, this message translates to:
  /// **'Local HTTP control could not be enabled and verified on the device. Make sure this phone is on the same Wi-Fi as the device, then try again.'**
  String get pvLocalFallback;

  /// No description provided for @pvLocalUnknownIp.
  ///
  /// In en, this message translates to:
  /// **'The device address is not known to this phone yet — make sure it is on the same Wi-Fi network as the device, then retry.'**
  String get pvLocalUnknownIp;

  /// No description provided for @pvDiagBadIp.
  ///
  /// In en, this message translates to:
  /// **'The backend-reported LAN IP {ip} was invalid.'**
  String pvDiagBadIp(String ip);

  /// No description provided for @pvDiagDiscovery.
  ///
  /// In en, this message translates to:
  /// **'Local discovery failed ({detail}). Make sure this phone is on the same Wi-Fi as the device.'**
  String pvDiagDiscovery(String detail);

  /// No description provided for @pvDiagNoEndpoint.
  ///
  /// In en, this message translates to:
  /// **'No local HTTP endpoint was reachable for the device. Make sure this phone is on the same Wi-Fi as the device, then try again.'**
  String get pvDiagNoEndpoint;

  /// No description provided for @pvDiagRejected.
  ///
  /// In en, this message translates to:
  /// **'The device rejected or did not confirm the SetOption128 enable ({detail}).'**
  String pvDiagRejected(String detail);

  /// No description provided for @pvDiagHttpApi.
  ///
  /// In en, this message translates to:
  /// **'The device did not confirm its HTTP API is enabled (StatusNET.HTTP_API != 1). Restart the wizard or check the device console.'**
  String get pvDiagHttpApi;

  /// No description provided for @pvDiagFinalCheck.
  ///
  /// In en, this message translates to:
  /// **'The final referer-less state check failed ({detail}).'**
  String pvDiagFinalCheck(String detail);

  /// No description provided for @pvBrokerFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the MQTT broker address. Reopen Add Device while you have an internet connection.'**
  String get pvBrokerFailed;

  /// No description provided for @pvBrokerLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the MQTT broker address from the backend. Make sure you are online, then reopen Add Device.'**
  String get pvBrokerLoadFailed;

  /// No description provided for @pvWifiSettingsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open Wi-Fi settings.'**
  String get pvWifiSettingsFailed;

  /// No description provided for @pvNoIp.
  ///
  /// In en, this message translates to:
  /// **'The device connected to the network but did not receive an IP address. The Wi-Fi name and password are correct; check that the network allows new devices.'**
  String get pvNoIp;

  /// No description provided for @pvSsidNotFound.
  ///
  /// In en, this message translates to:
  /// **'The device could not find this Wi-Fi network. Check the Wi-Fi name and try again.'**
  String get pvSsidNotFound;

  /// No description provided for @pvWrongPasswordMsg.
  ///
  /// In en, this message translates to:
  /// **'The device could not connect to this Wi-Fi network. The Wi-Fi password may be incorrect.'**
  String get pvWrongPasswordMsg;

  /// No description provided for @pvLocalError.
  ///
  /// In en, this message translates to:
  /// **'The device didn\'t respond to the Wi-Fi test. Make sure your phone is still connected to the device Wi-Fi and try again.'**
  String get pvLocalError;

  /// No description provided for @pvWifiVerified.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi connection verified.'**
  String get pvWifiVerified;

  /// No description provided for @pvWifiUnknown.
  ///
  /// In en, this message translates to:
  /// **'The device couldn\'t connect to this Wi-Fi network. Check the Wi-Fi name and password and try again.'**
  String get pvWifiUnknown;

  /// No description provided for @pvGettingReady.
  ///
  /// In en, this message translates to:
  /// **'Getting ready…'**
  String get pvGettingReady;

  /// No description provided for @pvConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to device'**
  String get pvConnecting;

  /// No description provided for @pvReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to device'**
  String get pvReconnecting;

  /// No description provided for @pvConfiguring.
  ///
  /// In en, this message translates to:
  /// **'Configuring device'**
  String get pvConfiguring;

  /// No description provided for @pvTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing Wi-Fi connection…'**
  String get pvTesting;

  /// No description provided for @pvWifiFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi connection failed'**
  String get pvWifiFailedShort;

  /// No description provided for @pvWifiVerifiedShort.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi verified'**
  String get pvWifiVerifiedShort;

  /// No description provided for @pvRestarting.
  ///
  /// In en, this message translates to:
  /// **'Connecting device to Wi-Fi…'**
  String get pvRestarting;

  /// No description provided for @pvRebooting.
  ///
  /// In en, this message translates to:
  /// **'Rebooting device…'**
  String get pvRebooting;

  /// No description provided for @pvConnectingMqtt.
  ///
  /// In en, this message translates to:
  /// **'Connecting device to MQTT…'**
  String get pvConnectingMqtt;

  /// No description provided for @pvRegistering.
  ///
  /// In en, this message translates to:
  /// **'Registering device…'**
  String get pvRegistering;

  /// No description provided for @pvEnablingLocal.
  ///
  /// In en, this message translates to:
  /// **'Enabling local control…'**
  String get pvEnablingLocal;

  /// No description provided for @pvWaitingWifi.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your Wi-Fi…'**
  String get pvWaitingWifi;

  /// No description provided for @pvDeviceReady.
  ///
  /// In en, this message translates to:
  /// **'Device ready'**
  String get pvDeviceReady;

  /// No description provided for @pvProvisionFailed.
  ///
  /// In en, this message translates to:
  /// **'Provisioning failed'**
  String get pvProvisionFailed;

  /// No description provided for @pvCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get pvCancelled;

  /// No description provided for @pvSweepWifiTest.
  ///
  /// In en, this message translates to:
  /// **'wifi-test'**
  String get pvSweepWifiTest;

  /// No description provided for @pvSweepBroker.
  ///
  /// In en, this message translates to:
  /// **'broker'**
  String get pvSweepBroker;

  /// No description provided for @pvSweepTopic.
  ///
  /// In en, this message translates to:
  /// **'topic'**
  String get pvSweepTopic;

  /// No description provided for @pvSweepModule.
  ///
  /// In en, this message translates to:
  /// **'module'**
  String get pvSweepModule;

  /// No description provided for @pvSweepName.
  ///
  /// In en, this message translates to:
  /// **'name'**
  String get pvSweepName;

  /// No description provided for @pvSweepSsid.
  ///
  /// In en, this message translates to:
  /// **'ssid'**
  String get pvSweepSsid;

  /// No description provided for @pvSweepVerify.
  ///
  /// In en, this message translates to:
  /// **'verify'**
  String get pvSweepVerify;

  /// No description provided for @pvSweepRestart.
  ///
  /// In en, this message translates to:
  /// **'restart'**
  String get pvSweepRestart;

  /// No description provided for @pvTryDifferent.
  ///
  /// In en, this message translates to:
  /// **'Try a different network'**
  String get pvTryDifferent;

  /// No description provided for @pvShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get pvShowPassword;

  /// No description provided for @pvHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get pvHidePassword;

  /// No description provided for @adWifiOff.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi is off'**
  String get adWifiOff;

  /// No description provided for @adWifiOffHint.
  ///
  /// In en, this message translates to:
  /// **'Your phone needs Wi-Fi turned on to find and join the device’s setup network.'**
  String get adWifiOffHint;

  /// No description provided for @adTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn on Wi-Fi'**
  String get adTurnOn;

  /// No description provided for @adTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Device'**
  String get adTitle;

  /// No description provided for @adHeading.
  ///
  /// In en, this message translates to:
  /// **'Add a device'**
  String get adHeading;

  /// No description provided for @adGuided.
  ///
  /// In en, this message translates to:
  /// **'GUIDED SETUP'**
  String get adGuided;

  /// No description provided for @adWizardHint.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi must be turned on on your phone — the wizard needs it to find and join the device’s setup network.'**
  String get adWizardHint;

  /// No description provided for @adProvision.
  ///
  /// In en, this message translates to:
  /// **'Provision New Device'**
  String get adProvision;

  /// No description provided for @asEnterNameId.
  ///
  /// In en, this message translates to:
  /// **'Enter a Sensor Name and Sensor ID'**
  String get asEnterNameId;

  /// No description provided for @asSelectDevice.
  ///
  /// In en, this message translates to:
  /// **'Select the Sonoff device for this sensor'**
  String get asSelectDevice;

  /// No description provided for @asAdded.
  ///
  /// In en, this message translates to:
  /// **'Sensor connected successfully.'**
  String get asAdded;

  /// No description provided for @asAddedHint.
  ///
  /// In en, this message translates to:
  /// **'Your sensor is now linked to the Sonoff device.'**
  String get asAddedHint;

  /// No description provided for @asCheckId.
  ///
  /// In en, this message translates to:
  /// **'Check the Sensor ID and make sure the ESP32 is connected.'**
  String get asCheckId;

  /// No description provided for @asNotFound.
  ///
  /// In en, this message translates to:
  /// **'Sensor not found'**
  String get asNotFound;

  /// No description provided for @asTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Sensor'**
  String get asTitle;

  /// No description provided for @asLink.
  ///
  /// In en, this message translates to:
  /// **'LINK A SENSOR'**
  String get asLink;

  /// No description provided for @asLinkHint.
  ///
  /// In en, this message translates to:
  /// **'The sensor will be verified on MQTT before it is added. Make sure your ESP32 is powered on so it can be found.'**
  String get asLinkHint;

  /// No description provided for @asDetails.
  ///
  /// In en, this message translates to:
  /// **'Sensor details'**
  String get asDetails;

  /// No description provided for @asDetailsHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the Sensor ID exactly as configured on the device, then choose which Sonoff controller it belongs to.'**
  String get asDetailsHint;

  /// No description provided for @asNameHint.
  ///
  /// In en, this message translates to:
  /// **'Sensor Name'**
  String get asNameHint;

  /// No description provided for @asNameHelper.
  ///
  /// In en, this message translates to:
  /// **'e.g. Soil Moisture'**
  String get asNameHelper;

  /// No description provided for @asIdHint.
  ///
  /// In en, this message translates to:
  /// **'Sensor ID'**
  String get asIdHint;

  /// No description provided for @asIdHelper.
  ///
  /// In en, this message translates to:
  /// **'e.g. soil_1'**
  String get asIdHelper;

  /// No description provided for @asSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching for sensor...'**
  String get asSearching;

  /// No description provided for @asSearchingHint.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the sensor to report on MQTT. This can take a few seconds.'**
  String get asSearchingHint;

  /// No description provided for @asDeviceLbl.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get asDeviceLbl;

  /// No description provided for @asNoDevices.
  ///
  /// In en, this message translates to:
  /// **'No Sonoff devices yet'**
  String get asNoDevices;

  /// No description provided for @asSelectHint.
  ///
  /// In en, this message translates to:
  /// **'Select the Sonoff device'**
  String get asSelectHint;

  /// No description provided for @asDeviceHelper.
  ///
  /// In en, this message translates to:
  /// **'e.g. Greenhouse Sonoff'**
  String get asDeviceHelper;

  /// No description provided for @apiTimeout.
  ///
  /// In en, this message translates to:
  /// **'The request timed out. Please try again.'**
  String get apiTimeout;

  /// No description provided for @apiUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server. Check your connection.'**
  String get apiUnreachable;

  /// No description provided for @apiSignup.
  ///
  /// In en, this message translates to:
  /// **'Signup failed'**
  String get apiSignup;

  /// No description provided for @apiLogin.
  ///
  /// In en, this message translates to:
  /// **'Login failed'**
  String get apiLogin;

  /// No description provided for @apiFetchDevices.
  ///
  /// In en, this message translates to:
  /// **'Failed to fetch devices'**
  String get apiFetchDevices;

  /// No description provided for @apiRegisterDevice.
  ///
  /// In en, this message translates to:
  /// **'Could not register the device'**
  String get apiRegisterDevice;

  /// No description provided for @apiCheckDevice.
  ///
  /// In en, this message translates to:
  /// **'Could not check device'**
  String get apiCheckDevice;

  /// No description provided for @apiCheckDeviceStatus.
  ///
  /// In en, this message translates to:
  /// **'Could not check device status'**
  String get apiCheckDeviceStatus;

  /// No description provided for @apiFetchStatus.
  ///
  /// In en, this message translates to:
  /// **'Failed to fetch status'**
  String get apiFetchStatus;

  /// No description provided for @apiBrokerInfo.
  ///
  /// In en, this message translates to:
  /// **'Could not load broker info'**
  String get apiBrokerInfo;

  /// No description provided for @apiBrokerHost.
  ///
  /// In en, this message translates to:
  /// **'Broker info missing a host'**
  String get apiBrokerHost;

  /// No description provided for @apiBrokerPort.
  ///
  /// In en, this message translates to:
  /// **'Broker info missing a port'**
  String get apiBrokerPort;

  /// No description provided for @apiControl.
  ///
  /// In en, this message translates to:
  /// **'Control failed'**
  String get apiControl;

  /// No description provided for @apiUnclaim.
  ///
  /// In en, this message translates to:
  /// **'Failed to unclaim device'**
  String get apiUnclaim;

  /// No description provided for @apiDeleteDevice.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete device'**
  String get apiDeleteDevice;

  /// No description provided for @apiFetchSensors.
  ///
  /// In en, this message translates to:
  /// **'Failed to fetch sensors'**
  String get apiFetchSensors;

  /// No description provided for @apiAddSensor.
  ///
  /// In en, this message translates to:
  /// **'Failed to add sensor'**
  String get apiAddSensor;

  /// No description provided for @apiDeleteSensor.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete sensor'**
  String get apiDeleteSensor;

  /// No description provided for @apiFetchRules.
  ///
  /// In en, this message translates to:
  /// **'Failed to fetch rules'**
  String get apiFetchRules;

  /// No description provided for @apiCreateRule.
  ///
  /// In en, this message translates to:
  /// **'Failed to create rule'**
  String get apiCreateRule;

  /// No description provided for @apiUpdateRule.
  ///
  /// In en, this message translates to:
  /// **'Failed to update rule'**
  String get apiUpdateRule;

  /// No description provided for @apiToggleRule.
  ///
  /// In en, this message translates to:
  /// **'Failed to toggle rule'**
  String get apiToggleRule;

  /// No description provided for @apiDeleteRule.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete rule'**
  String get apiDeleteRule;

  /// No description provided for @apiFetchSchedules.
  ///
  /// In en, this message translates to:
  /// **'Failed to fetch schedules'**
  String get apiFetchSchedules;

  /// No description provided for @apiCreateSchedule.
  ///
  /// In en, this message translates to:
  /// **'Failed to create schedule'**
  String get apiCreateSchedule;

  /// No description provided for @apiUpdateSchedule.
  ///
  /// In en, this message translates to:
  /// **'Failed to update schedule'**
  String get apiUpdateSchedule;

  /// No description provided for @apiToggleSchedule.
  ///
  /// In en, this message translates to:
  /// **'Failed to toggle schedule'**
  String get apiToggleSchedule;

  /// No description provided for @apiDeleteSchedule.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete schedule'**
  String get apiDeleteSchedule;

  /// No description provided for @apiSendMqtt.
  ///
  /// In en, this message translates to:
  /// **'Failed to send MQTT command'**
  String get apiSendMqtt;

  /// No description provided for @apiLoadWeather.
  ///
  /// In en, this message translates to:
  /// **'Failed to load weather'**
  String get apiLoadWeather;

  /// No description provided for @apiLoadAdvisories.
  ///
  /// In en, this message translates to:
  /// **'Failed to load advisories'**
  String get apiLoadAdvisories;

  /// No description provided for @apiUpdateLocation.
  ///
  /// In en, this message translates to:
  /// **'Failed to update location'**
  String get apiUpdateLocation;

  /// No description provided for @apiRemoveLocation.
  ///
  /// In en, this message translates to:
  /// **'Failed to remove location'**
  String get apiRemoveLocation;

  /// No description provided for @apiRegisterToken.
  ///
  /// In en, this message translates to:
  /// **'Failed to register push token'**
  String get apiRegisterToken;

  /// No description provided for @apiDeleteToken.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete push token'**
  String get apiDeleteToken;

  /// No description provided for @ntChannel.
  ///
  /// In en, this message translates to:
  /// **'STEES Weather'**
  String get ntChannel;

  /// No description provided for @ntChannelDesc.
  ///
  /// In en, this message translates to:
  /// **'Rain overlap advisories — alerts when irrigation overlaps forecast rain'**
  String get ntChannelDesc;

  /// No description provided for @ntRainExpected.
  ///
  /// In en, this message translates to:
  /// **'Rain expected'**
  String get ntRainExpected;

  /// No description provided for @ntCheckSchedule.
  ///
  /// In en, this message translates to:
  /// **'Check your irrigation schedule'**
  String get ntCheckSchedule;

  /// No description provided for @relayTypeOne.
  ///
  /// In en, this message translates to:
  /// **'1 Relay'**
  String get relayTypeOne;

  /// No description provided for @relayTypeFour.
  ///
  /// In en, this message translates to:
  /// **'4 Relays'**
  String get relayTypeFour;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en', 'fr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
    case 'fr':
      return AppLocalizationsFr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
