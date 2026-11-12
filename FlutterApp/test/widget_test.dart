import 'package:askme/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ask tab is selected by default and renders Gemini-style chat without overflow',
      (tester) async {
    await tester.pumpWidget(const AskMeApp());

    expect(tester.takeException(), isNull);
    expect(find.text('AskMe'), findsOneWidget);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('AskMe Private Offline AI'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('General AI'), findsOneWidget);
    expect(find.text('Ask anything or use @DocName…'), findsOneWidget);
  });

  testWidgets('Scan tab switches cleanly and shows camera scan and file upload controls',
      (tester) async {
    await tester.pumpWidget(const AskMeApp());

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(tester.takeException(), isNull);
    expect(find.text('Scan or Upload Named Documents'), findsOneWidget);
    expect(find.text('Scan Camera'), findsOneWidget);
    expect(find.text('Upload File'), findsOneWidget);
    expect(find.text('Saved Documents (0)'), findsOneWidget);
  });
}
