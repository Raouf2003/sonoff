// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'STEES';

  @override
  String get navDevices => 'الأجهزة';

  @override
  String get navSensors => 'الحساسات';

  @override
  String get navSchedules => 'الجداول';

  @override
  String get navRules => 'القواعد';

  @override
  String get navWeather => 'الطقس';

  @override
  String get appTagline => 'الري الذكي';

  @override
  String get actionToggleTheme => 'تبديل المظهر';

  @override
  String get actionLogout => 'تسجيل الخروج';

  @override
  String get actionLanguage => 'اللغة';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageFrench => 'Français';

  @override
  String get sharedCancel => 'إلغاء';

  @override
  String get sharedDelete => 'حذف';

  @override
  String get sharedEdit => 'تعديل';

  @override
  String get sharedRemove => 'إزالة';

  @override
  String get sharedOk => 'حسنًا';

  @override
  String get sharedRetry => 'إعادة المحاولة';

  @override
  String get sharedAdd => 'إضافة';

  @override
  String get sharedClose => 'إغلاق';

  @override
  String get sharedActive => 'نشط';

  @override
  String get sharedOff => 'متوقف';

  @override
  String get sharedEnabled => 'مفعّل';

  @override
  String get sharedDisabled => 'معطّل';

  @override
  String get sharedOnline => 'متصل';

  @override
  String get sharedOffline => 'غير متصل';

  @override
  String get sharedDevice => 'الجهاز';

  @override
  String get sharedChannel => 'القناة';

  @override
  String get sharedCheckConnection => 'تحقق من الاتصال وحاول مجددًا.';

  @override
  String get sharedSomethingWrong => 'حدث خطأ ما. يرجى المحاولة مجددًا.';

  @override
  String get sharedEveryDay => 'كل يوم';

  @override
  String get sharedEveryDayWord => 'كل يوم';

  @override
  String get sharedToday => 'اليوم';

  @override
  String get sharedTomorrow => 'غدًا';

  @override
  String get sharedSaveChanges => 'حفظ التغييرات';

  @override
  String get sharedSelectChannel => 'اختر قناة واحدة على الأقل';

  @override
  String get sharedSignedOut =>
      'يبدو أنك سجّلت الخروج. سجّل الدخول مجددًا وحاول مرة أخرى.';

  @override
  String get sharedNoDevices => 'لا توجد أجهزة بعد';

  @override
  String sharedScheduleCount(String range, int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n جداول',
      two: 'جدولان',
      one: 'جدول واحد',
    );
    return '$range  ·  $_temp0';
  }

  @override
  String sharedCustomDays(String days) {
    return 'مخصص: $days';
  }

  @override
  String sharedIdValue(String id) {
    return 'المعرف: $id';
  }

  @override
  String sharedDeviceValue(String name) {
    return 'الجهاز: $name';
  }

  @override
  String sharedSensorValue(String name) {
    return 'الحساس: $name';
  }

  @override
  String sharedChannelRange(int channels) {
    return 'CH1–CH$channels';
  }

  @override
  String zoneName(int index) {
    return 'المنطقة $index';
  }

  @override
  String channelCode(int index) {
    return 'القناة $index';
  }

  @override
  String get authFillAll => 'املأ جميع الحقول';

  @override
  String get authUsername => 'اسم المستخدم';

  @override
  String get authPassword => 'كلمة المرور';

  @override
  String get authConfirmPassword => 'تأكيد كلمة المرور';

  @override
  String get authSignIn => 'تسجيل الدخول';

  @override
  String get authSignUp => 'إنشاء حساب';

  @override
  String get authCreateAccount => 'إنشاء حساب';

  @override
  String get authJoinStees => 'انضم إلى STEES';

  @override
  String get authHaveAccount => 'لديك حساب بالفعل؟  ';

  @override
  String get authNoAccount => 'ليس لديك حساب؟  ';

  @override
  String get authPwdMismatch => 'كلمتا المرور غير متطابقتين';

  @override
  String get authPwdShort => 'يجب أن تتكون كلمة المرور من 6 أحرف على الأقل';

  @override
  String get devRelayBusy => 'الجهاز مشغول، حاول مجددًا';

  @override
  String get devRelayUnreachable => 'تعذّر الوصول إلى الجهاز';

  @override
  String devNoResponse(String channels) {
    return '$channels لم يستجب';
  }

  @override
  String get devFetchStatus => 'تعذّر جلب الحالة';

  @override
  String get devDeleteTitle => 'حذف الجهاز';

  @override
  String get devDeleteConfirm =>
      'هل أنت متأكد من حذف هذا الجهاز؟\nيمكنك إضافته مجددًا بعد الحذف.';

  @override
  String get devDeleted => 'تم حذف الجهاز.';

  @override
  String get devDeleteFailed =>
      'تعذّر حذف الجهاز. تحقق من الاتصال وحاول مجددًا.';

  @override
  String get devLoadFailed => 'تعذّر تحميل الأجهزة';

  @override
  String get devEmptyHint => 'أضف وحدة تحكم Sonoff للبدء\nفي إدارة مناطق الري.';

  @override
  String get devAdd => 'إضافة جهاز';

  @override
  String get devSectionTitle => 'الأجهزة';

  @override
  String get devZonesTitle => 'المناطق';

  @override
  String get devSchedulesBtn => 'الجداول';

  @override
  String get devLan => 'شبكة محلية';

  @override
  String get devLanOnly => 'محلي فقط';

  @override
  String get devSyncing => 'جارٍ المزامنة';

  @override
  String get devTurningOn => 'جارٍ التشغيل…';

  @override
  String get devTurningOff => 'جارٍ الإيقاف…';

  @override
  String get devTurning => 'جارٍ التنفيذ…';

  @override
  String get devOfflineBadge => 'غير متصل';

  @override
  String get devFlowing => 'يتدفق';

  @override
  String get devDry => 'جاف';

  @override
  String get senLoadFailed => 'تعذّر تحميل الحساسات';

  @override
  String get senEmptyTitle => 'لا توجد حساسات بعد';

  @override
  String get senEmptyHint => 'أضف حساس رطوبة التربة\nلمراقبة مناطق الري.';

  @override
  String get senAdd => 'إضافة حساس';

  @override
  String get senSection => 'الحساسات';

  @override
  String get senRuleBtn => 'القاعدة';

  @override
  String get schOfflineBanner =>
      'الجهاز غير متصل — ستتم مزامنة الجداول تلقائيًا عند إعادة الاتصال.';

  @override
  String get schSaved => 'تم حفظ الجدول';

  @override
  String get schDeleted => 'تم حذف الجدول';

  @override
  String get schUpdateFailed => 'تعذّر تحديث الجدول';

  @override
  String get schDeleteFailed => 'تعذّر حذف الجدول';

  @override
  String get schDeleteTitle => 'حذف الجدول؟';

  @override
  String schDeleteConfirm(String name) {
    return 'سيتم حذف \"$name\".';
  }

  @override
  String get schLoadFailed => 'تعذّر تحميل الجداول';

  @override
  String get schEmptyDevicesHint => 'أضف جهازًا لبدء الجدولة.';

  @override
  String get schSection => 'الجداول';

  @override
  String get schEmptyDevice => 'لا توجد جداول لهذا الجهاز';

  @override
  String schRangeInvalid(int index) {
    return 'الفترة $index: يجب أن تكون النهاية بعد البداية (لا فترات ليلية)';
  }

  @override
  String schConflict(String chans, String windows, String days) {
    return 'تعارض في الجدول: $chans مجدول بالفعل $windows في $days.';
  }

  @override
  String schConflictNamed(
    String chans,
    String windows,
    String days,
    String name,
  ) {
    return 'تعارض في الجدول: $chans مجدول بالفعل $windows في $days (\"$name\").';
  }

  @override
  String get schPickDay => 'اختر يومًا واحدًا على الأقل للتكرار المخصص';

  @override
  String get schSaveFailed => 'تعذّر حفظ الجدول';

  @override
  String get schEditTitle => 'تعديل الجدول';

  @override
  String get schNewTitle => 'جدول جديد';

  @override
  String get schChannelsSection => 'القنوات';

  @override
  String get schChannelsDesc => 'المخارج التي يشغّلها هذا الجدول.';

  @override
  String get schRepeatsSection => 'التكرار';

  @override
  String get schRepeatsDesc => 'أيام الأسبوع التي يعمل فيها الجدول.';

  @override
  String get schDaily => 'يوميًا';

  @override
  String get schCustomMode => 'أيام مخصصة';

  @override
  String get schWindowsSection => 'الفترات';

  @override
  String get schWindowsDesc => 'القنوات تعمل داخل كل فترة، ومتوقفة خارجها.';

  @override
  String get schAddWindow => 'إضافة فترة';

  @override
  String get schCreate => 'إنشاء الجدول';

  @override
  String get schStarts => 'البداية';

  @override
  String get schEnds => 'النهاية';

  @override
  String get schRemoveWindow => 'إزالة الفترة';

  @override
  String schWindowLabel(int index) {
    return 'ف$index';
  }

  @override
  String get ruleUpdateFailed => 'تعذّر تحديث القاعدة';

  @override
  String get ruleDeleteFailed => 'تعذّر حذف القاعدة';

  @override
  String get ruleDeleteTitle => 'حذف القاعدة؟';

  @override
  String ruleDeleteConfirm(String name) {
    return 'سيتم حذف \"$name\" نهائيًا.';
  }

  @override
  String get ruleNoSensors => 'لا توجد حساسات متاحة. أضف حساسًا أولًا.';

  @override
  String get ruleChooseSensor => 'اختر حساسًا';

  @override
  String get ruleChooseHint =>
      'تتحكم القواعد في المرحّلات بناءً على قراءات هذا الحساس.';

  @override
  String get ruleLoadFailed => 'تعذّر تحميل القواعد';

  @override
  String get ruleEmptyTitle => 'لا توجد قواعد بعد';

  @override
  String ruleEmptyHint(String action) {
    return 'اضغط \"$action\" للتحكم في مرحّل\nبناءً على قراءات حساس.';
  }

  @override
  String get ruleSection => 'القواعد';

  @override
  String get ruleAdd => 'إضافة قاعدة';

  @override
  String get ruleAbove => 'فوق';

  @override
  String get ruleBelow => 'تحت';

  @override
  String ruleWhen(String cond, String threshold) {
    return 'عندما $cond $threshold';
  }

  @override
  String ruleActionTarget(String channels, String action) {
    return '$channels ← $action';
  }

  @override
  String ruleOtherwise(String channels, String action) {
    return 'وإلا ← $channels ← $action';
  }

  @override
  String get rfEnterName => 'أدخل اسم القاعدة';

  @override
  String get rfEnterThreshold => 'أدخل عتبة رقمية';

  @override
  String get rfSaveFailed => 'تعذّر حفظ القاعدة';

  @override
  String get rfEditTitle => 'تعديل القاعدة';

  @override
  String get rfNewTitle => 'قاعدة جديدة';

  @override
  String get rfIdentity => 'الهوية';

  @override
  String get rfNameHint => 'اسم القاعدة';

  @override
  String get rfNameHelper => 'مثال: ري تلقائي عند الجفاف';

  @override
  String get rfChannelsSection => 'القنوات';

  @override
  String get rfChannelsDesc => 'اختر كل مرحّل يجب أن تتحكم فيه القاعدة.';

  @override
  String get rfConditionSection => 'الشرط';

  @override
  String get rfConditionDesc => 'قراءة الحساس التي تُفعّل القاعدة.';

  @override
  String get rfBelow => 'أقل من';

  @override
  String get rfAbove => 'أعلى من';

  @override
  String get rfThresholdHint => 'قيمة العتبة';

  @override
  String get rfThresholdHelper => 'مثال: 30';

  @override
  String get rfActionSection => 'الإجراء';

  @override
  String get rfActionDesc => 'ما يحدث عند تحقق الشرط.';

  @override
  String get rfTurnOn => 'تشغيل';

  @override
  String get rfTurnOff => 'إيقاف';

  @override
  String get actionOn => 'تشغيل';

  @override
  String get actionOff => 'إيقاف';

  @override
  String get rfCreate => 'إنشاء القاعدة';

  @override
  String get rfLogic => 'المنطق';

  @override
  String rfIf(String cond, String threshold) {
    return 'إذا كانت التربة $cond $threshold';
  }

  @override
  String get rfOtherwise => 'وإلا';

  @override
  String get srUpdateFailed => 'فشل تحديث القاعدة';

  @override
  String get srDeleteFailed => 'فشل حذف القاعدة';

  @override
  String get srLoadFailed => 'تعذّر تحميل القاعدة';

  @override
  String get srEmptyTitle => 'لا توجد قاعدة بعد';

  @override
  String get srEmptyHint =>
      'أنشئ قاعدة للتحكم تلقائيًا في مرحّل بناءً على قراءات هذا الحساس.';

  @override
  String get srTitle => 'القاعدة';

  @override
  String srElse(String channels, String action) {
    return 'وإلا ← $channels ← $action';
  }

  @override
  String get slLoadFailed => 'فشل تحميل الجداول';

  @override
  String get slUpdateFailed => 'فشل تحديث الجدول';

  @override
  String get slDeleteFailed => 'فشل حذف الجدول';

  @override
  String get slTitle => 'الجداول';

  @override
  String slChannels(String channels) {
    return 'القنوات: $channels';
  }

  @override
  String get wLoadFailed => 'تعذّر تحميل الطقس.';

  @override
  String get wNoDevicesHint => 'أضف جهازًا لتفعيل توقعات الطقس.';

  @override
  String get wLoadTitle => 'تعذّر تحميل الطقس';

  @override
  String get wSection => 'الطقس';

  @override
  String get wRefresh => 'تحديث';

  @override
  String get wNoLocation => 'لم يتم ضبط موقع الطقس';

  @override
  String get wNoLocationHint =>
      'لا يوجد موقع مزرعة لهذا الجهاز بعد. اختر موقعًا على الخريطة لتفعيل الطقس لهذا الجهاز.';

  @override
  String get wFeatForecast => 'توقعات\nمحلية';

  @override
  String get wFeatAdvisories => 'تنبيهات\nالمطر';

  @override
  String get wFeatUnaffected => 'الجداول\nلا تتأثر';

  @override
  String get wSetLocation => 'تحديد الموقع';

  @override
  String wPinDefaults(String tz) {
    return 'الدبوس يبدأ من موقعك الحالي • $tz';
  }

  @override
  String get wForecastUnavailable => 'التوقعات غير متاحة';

  @override
  String get wForecastHint =>
      'جداول الري الخاصة بك لا تتأثر وستعمل كما هو مبرمج.';

  @override
  String get wPrecipitation => 'الهطول';

  @override
  String get wLastHour => 'الساعة الماضية';

  @override
  String get wCurrent => 'الظروف الحالية';

  @override
  String get wTemperature => 'درجة الحرارة';

  @override
  String get wNoHourly => 'لا توجد بيانات ساعية لهذا اليوم.';

  @override
  String get wSignificantRain => 'مطر مهم: ≥2 مم مع احتمال ≥50٪';

  @override
  String get wForecast => 'التوقعات';

  @override
  String get wRainDuring => 'مطر أثناء الري';

  @override
  String get wRainNear => 'مطر قريب من الري';

  @override
  String get wIrrigation => 'الري';

  @override
  String get wRain => 'المطر';

  @override
  String get wDirectOverlap => 'تداخل مباشر';

  @override
  String wDirectOverlapWith(String duration) {
    return 'تداخل مباشر · $duration';
  }

  @override
  String get wCloseToWindow => 'قريب من فترة الري';

  @override
  String wAlsoNear(String windows) {
    return 'قريب أيضًا: $windows';
  }

  @override
  String wMoreOverlaps(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n تداخلات أخرى',
      two: 'تداخلان آخران',
      one: 'تداخل آخر',
    );
    return '+$_temp0 في نفس اليوم';
  }

  @override
  String get wReviewSchedule => 'مراجعة الجدول';

  @override
  String get hourNow => 'الآن';

  @override
  String get unitMm => 'مم';

  @override
  String get wNoSchedules => 'لا توجد جداول ري لهذا الجهاز.';

  @override
  String get wTodayIrrigation => 'ري اليوم';

  @override
  String wDurationMin(int minutes) {
    return '~$minutes دقيقة';
  }

  @override
  String wDurationHour(int h) {
    return '~$h س';
  }

  @override
  String wDurationHourMin(int h, int m) {
    return '~$h س $m د';
  }

  @override
  String wRainChip(String start, String end, String mm, String prob) {
    return 'مطر $start–$end · $mm مم · $prob٪';
  }

  @override
  String wUpdated(String time, String tz) {
    return 'آخر تحديث $time · $tz';
  }

  @override
  String get pkRemoveTitle => 'إزالة الموقع؟';

  @override
  String get pkRemoveConfirm =>
      'سيتم تعطيل توقعات الطقس لهذا الجهاز. جداول الري الخاصة بك لا تتأثر.';

  @override
  String get pkTitle => 'اختيار موقع الطقس';

  @override
  String get pkTapHint => 'اضغط على الخريطة أو اسحب الدبوس';

  @override
  String get pkTapChoose => 'اضغط على الخريطة لاختيار موقع المزرعة';

  @override
  String get pkResolving => 'جارٍ تحديد المكان…';

  @override
  String get pkCustom => 'نقطة مخصصة على الخريطة';

  @override
  String get pkUseFor => 'استخدام للجهاز';

  @override
  String get pkSaving => 'جارٍ الحفظ…';

  @override
  String get pkConfirm => 'تأكيد الموقع';

  @override
  String get pkRemoveFailed => 'تعذّر إزالة الموقع.';

  @override
  String get pkChooseFirst => 'اضغط على الخريطة لاختيار موقع أولًا.';

  @override
  String get pkSaveFailed => 'تعذّر حفظ الموقع.';

  @override
  String get pvTitle => 'إعداد الجهاز';

  @override
  String get pvReconnect => 'إعادة توصيل شبكة الجهاز';

  @override
  String get pvJoinNetwork => 'الانضمام إلى شبكة الجهاز';

  @override
  String get pvStep1 => 'الخطوة 1 من 3';

  @override
  String get pvStep1a =>
      'شغّل الجهاز — تبدأ شبكة الإعداد الخاصة به بـ \"tasmota-\" أو تعرض معرف الجهاز.';

  @override
  String get pvStep1bJoin => 'انضم إلى tasmota-XXXX في إعدادات Wi-Fi.';

  @override
  String get pvStep1bPick => 'اختر تلك الشبكة من القائمة أدناه.';

  @override
  String get pvStep1bOpen => 'افتح إعدادات Wi-Fi وانضم إلى تلك الشبكة.';

  @override
  String get pvStep1cRecovery =>
      'ارجع إلى هنا — معرف جهازك محفوظ؛ هذا تصحيح للشبكة وليس تسجيلًا جديدًا.';

  @override
  String get pvStep1cNormal => 'ارجع إلى هنا وتابع.';

  @override
  String get pvSelectAp => 'اختيار شبكة الجهاز';

  @override
  String get pvContinue => 'متابعة';

  @override
  String get pvDeviceNetwork => 'شبكة الجهاز';

  @override
  String get pvJoinAp => 'الانضمام إلى شبكة الجهاز';

  @override
  String get pvOpenSettings => 'فتح إعدادات Wi-Fi';

  @override
  String get pvNotFoundHint =>
      'إذا لم تجد الجهاز، أوقف Wi-Fi ثم أعد تشغيله وحاول مجددًا. إذا استمر عدم ظهوره، افصل طاقة الجهاز وأعدها بسرعة 6 إلى 7 مرات لإعادة ضبطه.';

  @override
  String get pvSearchAgain => 'بحث مجددًا';

  @override
  String get pvRecoveryBtn => 'تعليمات الاسترداد';

  @override
  String get pvRecoveryTitle => 'خطوات الاسترداد';

  @override
  String get pvRecoverySteps =>
      '1. افصل طاقة الجهاز وانتظر 30 ثانية حتى تظهر نقطة الوصول (tasmota-XXXX).\n\n2. افتح إعدادات Wi-Fi واتصل بشبكة tasmota-XXXX.\n\n3. ارجع إلى هنا واضغط متابعة.\n\n4. تأكد من صحة اسم شبكة المنزل وكلمة المرور، ثم اضغط إعداد الجهاز.';

  @override
  String get pvConfigure => 'ضبط الجهاز';

  @override
  String get pvStep2 => 'الخطوة 2 من 3';

  @override
  String get pvHomeWifi => 'شبكة المنزل';

  @override
  String get pvSsidHint => 'اسم الشبكة (SSID)';

  @override
  String get pvWifiPwdHint => 'كلمة مرور Wi-Fi';

  @override
  String get pvWrongPwd => 'كلمة مرور خاطئة. تحقق منها وحاول مجددًا.';

  @override
  String get pvDeviceSection => 'الجهاز';

  @override
  String get pvDeviceNameHint => 'اسم الجهاز';

  @override
  String get pvDeviceIdLbl => 'معرف الجهاز';

  @override
  String get pvDeviceIdPending => 'يُقرأ من الجهاز عند اتصاله';

  @override
  String get pvMac => 'MAC';

  @override
  String get pvWifiFailed => 'فشل الاتصال بشبكة Wi-Fi';

  @override
  String get pvWifiFailedGeneric =>
      'تعذّر على الجهاز الاتصال بشبكة Wi-Fi هذه. تحقق من اسم الشبكة وكلمة المرور وحاول مجددًا.';

  @override
  String get pvWifiFailedHint =>
      'جهازك ما زال متصلًا بشبكة الإعداد، لذا يمكنك تصحيح البيانات وإعادة الاختبار.';

  @override
  String get pvTryAgain => 'حاول مجددًا';

  @override
  String get pvChangeWifi => 'تغيير الشبكة';

  @override
  String get pvTestContinue => 'اختبار Wi-Fi والمتابعة';

  @override
  String get pvTestingWifi =>
      'جارٍ اختبار اتصال Wi-Fi…\nيرجى إبقاء هاتفك متصلًا بالجهاز.';

  @override
  String get pvWifiNetworkLbl => 'شبكة Wi-Fi';

  @override
  String get pvSelectWifi => 'اختيار شبكة Wi-Fi';

  @override
  String get pvWaiting => 'انتظار الجهاز';

  @override
  String get pvStep3 => 'الخطوة 3 من 3';

  @override
  String get pvWaitHint => 'سينضم الجهاز إلى شبكتك ويتصل بالسحابة تلقائيًا.';

  @override
  String get pvReconfigure => 'إعادة ضبط Wi-Fi';

  @override
  String get pvWaitLonger => 'انتظر قليلًا';

  @override
  String get pvWaitLongerHint =>
      'يمكنك أيضًا فصل طاقة الجهاز وإعادة توصيلها ليعيد الاتصال، ثم مواصلة الانتظار هنا.';

  @override
  String get pvLocalNotReady => 'التحكم المحلي غير جاهز';

  @override
  String get pvPreparingLocal => 'جارٍ تجهيز التحكم المحلي…';

  @override
  String get pvLocalSection => 'التحكم المحلي';

  @override
  String get pvEnabling => 'جارٍ التفعيل…';

  @override
  String get pvLocalAddedHint =>
      'تمت إضافة الجهاز إلى حسابك بالفعل — يمكنك التحكم فيه عبر السحابة بينما التحكم المحلي معلّق. إعادة المحاولة تفعّل التحكم المحلي المباشر دون الحاجة لإضافة الجهاز مجددًا.';

  @override
  String get pvLocalAddedBody =>
      'تمت إضافة الجهاز إلى حسابك. جارٍ تفعيل التحكم المحلي المباشر…';

  @override
  String get pvRetryLocal => 'إعادة محاولة التحكم المحلي';

  @override
  String get pvContinueBg => 'المتابعة في الخلفية';

  @override
  String get pvTerminalAdded => 'الجهاز مضاف بالفعل';

  @override
  String get pvTerminalRegistered => 'الجهاز مسجّل بالفعل';

  @override
  String get pvTerminalUnreadable => 'تعذّرت قراءة هوية الجهاز';

  @override
  String get pvTerminalGeneric => 'الجهاز غير متصل بعد';

  @override
  String get pvPhaseConnect => 'الاتصال';

  @override
  String get pvPhaseConfigure => 'الضبط';

  @override
  String get pvPhaseWait => 'الانتظار';

  @override
  String get pvWaitRebooting => 'جارٍ إعادة التشغيل';

  @override
  String get pvWaitJoining => 'جارٍ الانضمام للشبكة';

  @override
  String get pvWaitMqtt => 'جارٍ الاتصال بـ MQTT';

  @override
  String get pvWaitDetected => 'تم رصد الجهاز';

  @override
  String get pvWaitVerifying => 'جارٍ التحقق';

  @override
  String get pvWaitClaiming => 'جارٍ التسجيل';

  @override
  String get pvWaitFinalizing => 'جارٍ الإنهاء';

  @override
  String get pvWaitDone => 'تم';

  @override
  String get pvWaitFailed => 'فشل';

  @override
  String get pvWaitWaiting => 'انتظار';

  @override
  String get pvChecklistReboot => 'جارٍ إعادة تشغيل الجهاز...';

  @override
  String get pvChecklistWifi => 'جارٍ الانضمام إلى شبكتك...';

  @override
  String get pvChecklistCloud => 'جارٍ الاتصال بالسحابة...';

  @override
  String get pvSelectWifiTitle => 'اختيار شبكة Wi-Fi';

  @override
  String get pvRescan => 'إعادة الفحص';

  @override
  String get pvScanUnavailable => 'فحص Wi-Fi غير متاح. أدخل شبكتك يدويًا.';

  @override
  String get pvNoNetworks => 'لم يتم العثور على شبكات Wi-Fi.';

  @override
  String get pvScanTimeout =>
      'انتهت مهلة فحص Wi-Fi. اضغط التحديث للمحاولة مجددًا.';

  @override
  String get pvEnterManual => 'إدخال الشبكة يدويًا';

  @override
  String get pvSelectApTitle => 'اختيار شبكة الجهاز';

  @override
  String get pvTapAp => 'اضغط على شبكة إعداد جهازك أدناه للاتصال.';

  @override
  String get pvScanUnavailableSettings =>
      'فحص Wi-Fi غير متاح. استخدم فتح إعدادات Wi-Fi بدلًا من ذلك.';

  @override
  String get pvNoNetworksNearby => 'لم يتم العثور على شبكات Wi-Fi قريبة.';

  @override
  String get pvLocationOff =>
      'يخفي أندرويد شبكات Wi-Fi القريبة عن التطبيقات حتى يتم تفعيل الموقع.';

  @override
  String get pvTurnOnLocation => 'تفعيل الموقع';

  @override
  String get pvPermDenied =>
      'يحتاج فحص Wi-Fi إلى إذن الموقع الخاص بهذا التطبيق.';

  @override
  String get pvAllowSettings => 'السماح من إعدادات التطبيق';

  @override
  String get pvDeviceNets => 'شبكات إعداد الجهاز';

  @override
  String get pvOtherNets => 'شبكات Wi-Fi أخرى';

  @override
  String get pvApChip => 'الجهاز';

  @override
  String get pvManualJoin =>
      'يدويًا: انضم إلى شبكة الجهاز من إعدادات أندرويد بنفسك';

  @override
  String get pvDetectedTap => 'تم الرصد — اضغط للاتصال';

  @override
  String pvSignalLine(String signal, String id) {
    return 'إشارة $signal  ·  المعرف …$id';
  }

  @override
  String get pvSignalStrong => 'قوية';

  @override
  String get pvSignalGood => 'جيدة';

  @override
  String get pvSignalFair => 'متوسطة';

  @override
  String get pvSignalWeak => 'ضعيفة';

  @override
  String pvSweepHeader(int step, int total, String name) {
    return 'الخطوة $step/$total — $name';
  }

  @override
  String pvSweepBusy(String name, int step, int total, int secs) {
    return 'جارٍ ضبط الجهاز — الخطوة $step/$total ($name) · $secs ث';
  }

  @override
  String get pvEnterDeviceName => 'أدخل اسم الجهاز.';

  @override
  String get pvEnterHomeWifi => 'اختر شبكة Wi-Fi المنزلية أو أدخلها.';

  @override
  String get pvDeviceUnreachable =>
      'تعذّر الوصول إلى الجهاز عبر شبكة الإعداد. ربما اتصل بشبكة منزلك بالفعل؛ افصل طاقته وأعدها، وإذا أعاد الاتصال بدل إظهار شبكة tasmota-XXXX، أعد ضبط المصنع (اضغط الزر ~10 ثوانٍ)، ثم حاول مجددًا.';

  @override
  String get pvIdentityUnreadable =>
      'تعذّرت قراءة هوية الجهاز. افصل طاقة الجهاز وحاول مجددًا.';

  @override
  String get pvIdentityLost => 'فُقدت هوية الجهاز. يرجى المحاولة مجددًا.';

  @override
  String get pvReachStees =>
      'تعذّر الوصول إلى STEES. جارٍ الانتظار وإعادة المحاولة…';

  @override
  String get pvAlreadyExists =>
      'الجهاز موجود بالفعل. يجب حذفه قبل إضافته مجددًا.';

  @override
  String get pvAlreadyRegistered =>
      'هذا الجهاز مسجّل في حساب آخر ولا يمكن إضافته إلى حسابك.';

  @override
  String get pvInvalidMac =>
      'لم يُبلغ الجهاز عن هويته بشكل صحيح. أغلق هذه النافذة وحاول مجددًا.';

  @override
  String get pvBadRequest =>
      'تعذّر تسجيل هذا الجهاز في STEES. أغلق وحاول مجددًا.';

  @override
  String get pvAccessDenied =>
      'تم رفض الوصول. سجّل الدخول مجددًا وحاول مرة أخرى.';

  @override
  String get pvSteesRejected => 'رفض STEES هذا الجهاز. أغلق وحاول مجددًا.';

  @override
  String get pvNotSeen =>
      'الجهاز ليس على السحابة بعد. جارٍ الانتظار وإعادة المحاولة…';

  @override
  String get pvRateLimited =>
      'طلبات كثيرة إلى STEES. ننتظر قليلًا ونعيد المحاولة…';

  @override
  String get pvSteesBusy => 'STEES مشغول. جارٍ الانتظار وإعادة المحاولة…';

  @override
  String get pvNoLongerConnected =>
      'لم تعد متصلًا بشبكة إعداد الجهاز — أعد الاتصال بها وتابع.';

  @override
  String pvSettingRetry(String step) {
    return 'لم يقبل الجهاز إعدادًا (الخطوة الفاشلة: $step). ما زال متاحًا — حاول مجددًا.';
  }

  @override
  String pvSettingReset(String step) {
    return 'لم يقبل الجهاز كل الإعدادات (الخطوة الفاشلة: $step). افصل طاقته (اضغط الزر ~10 ثوانٍ لإعادة ضبط المصنع إذا لم تعد تظهر نقطة الوصول tasmota-XXXX)، ثم حاول مجددًا.';
  }

  @override
  String pvConnectingTo(String ssid, int secs) {
    return 'جارٍ الاتصال بـ $ssid… ($secs ث)';
  }

  @override
  String pvCheckingDevice(int secs) {
    return 'جارٍ فحص الجهاز… ($secs ث)';
  }

  @override
  String pvApLost(String ssid) {
    return 'انقطع الاتصال بـ \"$ssid\" قبل بدء الإعداد. ابقَ قريبًا من الجهاز وحاول مجددًا.';
  }

  @override
  String get pvBindFailed =>
      'تعذّر على الهاتف توجيه البيانات إلى شبكة الجهاز. أوقف Wi-Fi ثم أعد تشغيله وحاول مجددًا.';

  @override
  String pvApTimeout(String ssid) {
    return 'استغرق النظام وقتًا طويلًا للانضمام إلى \"$ssid\". تأكد من تشغيل الجهاز ووضع الاقتران، ثم حاول مجددًا.';
  }

  @override
  String pvApFailed(String ssid) {
    return 'تعذّر الاتصال بشبكة إعداد الجهاز $ssid. تأكد من تشغيل الجهاز ووضع الإعداد. إذا تم رفض طلب الانضمام أو كانت الشبكة محمية بكلمة مرور، استخدم فتح إعدادات Wi-Fi بدلًا من ذلك.';
  }

  @override
  String get pvDefaultName => 'جهاز STEES الذكي';

  @override
  String get pvLocalFallback =>
      'تعذّر تفعيل التحكم المحلي عبر HTTP والتحقق منه على الجهاز. تأكد من أن هذا الهاتف على نفس شبكة Wi-Fi مثل الجهاز، ثم حاول مجددًا.';

  @override
  String get pvLocalUnknownIp =>
      'عنوان الجهاز غير معروف لهذا الهاتف بعد — تأكد من أنه على نفس شبكة Wi-Fi مثل الجهاز، ثم أعد المحاولة.';

  @override
  String pvDiagBadIp(String ip) {
    return 'عنوان IP المحلي الذي أبلغ عنه الخادم ($ip) غير صالح.';
  }

  @override
  String pvDiagDiscovery(String detail) {
    return 'فشل الاكتشاف المحلي ($detail). تأكد من أن هذا الهاتف على نفس شبكة Wi-Fi مثل الجهاز.';
  }

  @override
  String get pvDiagNoEndpoint =>
      'تعذّر الوصول إلى أي نقطة نهاية HTTP محلية للجهاز. تأكد من أن هذا الهاتف على نفس شبكة Wi-Fi مثل الجهاز، ثم حاول مجددًا.';

  @override
  String pvDiagRejected(String detail) {
    return 'رفض الجهاز تفعيل SetOption128 أو لم يؤكده ($detail).';
  }

  @override
  String get pvDiagHttpApi =>
      'لم يؤكد الجهاز تفعيل واجهة HTTP (StatusNET.HTTP_API != 1). أعد تشغيل المعالج أو تحقق من وحدة تحكم الجهاز.';

  @override
  String pvDiagFinalCheck(String detail) {
    return 'فشل فحص الحالة النهائي ($detail).';
  }

  @override
  String get pvBrokerFailed =>
      'تعذّر تحميل عنوان وسيط MQTT. أعد فتح إضافة جهاز أثناء اتصالك بالإنترنت.';

  @override
  String get pvBrokerLoadFailed =>
      'تعذّر تحميل عنوان وسيط MQTT من الخادم. تأكد من اتصالك بالإنترنت، ثم أعد فتح إضافة جهاز.';

  @override
  String get pvWifiSettingsFailed => 'تعذّر فتح إعدادات Wi-Fi.';

  @override
  String get pvNoIp =>
      'اتصل الجهاز بالشبكة لكنه لم يحصل على عنوان IP. اسم الشبكة وكلمة المرور صحيحان؛ تحقق من أن الشبكة تسمح بالأجهزة الجديدة.';

  @override
  String get pvSsidNotFound =>
      'تعذّر على الجهاز العثور على شبكة Wi-Fi هذه. تحقق من اسم الشبكة وحاول مجددًا.';

  @override
  String get pvWrongPasswordMsg =>
      'تعذّر على الجهاز الاتصال بشبكة Wi-Fi هذه. قد تكون كلمة المرور غير صحيحة.';

  @override
  String get pvLocalError =>
      'لم يستجب الجهاز لاختبار Wi-Fi. تأكد من أن هاتفك ما زال متصلًا بشبكة الجهاز وحاول مجددًا.';

  @override
  String get pvWifiVerified => 'تم التحقق من اتصال Wi-Fi.';

  @override
  String get pvWifiUnknown =>
      'تعذّر على الجهاز الاتصال بشبكة Wi-Fi هذه. تحقق من اسم الشبكة وكلمة المرور وحاول مجددًا.';

  @override
  String get pvGettingReady => 'جارٍ التجهيز…';

  @override
  String get pvConnecting => 'جارٍ الاتصال بالجهاز';

  @override
  String get pvReconnecting => 'جارٍ إعادة الاتصال بالجهاز';

  @override
  String get pvConfiguring => 'جارٍ ضبط الجهاز';

  @override
  String get pvTesting => 'جارٍ اختبار اتصال Wi-Fi…';

  @override
  String get pvWifiFailedShort => 'فشل الاتصال بشبكة Wi-Fi';

  @override
  String get pvWifiVerifiedShort => 'تم التحقق من Wi-Fi';

  @override
  String get pvRestarting => 'جارٍ توصيل الجهاز بشبكة Wi-Fi…';

  @override
  String get pvRebooting => 'جارٍ إعادة تشغيل الجهاز…';

  @override
  String get pvConnectingMqtt => 'جارٍ توصيل الجهاز بـ MQTT…';

  @override
  String get pvRegistering => 'جارٍ تسجيل الجهاز…';

  @override
  String get pvEnablingLocal => 'جارٍ تفعيل التحكم المحلي…';

  @override
  String get pvWaitingWifi => 'في انتظار شبكتك…';

  @override
  String get pvDeviceReady => 'الجهاز جاهز';

  @override
  String get pvProvisionFailed => 'فشل الإعداد';

  @override
  String get pvCancelled => 'أُلغي';

  @override
  String get pvSweepWifiTest => 'اختبار الشبكة';

  @override
  String get pvSweepBroker => 'الوسيط';

  @override
  String get pvSweepTopic => 'الموضوع';

  @override
  String get pvSweepModule => 'الوحدة';

  @override
  String get pvSweepName => 'الاسم';

  @override
  String get pvSweepSsid => 'الشبكة';

  @override
  String get pvSweepVerify => 'التحقق';

  @override
  String get pvSweepRestart => 'إعادة التشغيل';

  @override
  String get pvTryDifferent => 'تجربة شبكة أخرى';

  @override
  String get pvShowPassword => 'إظهار كلمة المرور';

  @override
  String get pvHidePassword => 'إخفاء كلمة المرور';

  @override
  String get adWifiOff => 'Wi-Fi متوقف';

  @override
  String get adWifiOffHint =>
      'يحتاج هاتفك إلى تفعيل Wi-Fi للعثور على شبكة إعداد الجهاز والانضمام إليها.';

  @override
  String get adTurnOn => 'تشغيل Wi-Fi';

  @override
  String get adTitle => 'إضافة جهاز';

  @override
  String get adHeading => 'إضافة جهاز';

  @override
  String get adGuided => 'إعداد موجّه';

  @override
  String get adWizardHint =>
      'يجب تفعيل Wi-Fi على هاتفك — يحتاجه المعالج للعثور على شبكة إعداد الجهاز والانضمام إليها.';

  @override
  String get adProvision => 'إعداد جهاز جديد';

  @override
  String get asEnterNameId => 'أدخل اسم الحساس ومعرفه';

  @override
  String get asSelectDevice => 'اختر جهاز Sonoff الخاص بهذا الحساس';

  @override
  String get asAdded => 'تم توصيل الحساس بنجاح.';

  @override
  String get asAddedHint => 'حساسك مرتبط الآن بجهاز Sonoff.';

  @override
  String get asCheckId => 'تحقق من معرف الحساس وتأكد من اتصال ESP32.';

  @override
  String get asNotFound => 'لم يتم العثور على الحساس';

  @override
  String get asTitle => 'إضافة حساس';

  @override
  String get asLink => 'ربط حساس';

  @override
  String get asLinkHint =>
      'سيتم التحقق من الحساس عبر MQTT قبل إضافته. تأكد من تشغيل ESP32 ليتم العثور عليه.';

  @override
  String get asDetails => 'تفاصيل الحساس';

  @override
  String get asDetailsHint =>
      'أدخل معرف الحساس كما هو مضبوط على الجهاز تمامًا، ثم اختر وحدة تحكم Sonoff التي ينتمي إليها.';

  @override
  String get asNameHint => 'اسم الحساس';

  @override
  String get asNameHelper => 'مثال: رطوبة التربة';

  @override
  String get asIdHint => 'معرف الحساس';

  @override
  String get asIdHelper => 'مثال: soil_1';

  @override
  String get asSearching => 'جارٍ البحث عن الحساس...';

  @override
  String get asSearchingHint =>
      'في انتظار أن يُبلغ الحساس عبر MQTT. قد يستغرق ذلك بضع ثوانٍ.';

  @override
  String get asDeviceLbl => 'الجهاز';

  @override
  String get asNoDevices => 'لا توجد أجهزة Sonoff بعد';

  @override
  String get asSelectHint => 'اختر جهاز Sonoff';

  @override
  String get asDeviceHelper => 'مثال: Sonoff الدفيئة';

  @override
  String get apiTimeout => 'انتهت مهلة الطلب. يرجى المحاولة مجددًا.';

  @override
  String get apiUnreachable => 'تعذّر الوصول إلى الخادم. تحقق من الاتصال.';

  @override
  String get apiSignup => 'فشل إنشاء الحساب';

  @override
  String get apiLogin => 'فشل تسجيل الدخول';

  @override
  String get apiFetchDevices => 'فشل جلب الأجهزة';

  @override
  String get apiRegisterDevice => 'تعذّر تسجيل الجهاز';

  @override
  String get apiCheckDevice => 'تعذّر فحص الجهاز';

  @override
  String get apiCheckDeviceStatus => 'تعذّر التحقق من حالة الجهاز';

  @override
  String get apiFetchStatus => 'فشل جلب الحالة';

  @override
  String get apiBrokerInfo => 'تعذّر تحميل معلومات الوسيط';

  @override
  String get apiBrokerHost => 'معلومات الوسيط تفتقد المضيف';

  @override
  String get apiBrokerPort => 'معلومات الوسيط تفتقد المنفذ';

  @override
  String get apiControl => 'فشل التحكم';

  @override
  String get apiUnclaim => 'فشل إلغاء ارتباط الجهاز';

  @override
  String get apiDeleteDevice => 'فشل حذف الجهاز';

  @override
  String get apiFetchSensors => 'فشل جلب الحساسات';

  @override
  String get apiAddSensor => 'فشل إضافة الحساس';

  @override
  String get apiDeleteSensor => 'فشل حذف الحساس';

  @override
  String get apiFetchRules => 'فشل جلب القواعد';

  @override
  String get apiCreateRule => 'فشل إنشاء القاعدة';

  @override
  String get apiUpdateRule => 'فشل تحديث القاعدة';

  @override
  String get apiToggleRule => 'فشل تبديل القاعدة';

  @override
  String get apiDeleteRule => 'فشل حذف القاعدة';

  @override
  String get apiFetchSchedules => 'فشل جلب الجداول';

  @override
  String get apiCreateSchedule => 'فشل إنشاء الجدول';

  @override
  String get apiUpdateSchedule => 'فشل تحديث الجدول';

  @override
  String get apiToggleSchedule => 'فشل تبديل الجدول';

  @override
  String get apiDeleteSchedule => 'فشل حذف الجدول';

  @override
  String get apiSendMqtt => 'فشل إرسال أمر MQTT';

  @override
  String get apiLoadWeather => 'فشل تحميل الطقس';

  @override
  String get apiLoadAdvisories => 'فشل تحميل التنبيهات';

  @override
  String get apiUpdateLocation => 'فشل تحديث الموقع';

  @override
  String get apiRemoveLocation => 'فشل إزالة الموقع';

  @override
  String get apiRegisterToken => 'فشل تسجيل رمز الدفع';

  @override
  String get apiDeleteToken => 'فشل حذف رمز الدفع';

  @override
  String get apiAuthRequired => 'اسم المستخدم وكلمة المرور مطلوبان';

  @override
  String get apiUsernameShort =>
      'يجب أن يتكون اسم المستخدم من 3 أحرف على الأقل';

  @override
  String get apiPasswordShort => 'يجب أن تتكون كلمة المرور من 6 أحرف على الأقل';

  @override
  String get apiUsernameTaken => 'اسم المستخدم مستخدم بالفعل';

  @override
  String get apiInvalidCredentials => 'اسم المستخدم أو كلمة المرور غير صحيحة';

  @override
  String get apiAuthHeader => 'ترويسة التفويض مفقودة أو غير صالحة';

  @override
  String get apiTokenExpired => 'الرمز غير صالح أو منتهي الصلاحية';

  @override
  String get apiServerError => 'خطأ داخلي في الخادم';

  @override
  String get apiNotOwner => 'أنت لا تملك هذا الجهاز';

  @override
  String get apiDeviceNotOwned => 'الجهاز غير موجود أو لا تملكه';

  @override
  String get apiDeviceNotFound => 'الجهاز غير موجود';

  @override
  String get apiRuleNotFound => 'القاعدة غير موجودة';

  @override
  String get apiScheduleNotFound => 'الجدول غير موجود';

  @override
  String get apiSensorNotFound => 'الحساس غير موجود';

  @override
  String get apiSensorIdTaken => 'معرف الحساس هذا مضاف بالفعل';

  @override
  String get apiSensorNotFoundDetail =>
      'الحساس غير موجود. تأكد من اتصال ESP32 وصحة معرف الحساس.';

  @override
  String get apiSensorIdInvalid =>
      'يجب أن يتكون معرف الحساس من 1-40 حرفًا (أحرف، أرقام، _ . -)';

  @override
  String get apiSensorRequired => 'الاسم ومعرف الحساس ومعرف الجهاز مطلوبة';

  @override
  String get ntChannel => 'طقس STEES';

  @override
  String get ntChannelDesc =>
      'تنبيهات تداخل المطر — تنبيه عند تداخل الري مع توقعات المطر';

  @override
  String get ntRainExpected => 'مطر متوقع';

  @override
  String get ntCheckSchedule => 'تحقق من جدول الري';

  @override
  String get relayTypeOne => 'مرحّل واحد';

  @override
  String get relayTypeFour => '4 مرحّلات';
}
