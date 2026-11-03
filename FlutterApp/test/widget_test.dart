import 'package:flutter_test/flutter_test.dart';
import 'package:askme/main.dart';

void main() {
  testWidgets('AskMe application loads successfully', (tester) async {
    await tester.pumpWidget(const AskMeApp());

    expect(find.text('AskMe'), findsOneWidget);
    expect(find.text('Your private AI document assistant'), findsOneWidget);
    expect(find.text('Select a document'), findsOneWidget);
  });
}
