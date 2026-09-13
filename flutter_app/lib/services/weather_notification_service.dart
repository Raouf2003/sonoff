import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_service.dart';

// Centralizes FCM + local display + Socket.IO is handled in weather_page via
// Socket.IO 'weather_advisory' (live). This service owns FCM lifecycle only.
class WeatherNotificationService {
  static final WeatherNotificationService _i = WeatherNotificationService._();
  factory WeatherNotificationService() => _i;
  WeatherNotificationService._();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _tokenSub;
  bool _inited = false;
  String? _pendingDeviceId;
  void Function(String deviceId)? onNotificationTap;

  String? get pendingDeviceId => _pendingDeviceId;
  void consumePending() => _pendingDeviceId = null;

  Future<void> init({required ApiService api, void Function(String deviceId)? onTap}) async {
    if (_inited) return;
    onNotificationTap = onTap;
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
      const channel = AndroidNotificationChannel('stees_weather', 'STEES Weather', importance: Importance.high);
      await _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
    } catch (_) {}
    _inited = true;
    // Listen foreground FCM -> local show
    FirebaseMessaging.onMessage.listen((msg) async {
      final title = msg.notification?.title ?? 'Rain expected';
      final body = msg.notification?.body ?? 'Check your irrigation schedule';
      final deviceId = msg.data['deviceId'] as String? ?? '';
      await _showLocal(title, body, deviceId);
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
    } catch (_) {}
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
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> unregister(ApiService api) async {
    try {
      final token = await _fcm.getToken();
      if (token != null) {
        try {
          await api.deletePushToken(token);
        } catch (_) {}
      }
      await _tokenSub?.cancel();
      _tokenSub = null;
      try {
        await _fcm.deleteToken();
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _showLocal(String title, String body, String payload) async {
    try {
      await _local.show(
        id: DateTime.now().millisecondsSinceEpoch % 100000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('stees_weather', 'STEES Weather', importance: Importance.high, priority: Priority.high),
          iOS: DarwinNotificationDetails(),
        ),
        payload: payload,
      );
    } catch (_) {}
  }
}
