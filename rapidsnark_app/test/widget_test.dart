import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rapidsnark_app/main.dart';

void main() {
  testWidgets('renders proof generator screen', (WidgetTester tester) async {
    await tester.pumpWidget(const RapidsnarkApp());

    expect(find.text('都市配送ルートの安全証跡'), findsWidgets);
    expect(
      find.widgetWithText(FilledButton, '動画検知済みなら Generate And Verify Proof'),
      findsOneWidget,
    );
    expect(find.textContaining('UAV SAFETY ZK'), findsOneWidget);
  });
}
