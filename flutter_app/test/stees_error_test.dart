import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/theme/app_theme.dart';
import 'package:smart_home_app/widgets/stees_widgets.dart';

void main() {
  testWidgets('SteesError renders title/subtitle and fires retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SteesError(
          title: 'Could not load devices',
          subtitle: 'Check your connection and try again.',
          onRetry: () => retried = true,
        ),
      ),
    ));

    expect(find.text('Could not load devices'), findsOneWidget);
    expect(find.text('Check your connection and try again.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('SteesError hides retry when no callback is given', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(
        body: SteesError(title: 'Oops', subtitle: 'Nothing to retry.'),
      ),
    ));
    expect(find.text('Oops'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}