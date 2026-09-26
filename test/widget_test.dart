import 'package:flutter_test/flutter_test.dart';

import 'package:my_app/main.dart';

void main() {
  testWidgets('Splash screen shows the Continue button', (WidgetTester tester) async {
    await tester.pumpWidget(const TrailwiseApp());

    expect(find.text('Continue'), findsOneWidget);
  });
}
