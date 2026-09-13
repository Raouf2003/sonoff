import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_service.dart';

// Channel every weather notification is posted on — foreground, background and
// system auto-display (the backend stamps the same id on the FCM
// `android.notification` block). High importance so it always heads-ups.
const String kWeatherChannelId = 'stees_weather';
const String kWeatherChannelName = 'STEES Weather';

// Discriminator stamped by the backend on every weather advisory FCM payload
// (`data.type`). Handlers route on it explicitly instead of guessing from
// payload shape.
const String kWeatherAdvisoryType = 'weather_advisory';

const AndroidNotificationChannel _weatherChannel = AndroidNotificationChannel(
  kWeatherChannelId,
  kWeatherChannelName,
  description: 'Rain overlap advisories — alerts when irrigation overlaps forecast rain',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

Future<void> _ensureWeatherChannel(FlutterLocalNotificationsPlugin local) async {
  final android = local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  if (android == null) return;
  // Existing installs created this channel without an explicit sound — Android
  // persists channel settings forever, so an update alone is ignored. Delete
  // then recreate to force default sound + max importance. Safe to run every
  // launch (re-creating an existing channel is a no-op after the first fix).
  try {
    await android.deleteNotificationChannel(channelId: kWeatherChannelId);
  } catch (_) {}
  await android.createNotificationChannel(_weatherChannel);
}

String _dataString(Map<String, dynamic> data, String key, String fallback) {
  final v = data[key];
  if (v == null) return fallback;
  final s = v.toString();
  return s.isEmpty ? fallback : s;
}

/// Background/killed handler. MUST stay a top-level function and MUST be
/// registered via `FirebaseMessaging.onBackgroundMessage()` before `runApp()`
/// (see main.dart). Runs in its own isolate: it cannot touch
/// [WeatherNotificationService] state, so it builds a throwaway
/// local-notifications plugin and shows directly.
///
/// NOTE: on Android, messages that ALSO carry a `notification` payload are
/// auto-displayed in the system tray while backgrounded, so this handler
/// stays silent for those (showing again would double-banner). It displays
/// data-only weather messages, which otherwise would arrive with no UI at all.
@pragma('vm:entry-point')
Future<void> weatherBackgroundMessageHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('[weather-notif] background Firebase init failed: $e');
  }
  try {
    if (message.notification != null) return; // system tray already shows it
    final data = message.data;
    final isWeather = data['type'] == kWeatherAdvisoryType ||
        (data['deviceId'] is String &&
            (data['deviceId'] as String).isNotEmpty);
    if (!isWeather) return; // not ours — stay silent
    final local = FlutterLocalNotificationsPlugin();
    await local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await _ensureWeatherChannel(local);
    final title = _dataString(data, 'title', 'Rain expected');
    final body = _dataString(data, 'body', 'Check your irrigation schedule');
    await local.show(
      id: DateTime.now().millisecondsSinceEpoch % 100000,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          kWeatherChannelId,
          kWeatherChannelName,
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          visibility: NotificationVisibility.public,
          category: AndroidNotificationCategory.message,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
          ticker: title,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.active,
        ),
      ),
      payload: _dataString(data, 'deviceId', ''),
    );
  } catch (e) {
    debugPrint('[weather-notif] background show failed: $e');
  }
}

// Centralizes FCM + local display + Socket.IO is handled in weather_page via
// Socket.IO 'weather_advisory' (live). This service owns FCM lifecycle only.
class WeatherNotificationService {
  static final WeatherNotificationService _i = WeatherNotificationService._();
  factory WeatherNotificationService() => _i;
  WeatherNotificationService._();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _tokenSub;
  bool _inited = false;
  String? _pendingDeviceId;
  void Function(String deviceId)? onNotificationTap;

  String? get pendingDeviceId => _pendingDeviceId;
  void consumePending() => _pendingDeviceId = null;

  Future<void> init({required ApiService api, void Function(String deviceId)? onTap}) async {
    if (_inited) return;
    onNotificationTap = onTap;
    // Local-notification setup must NEVER prevent the FCM listeners below
    // from registering: a failed plugin init used to silently kill ALL
    // foreground display. Failures are now logged, listeners always attach.
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) {
            _pendingDeviceId = id;
            onNotificationTap?.call(id);
          }
        },
      );
      // Create channel
      await _ensureWeatherChannel(_local);
      // Cold start from a tapped LOCALLY-shown notification (e.g. posted by
      // the background handler while the app was dead): route like a tap.
      try {
        final launch =
            await _local.getNotificationAppLaunchDetails();
        final payload = launch?.notificationResponse?.payload;
        if ((launch?.didNotificationLaunchApp ?? false) &&
            payload != null &&
            payload.isNotEmpty) {
          _pendingDeviceId = payload;
        }
      } catch (e) {
        debugPrint('[weather-notif] launch-details check failed: $e');
      }
    } catch (e) {
      debugPrint('[weather-notif] local-notifications init failed: $e');
    }
    _inited = true;
    // Foreground FCM -> local show. Handles EVERY message type: weather
    // advisories (data.type == weather_advisory), the diagnostic test ping,
    // and anything else carrying a notification or device payload. Title/body
    // prefer the FCM notification part, falling back to data fields so
    // data-only messages still render.
    FirebaseMessaging.onMessage.listen((msg) async {
      try {
        final data = msg.data;
        final title = msg.notification?.title ??
            _dataString(data, 'title', 'Rain expected');
        final body = msg.notification?.body ??
            _dataString(data, 'body', 'Check your irrigation schedule');
        final deviceId = _dataString(data, 'deviceId', '');
        debugPrint(
            '[weather-notif] foreground msg type=${data['type'] ?? 'none'} device=$deviceId');
        await _showLocal(title, body, deviceId);
      } catch (e) {
        debugPrint('[weather-notif] foreground handler failed: $e');
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      final d = msg.data['deviceId'] as String?;
      if (d != null && d.isNotEmpty) {
        _pendingDeviceId = d;
        onNotificationTap?.call(d);
      }
    });
    // Terminated launch
    try {
      final initial = await _fcm.getInitialMessage();
      final d = initial?.data['deviceId'] as String?;
      if (d != null && d.isNotEmpty) _pendingDeviceId = d;
    } catch (e) {
      debugPrint('[weather-notif] getInitialMessage failed: $e');
    }
  }

  Future<void> requestPermissionAndRegister(ApiService api) async {
    try {
      await _fcm.requestPermission(alert: true, badge: true, sound: true);
      final token = await _fcm.getToken();
      if (token != null && token.isNotEmpty) {
        await api.registerPushToken(token);
      }
      _tokenSub?.cancel();
      _tokenSub = _fcm.onTokenRefresh.listen((t) async {
        try {
          await api.registerPushToken(t);
        } catch (e) {
          debugPrint('[weather-notif] token re-register failed: $e');
        }
      });
    } catch (e) {
      debugPrint('[weather-notif] permission/register failed: $e');
    }
  }

  Future<void> unregister(ApiService api) async {
    try {
      final token = await _fcm.getToken();
      if (token != null) {
        try {
          await api.deletePushToken(token);
        } catch (e) {
          debugPrint('[weather-notif] token delete failed: $e');
        }
      }
      await _tokenSub?.cancel();
      _tokenSub = null;
      try {
        await _fcm.deleteToken();
      } catch (e) {
        debugPrint('[weather-notif] deleteToken failed: $e');
      }
    } catch (e) {
      debugPrint('[weather-notif] unregister failed: $e');
    }
  }

  Future<void> _showLocal(String title, String body, String payload) async {
    try {
      // Belt-and-suspenders: re-creating an existing channel is a no-op, and
      // this repairs the case where init()'s channel step failed but FCM
      // listeners still attached.
      await _ensureWeatherChannel(_local);
      await _local.show(
        id: DateTime.now().millisecondsSinceEpoch % 100000,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kWeatherChannelId,
            kWeatherChannelName,
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            visibility: NotificationVisibility.public,
            category: AndroidNotificationCategory.message,
            styleInformation: BigTextStyleInformation(body, contentTitle: title),
            ticker: title,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.active,
          ),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('[weather-notif] showLocal failed: $e');
    }
  }
}
