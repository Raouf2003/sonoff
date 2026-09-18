// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'STEES';

  @override
  String get navDevices => 'Appareils';

  @override
  String get navSensors => 'Capteurs';

  @override
  String get navSchedules => 'Programmes';

  @override
  String get navRules => 'Règles';

  @override
  String get navWeather => 'Météo';

  @override
  String get appTagline => 'Irrigation intelligente';

  @override
  String get actionToggleTheme => 'Changer de thème';

  @override
  String get actionLogout => 'Déconnexion';

  @override
  String get actionLanguage => 'Langue';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageFrench => 'Français';

  @override
  String get sharedCancel => 'Annuler';

  @override
  String get sharedDelete => 'Supprimer';

  @override
  String get sharedEdit => 'Modifier';

  @override
  String get sharedRemove => 'Retirer';

  @override
  String get sharedOk => 'OK';

  @override
  String get sharedRetry => 'Réessayer';

  @override
  String get sharedAdd => 'Ajouter';

  @override
  String get sharedClose => 'Fermer';

  @override
  String get sharedActive => 'Actif';

  @override
  String get sharedOff => 'Arrêt';

  @override
  String get sharedEnabled => 'Activé';

  @override
  String get sharedDisabled => 'Désactivé';

  @override
  String get sharedOnline => 'En ligne';

  @override
  String get sharedOffline => 'Hors ligne';

  @override
  String get sharedDevice => 'Appareil';

  @override
  String get sharedChannel => 'Canal';

  @override
  String get sharedCheckConnection => 'Vérifiez votre connexion et réessayez.';

  @override
  String get sharedSomethingWrong =>
      'Un problème est survenu. Veuillez réessayer.';

  @override
  String get sharedEveryDay => 'Tous les jours';

  @override
  String get sharedEveryDayWord => 'tous les jours';

  @override
  String get sharedToday => 'Aujourd\'hui';

  @override
  String get sharedTomorrow => 'Demain';

  @override
  String get sharedSaveChanges => 'Enregistrer';

  @override
  String get sharedSelectChannel => 'Sélectionnez au moins un canal';

  @override
  String get sharedSignedOut =>
      'Vous semblez déconnecté. Reconnectez-vous et réessayez.';

  @override
  String get sharedNoDevices => 'Aucun appareil';

  @override
  String sharedScheduleCount(String range, int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n programmes',
      one: '1 programme',
    );
    return '$range  ·  $_temp0';
  }

  @override
  String sharedCustomDays(String days) {
    return 'Personnalisé : $days';
  }

  @override
  String sharedIdValue(String id) {
    return 'ID : $id';
  }

  @override
  String sharedDeviceValue(String name) {
    return 'Appareil : $name';
  }

  @override
  String sharedSensorValue(String name) {
    return 'Capteur : $name';
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
    return 'CANAL $index';
  }

  @override
  String get authFillAll => 'Remplissez tous les champs';

  @override
  String get authUsername => 'Nom d\'utilisateur';

  @override
  String get authPassword => 'Mot de passe';

  @override
  String get authConfirmPassword => 'Confirmer le mot de passe';

  @override
  String get authSignIn => 'Se connecter';

  @override
  String get authSignUp => 'S\'inscrire';

  @override
  String get authCreateAccount => 'Créer un compte';

  @override
  String get authJoinStees => 'Rejoignez STEES';

  @override
  String get authHaveAccount => 'Vous avez déjà un compte ?  ';

  @override
  String get authNoAccount => 'Pas de compte ?  ';

  @override
  String get authPwdMismatch => 'Les mots de passe ne correspondent pas';

  @override
  String get authPwdShort =>
      'Le mot de passe doit comporter au moins 6 caractères';

  @override
  String get devRelayBusy => 'Appareil occupé, réessayez';

  @override
  String get devRelayUnreachable => 'Impossible de joindre l\'appareil';

  @override
  String devNoResponse(String channels) {
    return '$channels n\'a pas répondu';
  }

  @override
  String get devFetchStatus => 'Échec de la récupération du statut';

  @override
  String get devDeleteTitle => 'Supprimer l\'appareil';

  @override
  String get devDeleteConfirm =>
      'Voulez-vous vraiment supprimer cet appareil ?\nVous pourrez le réclamer après suppression.';

  @override
  String get devDeleted => 'Appareil supprimé.';

  @override
  String get devDeleteFailed =>
      'Impossible de supprimer l\'appareil. Vérifiez votre connexion et réessayez.';

  @override
  String get devLoadFailed => 'Impossible de charger les appareils';

  @override
  String get devEmptyHint =>
      'Réclamez un contrôleur Sonoff pour commencer\nà gérer vos zones d\'irrigation.';

  @override
  String get devAdd => 'Ajouter un appareil';

  @override
  String get devSectionTitle => 'APPAREILS';

  @override
  String get devZonesTitle => 'ZONES';

  @override
  String get devSchedulesBtn => 'Programmes';

  @override
  String get devLan => 'LAN';

  @override
  String get devLanOnly => 'LAN UNIQUEMENT';

  @override
  String get devSyncing => 'SYNCHRONISATION';

  @override
  String get devTurningOn => 'ALLUMAGE…';

  @override
  String get devTurningOff => 'EXTINCTION…';

  @override
  String get devTurning => 'EN COURS…';

  @override
  String get devOfflineBadge => 'HORS LIGNE';

  @override
  String get devFlowing => 'EN COURS';

  @override
  String get devDry => 'SEC';

  @override
  String get senLoadFailed => 'Impossible de charger les capteurs';

  @override
  String get senEmptyTitle => 'Aucun capteur';

  @override
  String get senEmptyHint =>
      'Ajoutez un capteur d\'humidité du sol pour\nsurveiller vos zones d\'irrigation.';

  @override
  String get senAdd => 'Ajouter un capteur';

  @override
  String get senSection => 'CAPTEURS';

  @override
  String get senRuleBtn => 'Règle';

  @override
  String get schOfflineBanner =>
      'Appareil hors ligne — les programmes se synchroniseront automatiquement à la reconnexion.';

  @override
  String get schSaved => 'Programme enregistré';

  @override
  String get schDeleted => 'Programme supprimé';

  @override
  String get schUpdateFailed => 'Impossible de mettre à jour le programme';

  @override
  String get schDeleteFailed => 'Impossible de supprimer le programme';

  @override
  String get schDeleteTitle => 'Supprimer le programme ?';

  @override
  String schDeleteConfirm(String name) {
    return '« $name » sera supprimé.';
  }

  @override
  String get schLoadFailed => 'Impossible de charger les programmes';

  @override
  String get schEmptyDevicesHint =>
      'Réclamez un appareil pour commencer la programmation.';

  @override
  String get schSection => 'PROGRAMMES';

  @override
  String get schEmptyDevice => 'Aucun programme pour cet appareil';

  @override
  String schRangeInvalid(int index) {
    return 'Plage $index : la fin doit être après le début (pas de nuit)';
  }

  @override
  String schConflict(String chans, String windows, String days) {
    return 'Conflit de programme : $chans est déjà programmé $windows le $days.';
  }

  @override
  String schConflictNamed(
    String chans,
    String windows,
    String days,
    String name,
  ) {
    return 'Conflit de programme : $chans est déjà programmé $windows le $days (« $name »).';
  }

  @override
  String get schPickDay =>
      'Choisissez au moins un jour pour la récurrence personnalisée';

  @override
  String get schSaveFailed => 'Impossible d\'enregistrer le programme';

  @override
  String get schEditTitle => 'Modifier le programme';

  @override
  String get schNewTitle => 'Nouveau programme';

  @override
  String get schChannelsSection => 'CANAUX';

  @override
  String get schChannelsDesc => 'Les sorties pilotées par ce programme.';

  @override
  String get schRepeatsSection => 'RÉPÉTITION';

  @override
  String get schRepeatsDesc =>
      'Les jours de la semaine où ce programme s\'exécute.';

  @override
  String get schDaily => 'Quotidien';

  @override
  String get schCustomMode => 'Jours personnalisés';

  @override
  String get schWindowsSection => 'PLAGES';

  @override
  String get schWindowsDesc =>
      'Les canaux sont actifs dans chaque plage, arrêtés sinon.';

  @override
  String get schAddWindow => 'Ajouter une plage';

  @override
  String get schCreate => 'Créer le programme';

  @override
  String get schStarts => 'Début';

  @override
  String get schEnds => 'Fin';

  @override
  String get schRemoveWindow => 'Retirer la plage';

  @override
  String schWindowLabel(int index) {
    return 'P$index';
  }

  @override
  String get ruleUpdateFailed => 'Impossible de mettre à jour la règle';

  @override
  String get ruleDeleteFailed => 'Impossible de supprimer la règle';

  @override
  String get ruleDeleteTitle => 'Supprimer la règle ?';

  @override
  String ruleDeleteConfirm(String name) {
    return '« $name » sera définitivement supprimé.';
  }

  @override
  String get ruleNoSensors =>
      'Aucun capteur disponible. Ajoutez d\'abord un capteur.';

  @override
  String get ruleChooseSensor => 'Choisir un capteur';

  @override
  String get ruleChooseHint =>
      'Les règles pilotent les relais selon les relevés de ce capteur.';

  @override
  String get ruleLoadFailed => 'Impossible de charger les règles';

  @override
  String get ruleEmptyTitle => 'Aucune règle';

  @override
  String ruleEmptyHint(String action) {
    return 'Appuyez sur « $action » pour piloter un relais\nselon les relevés d\'un capteur.';
  }

  @override
  String get ruleSection => 'RÈGLES';

  @override
  String get ruleAdd => 'Ajouter une règle';

  @override
  String get ruleAbove => 'au-dessus de';

  @override
  String get ruleBelow => 'en dessous de';

  @override
  String ruleWhen(String cond, String threshold) {
    return 'Quand $cond $threshold';
  }

  @override
  String ruleActionTarget(String channels, String action) {
    return '$channels → $action';
  }

  @override
  String ruleOtherwise(String channels, String action) {
    return 'Sinon → $channels → $action';
  }

  @override
  String get rfEnterName => 'Saisissez un nom de règle';

  @override
  String get rfEnterThreshold => 'Saisissez un seuil numérique';

  @override
  String get rfSaveFailed => 'Impossible d\'enregistrer la règle';

  @override
  String get rfEditTitle => 'Modifier la règle';

  @override
  String get rfNewTitle => 'Nouvelle règle';

  @override
  String get rfIdentity => 'IDENTITÉ';

  @override
  String get rfNameHint => 'Nom de la règle';

  @override
  String get rfNameHelper => 'ex. Arrosage auto si sec';

  @override
  String get rfChannelsSection => 'CANAUX';

  @override
  String get rfChannelsDesc =>
      'Choisissez chaque relais piloté par cette règle.';

  @override
  String get rfConditionSection => 'CONDITION';

  @override
  String get rfConditionDesc => 'Le relevé du capteur qui déclenche la règle.';

  @override
  String get rfBelow => 'En dessous';

  @override
  String get rfAbove => 'Au-dessus';

  @override
  String get rfThresholdHint => 'Valeur du seuil';

  @override
  String get rfThresholdHelper => 'ex. 30';

  @override
  String get rfActionSection => 'ACTION';

  @override
  String get rfActionDesc => 'Ce qui se passe quand la condition est vraie.';

  @override
  String get rfTurnOn => 'Allumer';

  @override
  String get rfTurnOff => 'Éteindre';

  @override
  String get rfCreate => 'Créer la règle';

  @override
  String get rfLogic => 'LOGIQUE';

  @override
  String rfIf(String cond, String threshold) {
    return 'SI sol $cond $threshold';
  }

  @override
  String get rfOtherwise => 'SINON';

  @override
  String get srUpdateFailed => 'Échec de la mise à jour de la règle';

  @override
  String get srDeleteFailed => 'Échec de la suppression de la règle';

  @override
  String get srLoadFailed => 'Impossible de charger la règle';

  @override
  String get srEmptyTitle => 'Aucune règle';

  @override
  String get srEmptyHint =>
      'Créez une règle pour piloter automatiquement un relais selon les relevés de ce capteur.';

  @override
  String get srTitle => 'Règle';

  @override
  String srElse(String channels, String action) {
    return 'Sinon → $channels → $action';
  }

  @override
  String get slLoadFailed => 'Échec du chargement des programmes';

  @override
  String get slUpdateFailed => 'Échec de la mise à jour du programme';

  @override
  String get slDeleteFailed => 'Échec de la suppression du programme';

  @override
  String get slTitle => 'Programmes';

  @override
  String slChannels(String channels) {
    return 'Canaux : $channels';
  }

  @override
  String get wLoadFailed => 'Impossible de charger la météo.';

  @override
  String get wNoDevicesHint =>
      'Réclamez un appareil pour activer les prévisions météo.';

  @override
  String get wLoadTitle => 'Impossible de charger la météo';

  @override
  String get wSection => 'MÉTÉO';

  @override
  String get wRefresh => 'Actualiser';

  @override
  String get wNoLocation => 'Emplacement météo non configuré';

  @override
  String get wNoLocationHint =>
      'Cet appareil n\'a pas encore d\'emplacement de ferme. Sélectionnez un emplacement sur la carte pour activer la météo de cet appareil.';

  @override
  String get wFeatForecast => 'Prévisions\nlocales';

  @override
  String get wFeatAdvisories => 'Alertes\npluie';

  @override
  String get wFeatUnaffected => 'Programmes\ninchangés';

  @override
  String get wSetLocation => 'Définir l\'emplacement';

  @override
  String wPinDefaults(String tz) {
    return 'L\'épingle part de votre position actuelle • $tz';
  }

  @override
  String get wForecastUnavailable => 'Prévisions indisponibles';

  @override
  String get wForecastHint =>
      'Vos programmes d\'irrigation ne sont pas affectés et s\'exécuteront comme prévu.';

  @override
  String get wPrecipitation => 'Précipitations';

  @override
  String get wLastHour => 'Dernière heure';

  @override
  String get wCurrent => 'CONDITIONS ACTUELLES';

  @override
  String get wTemperature => 'Température';

  @override
  String get wNoHourly => 'Aucune donnée horaire pour ce jour.';

  @override
  String get wSignificantRain =>
      'Pluie notable : ≥2 mm avec ≥50 % de probabilité';

  @override
  String get wForecast => 'PRÉVISIONS';

  @override
  String get wRainDuring => 'Pluie pendant l\'irrigation';

  @override
  String get wRainNear => 'Pluie proche de l\'irrigation';

  @override
  String get wIrrigation => 'Irrigation';

  @override
  String get wRain => 'Pluie';

  @override
  String get wDirectOverlap => 'Chevauchement direct';

  @override
  String wDirectOverlapWith(String duration) {
    return 'Chevauchement direct · $duration';
  }

  @override
  String get wCloseToWindow => 'Proche de la plage d\'irrigation';

  @override
  String wAlsoNear(String windows) {
    return 'Aussi proche : $windows';
  }

  @override
  String wMoreOverlaps(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n autres chevauchements',
      one: '1 autre chevauchement',
    );
    return '+$_temp0 le même jour';
  }

  @override
  String get wReviewSchedule => 'Voir le programme';

  @override
  String get hourNow => 'MAINT.';

  @override
  String get unitMm => 'mm';

  @override
  String get wNoSchedules => 'Aucun programme d\'irrigation pour cet appareil.';

  @override
  String get wTodayIrrigation => 'IRRIGATION DU JOUR';

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
    return 'Pluie $start–$end · $mm mm · $prob %';
  }

  @override
  String wUpdated(String time, String tz) {
    return 'Mis à jour $time · $tz';
  }

  @override
  String get pkRemoveTitle => 'Retirer l\'emplacement ?';

  @override
  String get pkRemoveConfirm =>
      'Les prévisions météo seront désactivées pour cet appareil. Vos programmes d\'irrigation ne sont pas affectés.';

  @override
  String get pkTitle => 'Choisir l\'emplacement météo';

  @override
  String get pkTapHint => 'Touchez la carte ou déplacez l\'épingle';

  @override
  String get pkTapChoose =>
      'Touchez la carte pour choisir l\'emplacement de la ferme';

  @override
  String get pkResolving => 'Recherche du lieu…';

  @override
  String get pkCustom => 'Point personnalisé';

  @override
  String get pkUseFor => 'Utiliser pour l\'appareil';

  @override
  String get pkSaving => 'Enregistrement…';

  @override
  String get pkConfirm => 'Confirmer l\'emplacement';

  @override
  String get pkRemoveFailed => 'Impossible de retirer l\'emplacement.';

  @override
  String get pkChooseFirst =>
      'Touchez d\'abord la carte pour choisir un emplacement.';

  @override
  String get pkSaveFailed => 'Impossible d\'enregistrer l\'emplacement.';

  @override
  String get pvTitle => 'Configurer l\'appareil';

  @override
  String get pvReconnect => 'Reconnecter le Wi-Fi de l\'appareil';

  @override
  String get pvJoinNetwork => 'Rejoindre le réseau de l\'appareil';

  @override
  String get pvStep1 => 'ÉTAPE 1 SUR 3';

  @override
  String get pvStep1a =>
      'Allumez l\'appareil — son réseau de configuration commence par « tasmota- » ou affiche son identifiant.';

  @override
  String get pvStep1bJoin => 'Rejoignez tasmota-XXXX dans les réglages Wi-Fi.';

  @override
  String get pvStep1bPick => 'Choisissez ce réseau dans la liste ci-dessous.';

  @override
  String get pvStep1bOpen =>
      'Ouvrez les réglages Wi-Fi et rejoignez ce réseau.';

  @override
  String get pvStep1cRecovery =>
      'Revenez ici — votre identifiant est conservé ; c\'est une correction Wi-Fi, pas un nouvel enregistrement.';

  @override
  String get pvStep1cNormal => 'Revenez ici et continuez.';

  @override
  String get pvSelectAp => 'Choisir le Wi-Fi de l\'appareil';

  @override
  String get pvContinue => 'Continuer';

  @override
  String get pvDeviceNetwork => 'Réseau de l\'appareil';

  @override
  String get pvJoinAp => 'Rejoindre le réseau';

  @override
  String get pvOpenSettings => 'Ouvrir les réglages Wi-Fi';

  @override
  String get pvNotFoundHint =>
      'Si vous ne trouvez pas l\'appareil, éteignez puis rallumez le Wi-Fi et réessayez. Sinon, coupez puis remettez rapidement l\'alimentation de l\'appareil 6 à 7 fois pour le réinitialiser.';

  @override
  String get pvSearchAgain => 'Rechercher à nouveau';

  @override
  String get pvRecoveryBtn => 'Instructions de récupération';

  @override
  String get pvRecoveryTitle => 'Étapes de récupération';

  @override
  String get pvRecoverySteps =>
      '1. Redémarrez l\'appareil et attendez 30 secondes que son point d\'accès (tasmota-XXXX) apparaisse.\n\n2. Ouvrez les réglages Wi-Fi et connectez-vous au réseau tasmota-XXXX.\n\n3. Revenez ici et appuyez sur Continuer.\n\n4. Vérifiez le nom et le mot de passe du Wi-Fi domestique, puis appuyez sur Configurer l\'appareil.';

  @override
  String get pvConfigure => 'Configurer l\'appareil';

  @override
  String get pvStep2 => 'ÉTAPE 2 SUR 3';

  @override
  String get pvHomeWifi => 'WI-FI DOMESTIQUE';

  @override
  String get pvSsidHint => 'Nom du réseau (SSID)';

  @override
  String get pvWifiPwdHint => 'Mot de passe Wi-Fi';

  @override
  String get pvWrongPwd => 'Mot de passe incorrect. Vérifiez-le et réessayez.';

  @override
  String get pvDeviceSection => 'APPAREIL';

  @override
  String get pvDeviceNameHint => 'Nom de l\'appareil';

  @override
  String get pvDeviceIdLbl => 'Identifiant de l\'appareil';

  @override
  String get pvDeviceIdPending => 'lu depuis l\'appareil à sa connexion';

  @override
  String get pvMac => 'MAC';

  @override
  String get pvWifiFailed => 'Échec de la connexion Wi-Fi';

  @override
  String get pvWifiFailedGeneric =>
      'L\'appareil n\'a pas pu se connecter à ce réseau Wi-Fi. Vérifiez le nom et le mot de passe, puis réessayez.';

  @override
  String get pvWifiFailedHint =>
      'Votre appareil est toujours connecté au Wi-Fi de configuration, vous pouvez corriger les identifiants et retester.';

  @override
  String get pvTryAgain => 'Réessayer';

  @override
  String get pvChangeWifi => 'Changer de Wi-Fi';

  @override
  String get pvTestContinue => 'Tester le Wi-Fi et continuer';

  @override
  String get pvTestingWifi =>
      'Test de la connexion Wi-Fi…\nGardez votre téléphone connecté à l\'appareil.';

  @override
  String get pvWifiNetworkLbl => 'Réseau Wi-Fi';

  @override
  String get pvSelectWifi => 'Choisir le réseau Wi-Fi';

  @override
  String get pvWaiting => 'Attente de l\'appareil';

  @override
  String get pvStep3 => 'ÉTAPE 3 SUR 3';

  @override
  String get pvWaitHint =>
      'L\'appareil rejoindra votre Wi-Fi et se connectera au cloud automatiquement.';

  @override
  String get pvReconfigure => 'Reconfigurer le Wi-Fi';

  @override
  String get pvWaitLonger => 'Attendre encore un peu';

  @override
  String get pvWaitLongerHint =>
      'Vous pouvez aussi redémarrer l\'appareil pour qu\'il se reconnecte, puis continuer d\'attendre ici.';

  @override
  String get pvLocalNotReady => 'Contrôle local indisponible';

  @override
  String get pvPreparingLocal => 'Préparation du contrôle local…';

  @override
  String get pvLocalSection => 'CONTRÔLE LOCAL';

  @override
  String get pvEnabling => 'ACTIVATION…';

  @override
  String get pvLocalAddedHint =>
      'L\'appareil est déjà ajouté à votre compte — vous pouvez le piloter via le cloud en attendant le contrôle local. Réessayer active le contrôle local direct sans réclamer l\'appareil.';

  @override
  String get pvLocalAddedBody =>
      'L\'appareil a été ajouté à votre compte. Activation du contrôle local direct…';

  @override
  String get pvRetryLocal => 'Réessayer le contrôle local';

  @override
  String get pvContinueBg => 'Continuer en arrière-plan';

  @override
  String get pvTerminalAdded => 'Appareil déjà ajouté';

  @override
  String get pvTerminalRegistered => 'Appareil déjà enregistré';

  @override
  String get pvTerminalUnreadable => 'Identité de l\'appareil illisible';

  @override
  String get pvTerminalGeneric => 'L\'appareil n\'est pas encore connecté';

  @override
  String get pvPhaseConnect => 'Connexion';

  @override
  String get pvPhaseConfigure => 'Configuration';

  @override
  String get pvPhaseWait => 'Attente';

  @override
  String get pvWaitRebooting => 'REDÉMARRAGE';

  @override
  String get pvWaitJoining => 'CONNEXION WI-FI';

  @override
  String get pvWaitMqtt => 'CONNEXION MQTT';

  @override
  String get pvWaitDetected => 'APPAREIL DÉTECTÉ';

  @override
  String get pvWaitVerifying => 'VÉRIFICATION';

  @override
  String get pvWaitClaiming => 'ENREGISTREMENT';

  @override
  String get pvWaitFinalizing => 'FINALISATION';

  @override
  String get pvWaitDone => 'TERMINÉ';

  @override
  String get pvWaitFailed => 'ÉCHEC';

  @override
  String get pvWaitWaiting => 'ATTENTE';

  @override
  String get pvChecklistReboot => 'Redémarrage de l\'appareil...';

  @override
  String get pvChecklistWifi => 'Connexion à votre Wi-Fi...';

  @override
  String get pvChecklistCloud => 'Connexion au cloud...';

  @override
  String get pvSelectWifiTitle => 'Choisir le réseau Wi-Fi';

  @override
  String get pvRescan => 'Analyser à nouveau';

  @override
  String get pvScanUnavailable =>
      'Analyse Wi-Fi indisponible. Saisissez votre réseau manuellement.';

  @override
  String get pvNoNetworks => 'Aucun réseau Wi-Fi trouvé.';

  @override
  String get pvScanTimeout =>
      'L\'analyse Wi-Fi a expiré. Touchez actualiser pour réessayer.';

  @override
  String get pvEnterManual => 'Saisir le réseau manuellement';

  @override
  String get pvSelectApTitle => 'Choisir le Wi-Fi de l\'appareil';

  @override
  String get pvTapAp =>
      'Touchez ci-dessous le réseau de configuration de votre appareil pour vous connecter.';

  @override
  String get pvScanUnavailableSettings =>
      'Analyse Wi-Fi indisponible. Ouvrez plutôt les réglages Wi-Fi.';

  @override
  String get pvNoNetworksNearby => 'Aucun réseau Wi-Fi trouvé à proximité.';

  @override
  String get pvLocationOff =>
      'Android masque les réseaux Wi-Fi proches aux applications tant que la localisation est désactivée.';

  @override
  String get pvTurnOnLocation => 'Activer la localisation';

  @override
  String get pvPermDenied =>
      'L\'analyse Wi-Fi nécessite l\'autorisation de localisation de cette application.';

  @override
  String get pvAllowSettings => 'Autoriser dans les réglages';

  @override
  String get pvDeviceNets => 'RÉSEAUX DE CONFIGURATION';

  @override
  String get pvOtherNets => 'AUTRES RÉSEAUX WI-FI';

  @override
  String get pvApChip => 'APPAREIL';

  @override
  String get pvManualJoin =>
      'Manuel : rejoignez vous-même le réseau de l\'appareil dans les réglages Android';

  @override
  String get pvDetectedTap => 'Détecté — touchez pour connecter';

  @override
  String pvSignalLine(String signal, String id) {
    return 'Signal $signal  ·  ID …$id';
  }

  @override
  String get pvSignalStrong => 'Fort';

  @override
  String get pvSignalGood => 'Bon';

  @override
  String get pvSignalFair => 'Moyen';

  @override
  String get pvSignalWeak => 'Faible';

  @override
  String pvSweepHeader(int step, int total, String name) {
    return 'Étape $step/$total — $name';
  }

  @override
  String pvSweepBusy(String name, int step, int total, int secs) {
    return 'Configuration de l\'appareil — étape $step/$total ($name) · $secs s';
  }

  @override
  String get pvEnterDeviceName => 'Saisissez un nom d\'appareil.';

  @override
  String get pvEnterHomeWifi =>
      'Sélectionnez ou saisissez votre réseau Wi-Fi domestique.';

  @override
  String get pvDeviceUnreachable =>
      'L\'appareil n\'est plus joignable sur son Wi-Fi de configuration. Il a probablement rejoint votre réseau domestique ; redémarrez-le et, s\'il se reconnecte au lieu d\'afficher le point d\'accès tasmota-XXXX, réinitialisez-le (bouton ~10 s), puis réessayez.';

  @override
  String get pvIdentityUnreadable =>
      'L\'identité de l\'appareil n\'a pas pu être lue. Redémarrez l\'appareil et réessayez.';

  @override
  String get pvIdentityLost =>
      'L\'identité de l\'appareil a été perdue. Veuillez réessayer.';

  @override
  String get pvReachStees =>
      'Impossible de joindre STEES. Attente et nouvel essai…';

  @override
  String get pvAlreadyExists =>
      'L\'appareil existe déjà. Vous devez le supprimer avant de le réclamer.';

  @override
  String get pvAlreadyRegistered =>
      'Cet appareil est déjà enregistré sur un autre compte et ne peut pas être ajouté au vôtre.';

  @override
  String get pvInvalidMac =>
      'L\'appareil n\'a pas correctement communiqué son identité. Fermez cette fenêtre et réessayez.';

  @override
  String get pvBadRequest =>
      'Cet appareil n\'a pas pu être enregistré auprès de STEES. Fermez et réessayez.';

  @override
  String get pvAccessDenied => 'Accès refusé. Reconnectez-vous et réessayez.';

  @override
  String get pvSteesRejected =>
      'STEES a rejeté cet appareil. Fermez et réessayez.';

  @override
  String get pvNotSeen =>
      'L\'appareil n\'est pas encore sur le cloud. Attente et nouvel essai…';

  @override
  String get pvRateLimited =>
      'Trop de requêtes vers STEES. Petite pause puis nouvel essai…';

  @override
  String get pvSteesBusy => 'STEES est occupé. Attente et nouvel essai…';

  @override
  String get pvNoLongerConnected =>
      'Vous n\'êtes plus connecté au réseau de configuration — reconnectez-vous et continuez.';

  @override
  String pvSettingRetry(String step) {
    return 'L\'appareil n\'a pas accepté un réglage (étape en échec : $step). Il est toujours joignable — réessayez.';
  }

  @override
  String pvSettingReset(String step) {
    return 'L\'appareil n\'a pas accepté tous les réglages (étape en échec : $step). Redémarrez-le (bouton ~10 s pour réinitialiser s\'il n\'affiche plus le point d\'accès tasmota-XXXX), puis réessayez.';
  }

  @override
  String pvConnectingTo(String ssid, int secs) {
    return 'Connexion à $ssid… ($secs s)';
  }

  @override
  String pvCheckingDevice(int secs) {
    return 'Vérification de l\'appareil… ($secs s)';
  }

  @override
  String pvApLost(String ssid) {
    return 'La connexion à « $ssid » a été perdue avant le début de la configuration. Restez près de l\'appareil et réessayez.';
  }

  @override
  String get pvBindFailed =>
      'Le téléphone n\'a pas pu router le trafic vers le réseau de l\'appareil. Éteignez puis rallumez le Wi-Fi, puis réessayez.';

  @override
  String pvApTimeout(String ssid) {
    return 'Le système a mis trop longtemps à rejoindre « $ssid ». Vérifiez que l\'appareil est allumé et en mode appairage, puis réessayez.';
  }

  @override
  String pvApFailed(String ssid) {
    return 'Impossible de se connecter au réseau de configuration $ssid. Vérifiez que l\'appareil est allumé et en mode configuration. Si la demande a été refusée ou que le réseau est protégé, ouvrez plutôt les réglages Wi-Fi.';
  }

  @override
  String get pvDefaultName => 'Appareil intelligent STEES';

  @override
  String get pvLocalFallback =>
      'Le contrôle local HTTP n\'a pas pu être activé et vérifié sur l\'appareil. Assurez-vous que ce téléphone est sur le même Wi-Fi que l\'appareil, puis réessayez.';

  @override
  String get pvLocalUnknownIp =>
      'L\'adresse de l\'appareil est encore inconnue de ce téléphone — assurez-vous qu\'il est sur le même réseau Wi-Fi que l\'appareil, puis réessayez.';

  @override
  String pvDiagBadIp(String ip) {
    return 'L\'adresse IP LAN signalée par le backend ($ip) est invalide.';
  }

  @override
  String pvDiagDiscovery(String detail) {
    return 'Échec de la découverte locale ($detail). Assurez-vous que ce téléphone est sur le même Wi-Fi que l\'appareil.';
  }

  @override
  String get pvDiagNoEndpoint =>
      'Aucun point de terminaison HTTP local joignable pour l\'appareil. Assurez-vous que ce téléphone est sur le même Wi-Fi que l\'appareil, puis réessayez.';

  @override
  String pvDiagRejected(String detail) {
    return 'L\'appareil a rejeté ou n\'a pas confirmé l\'activation SetOption128 ($detail).';
  }

  @override
  String get pvDiagHttpApi =>
      'L\'appareil n\'a pas confirmé l\'activation de son API HTTP (StatusNET.HTTP_API != 1). Relancez l\'assistant ou vérifiez la console de l\'appareil.';

  @override
  String pvDiagFinalCheck(String detail) {
    return 'Échec de la vérification d\'état finale ($detail).';
  }

  @override
  String get pvBrokerFailed =>
      'Impossible de charger l\'adresse du broker MQTT. Rouvrez Ajouter un appareil avec une connexion internet.';

  @override
  String get pvBrokerLoadFailed =>
      'Impossible de charger l\'adresse du broker MQTT depuis le backend. Vérifiez votre connexion, puis rouvrez Ajouter un appareil.';

  @override
  String get pvWifiSettingsFailed => 'Impossible d\'ouvrir les réglages Wi-Fi.';

  @override
  String get pvNoIp =>
      'L\'appareil s\'est connecté au réseau mais n\'a pas reçu d\'adresse IP. Le nom et le mot de passe sont corrects ; vérifiez que le réseau accepte de nouveaux appareils.';

  @override
  String get pvSsidNotFound =>
      'L\'appareil n\'a pas trouvé ce réseau Wi-Fi. Vérifiez le nom et réessayez.';

  @override
  String get pvWrongPasswordMsg =>
      'L\'appareil n\'a pas pu se connecter à ce réseau Wi-Fi. Le mot de passe est peut-être incorrect.';

  @override
  String get pvLocalError =>
      'L\'appareil n\'a pas répondu au test Wi-Fi. Vérifiez que votre téléphone est toujours connecté au Wi-Fi de l\'appareil et réessayez.';

  @override
  String get pvWifiVerified => 'Connexion Wi-Fi vérifiée.';

  @override
  String get pvWifiUnknown =>
      'L\'appareil n\'a pas pu se connecter à ce réseau Wi-Fi. Vérifiez le nom et le mot de passe, puis réessayez.';

  @override
  String get pvGettingReady => 'Préparation…';

  @override
  String get pvConnecting => 'Connexion à l\'appareil';

  @override
  String get pvReconnecting => 'Reconnexion à l\'appareil';

  @override
  String get pvConfiguring => 'Configuration de l\'appareil';

  @override
  String get pvTesting => 'Test de la connexion Wi-Fi…';

  @override
  String get pvWifiFailedShort => 'Échec de la connexion Wi-Fi';

  @override
  String get pvWifiVerifiedShort => 'Wi-Fi vérifié';

  @override
  String get pvRestarting => 'Connexion de l\'appareil au Wi-Fi…';

  @override
  String get pvRebooting => 'Redémarrage de l\'appareil…';

  @override
  String get pvConnectingMqtt => 'Connexion de l\'appareil à MQTT…';

  @override
  String get pvRegistering => 'Enregistrement de l\'appareil…';

  @override
  String get pvEnablingLocal => 'Activation du contrôle local…';

  @override
  String get pvWaitingWifi => 'En attente de votre Wi-Fi…';

  @override
  String get pvDeviceReady => 'Appareil prêt';

  @override
  String get pvProvisionFailed => 'Échec de la configuration';

  @override
  String get pvCancelled => 'Annulé';

  @override
  String get pvSweepWifiTest => 'test-wifi';

  @override
  String get pvSweepBroker => 'broker';

  @override
  String get pvSweepTopic => 'topic';

  @override
  String get pvSweepModule => 'module';

  @override
  String get pvSweepName => 'nom';

  @override
  String get pvSweepSsid => 'ssid';

  @override
  String get pvSweepVerify => 'vérification';

  @override
  String get pvSweepRestart => 'redémarrage';

  @override
  String get pvTryDifferent => 'Essayer un autre réseau';

  @override
  String get pvShowPassword => 'Afficher le mot de passe';

  @override
  String get pvHidePassword => 'Masquer le mot de passe';

  @override
  String get adWifiOff => 'Wi-Fi désactivé';

  @override
  String get adWifiOffHint =>
      'Votre téléphone doit activer le Wi-Fi pour trouver et rejoindre le réseau de configuration de l\'appareil.';

  @override
  String get adTurnOn => 'Activer le Wi-Fi';

  @override
  String get adTitle => 'Ajouter un appareil';

  @override
  String get adHeading => 'Ajouter un appareil';

  @override
  String get adGuided => 'CONFIGURATION GUIDÉE';

  @override
  String get adWizardHint =>
      'Le Wi-Fi doit être activé sur votre téléphone — l\'assistant en a besoin pour trouver et rejoindre le réseau de configuration de l\'appareil.';

  @override
  String get adProvision => 'Configurer un nouvel appareil';

  @override
  String get asEnterNameId => 'Saisissez un nom et un identifiant de capteur';

  @override
  String get asSelectDevice => 'Sélectionnez l\'appareil Sonoff de ce capteur';

  @override
  String get asAdded => 'Capteur connecté avec succès.';

  @override
  String get asAddedHint =>
      'Votre capteur est maintenant lié à l\'appareil Sonoff.';

  @override
  String get asCheckId =>
      'Vérifiez l\'identifiant du capteur et assurez-vous que l\'ESP32 est connecté.';

  @override
  String get asNotFound => 'Capteur introuvable';

  @override
  String get asTitle => 'Ajouter un capteur';

  @override
  String get asLink => 'ASSOCIER UN CAPTEUR';

  @override
  String get asLinkHint =>
      'Le capteur sera vérifié via MQTT avant d\'être ajouté. Assurez-vous que votre ESP32 est allumé pour être détecté.';

  @override
  String get asDetails => 'Détails du capteur';

  @override
  String get asDetailsHint =>
      'Saisissez l\'identifiant du capteur exactement comme configuré sur l\'appareil, puis choisissez son contrôleur Sonoff.';

  @override
  String get asNameHint => 'Nom du capteur';

  @override
  String get asNameHelper => 'ex. Humidité du sol';

  @override
  String get asIdHint => 'Identifiant du capteur';

  @override
  String get asIdHelper => 'ex. soil_1';

  @override
  String get asSearching => 'Recherche du capteur...';

  @override
  String get asSearchingHint =>
      'En attente du rapport du capteur via MQTT. Cela peut prendre quelques secondes.';

  @override
  String get asDeviceLbl => 'Appareil';

  @override
  String get asNoDevices => 'Aucun appareil Sonoff';

  @override
  String get asSelectHint => 'Sélectionnez l\'appareil Sonoff';

  @override
  String get asDeviceHelper => 'ex. Sonoff de la serre';

  @override
  String get apiTimeout => 'La requête a expiré. Veuillez réessayer.';

  @override
  String get apiUnreachable =>
      'Impossible de joindre le serveur. Vérifiez votre connexion.';

  @override
  String get apiSignup => 'Échec de l\'inscription';

  @override
  String get apiLogin => 'Échec de la connexion';

  @override
  String get apiFetchDevices => 'Échec du chargement des appareils';

  @override
  String get apiRegisterDevice => 'Impossible d\'enregistrer l\'appareil';

  @override
  String get apiCheckDevice => 'Impossible de vérifier l\'appareil';

  @override
  String get apiCheckDeviceStatus =>
      'Impossible de vérifier le statut de l\'appareil';

  @override
  String get apiFetchStatus => 'Échec de la récupération du statut';

  @override
  String get apiBrokerInfo => 'Impossible de charger les infos du broker';

  @override
  String get apiBrokerHost => 'Hôte manquant dans les infos du broker';

  @override
  String get apiBrokerPort => 'Port manquant dans les infos du broker';

  @override
  String get apiControl => 'Échec de la commande';

  @override
  String get apiUnclaim => 'Échec de la libération de l\'appareil';

  @override
  String get apiDeleteDevice => 'Échec de la suppression de l\'appareil';

  @override
  String get apiFetchSensors => 'Échec du chargement des capteurs';

  @override
  String get apiAddSensor => 'Échec de l\'ajout du capteur';

  @override
  String get apiDeleteSensor => 'Échec de la suppression du capteur';

  @override
  String get apiFetchRules => 'Échec du chargement des règles';

  @override
  String get apiCreateRule => 'Échec de la création de la règle';

  @override
  String get apiUpdateRule => 'Échec de la mise à jour de la règle';

  @override
  String get apiToggleRule => 'Échec du basculement de la règle';

  @override
  String get apiDeleteRule => 'Échec de la suppression de la règle';

  @override
  String get apiFetchSchedules => 'Échec du chargement des programmes';

  @override
  String get apiCreateSchedule => 'Échec de la création du programme';

  @override
  String get apiUpdateSchedule => 'Échec de la mise à jour du programme';

  @override
  String get apiToggleSchedule => 'Échec du basculement du programme';

  @override
  String get apiDeleteSchedule => 'Échec de la suppression du programme';

  @override
  String get apiSendMqtt => 'Échec de l\'envoi de la commande MQTT';

  @override
  String get apiLoadWeather => 'Échec du chargement de la météo';

  @override
  String get apiLoadAdvisories => 'Échec du chargement des alertes';

  @override
  String get apiUpdateLocation => 'Échec de la mise à jour de l\'emplacement';

  @override
  String get apiRemoveLocation => 'Échec du retrait de l\'emplacement';

  @override
  String get apiRegisterToken => 'Échec de l\'enregistrement du jeton push';

  @override
  String get apiDeleteToken => 'Échec de la suppression du jeton push';

  @override
  String get ntChannel => 'Météo STEES';

  @override
  String get ntChannelDesc =>
      'Alertes de chevauchement pluie — alerte quand l\'irrigation chevauche la pluie prévue';

  @override
  String get ntRainExpected => 'Pluie attendue';

  @override
  String get ntCheckSchedule => 'Vérifiez votre programme d\'irrigation';

  @override
  String get relayTypeOne => '1 relais';

  @override
  String get relayTypeFour => '4 relais';
}
