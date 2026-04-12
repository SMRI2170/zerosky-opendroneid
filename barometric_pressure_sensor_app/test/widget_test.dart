import 'package:flutter_test/flutter_test.dart';

import 'package:barometric_pressure_sensor_app/main.dart';

void main() {
  testWidgets('App loads smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const BarometerApp());

    // Verify that our app bar title is present.
    expect(find.text('Barometer Monitor'), findsOneWidget);
    expect(find.text('Current Pressure'), findsOneWidget);
  });
}
