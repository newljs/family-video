import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:parent_app/main.dart';

void main() {
  testWidgets(
    'offline collection persists and can be removed without a server',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: ParentHome()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '恐龙小知识');
      await tester.enterText(
        find.byType(TextField).last,
        'https://v.douyin.com/test/',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存到收集箱'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到收集箱'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('同步 1 条到家庭电脑'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('同步 1 条到家庭电脑'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('inbox'), contains('恐龙小知识'));
      await tester.ensureVisible(find.byTooltip('移出收集箱'));
      await tester.tap(find.byTooltip('移出收集箱'));
      await tester.pumpAndSettle();
      expect(prefs.getString('inbox'), '[]');
    },
  );
}
