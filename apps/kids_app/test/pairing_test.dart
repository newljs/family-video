import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kids_app/main.dart';

void main() {
  testWidgets(
    'discovery welcome keeps manual fallback and rejects an invalid server address',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: KidsHome()));
      await tester.pumpAndSettle();
      expect(find.text('欢迎来到你的放映室'), findsOneWidget);
      await tester.tap(find.text('扫码或手动输入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'not-a-server');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('进入放映室'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入放映室'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('请输入服务器地址'), findsOneWidget);
    },
  );
}
