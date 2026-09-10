import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/app/home_shell.dart';
import 'package:stees_local/connection/session.dart';
import 'package:stees_local/theme/theme_controller.dart';

void main() {
  testWidgets('paired session builds the relay home without crashing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(
          deviceId: '34987AC30304',
          deviceName: 'Test',
          themes: ThemeController(),
          session: SessionState(),
          onForget: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Relays'), findsWidgets);
    expect(find.text('Schedules'), findsWidgets);
    await tester.tap(find.text('Schedules').last);
    await tester.pump();
    expect(find.text('Push'), findsOneWidget);
  });
}
