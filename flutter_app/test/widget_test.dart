import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/main.dart';

void main() {
  testWidgets('App loads and shows auth gate', (WidgetTester tester) async {
    await tester.pumpWidget(const SteesApp());
    expect(find.byType(SteesApp), findsOneWidget);
  });
}
