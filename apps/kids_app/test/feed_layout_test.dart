import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/feed.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('feed controls remain usable at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final font = File('C:/Windows/Fonts/msyh.ttc');
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        if (await font.exists()) {
          final loader = FontLoader('Preview');
          loader.addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
          await loader.load();
        }
      });
      var likes = 0, downloads = 0, collections = 0, tab = -1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('preview'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'Preview',
            ),
            home: Scaffold(
              backgroundColor: Colors.black,
              bottomNavigationBar: FeedNavigation(
                selected: 0,
                onSelect: (v) => tab = v,
              ),
              body: Stack(
                children: [
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xff547969), Color(0xff172e29)],
                        ),
                      ),
                    ),
                  ),
                  FeedOverlay(
                    video: const {'id': 'test', 'title': '认识大自然：为什么树叶会变色？'},
                    liked: false,
                    downloaded: false,
                    saving: false,
                    onLike: () => likes++,
                    onDownload: () => downloads++,
                    onCollections: () => collections++,
                  ),
                  const SafeArea(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(Icons.menu),
                          Text(
                            '合集     推荐',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Icon(Icons.search),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.favorite_rounded));
      await tester.tap(find.text('缓存'));
      await tester.tap(find.byIcon(Icons.video_library_rounded));
      expect(likes, 1);
      expect(downloads, 1);
      expect(collections, 1);
      await tester.tap(find.text('我'));
      expect(tab, 4);
      final output = Directory(
        '${Directory.current.parent.parent.path}/runtime/ui',
      );
      output.createSync(recursive: true);
      if (const bool.fromEnvironment('CAPTURE_UI')) {
        await expectLater(
          find.byKey(const Key('preview')),
          matchesGoldenFile(
            Uri.file('${output.path}/feed-${size.width.toInt()}.png'),
          ),
        );
      }
    });
  }
}
