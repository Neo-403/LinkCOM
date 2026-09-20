import 'package:flutter_test/flutter_test.dart';
import 'package:linkcom/main.dart';
import 'package:linkcom/version.dart';

void main() {
  testWidgets('LinkCOM 启动显示标题', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('LinkCOM v$appVersion'), findsOneWidget);
  });
}
