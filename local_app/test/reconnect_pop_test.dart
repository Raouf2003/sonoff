import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/connection/ap_connect_screen.dart';
import 'package:stees_local/connection/session.dart';

void main() {
  testWidgets('pushed wifi page closes itself once paired', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = SessionState();
    await tester.pumpWidget(
      MaterialApp(home: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ApConnectScreen(session: session)),
          ),
          child: const Text('Open'),
        );
      })),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Claim Device'), findsWidgets);

    var listenerFired = false;
    session.addListener(() => listenerFired = true);
    session.establish(const Session(mac: 'AA', name: 'Test', profileId: 'sonoff_4ch_pro_r3'));
    expect(listenerFired, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Claim Device'), findsNothing);
  });
}
