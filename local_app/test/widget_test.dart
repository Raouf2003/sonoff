import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:stees_local/main.dart';

void main() {
  testWidgets('unpaired app boots to the connect screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SteesLocalApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Connect your Sonoff'), findsOneWidget);
    expect(find.text('Claim Device'), findsWidgets);
    expect(find.widgetWithText(ElevatedButton, 'Claim Device'), findsOneWidget);
  });
}
