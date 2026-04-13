import 'package:flutter_test/flutter_test.dart';
import 'package:auric/main.dart';

void main() {
  testWidgets('AuricApp renders', (WidgetTester tester) async {
    await tester.pumpWidget(const AuricApp());
    await tester.pump(const Duration(seconds: 6));
    // Verify the root app widget renders without crashing.
    expect(find.byType(AuricApp), findsOneWidget);
  });
}
