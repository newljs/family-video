import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kids_app/time_budget.dart';
import 'package:shared_preferences/shared_preferences.dart';

String today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

FamilyApi apiWith(MockClient client) =>
    FamilyApi(client: client)..server = 'http://home:8765';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('关闭限额会覆盖旧缓存，离线重启不会恢复旧限制', () async {
    final api = apiWith(MockClient((r) async => http.Response('{}', 200)));
    final budget = TimeBudget(api);
    budget.apply({
      'limit_minutes': 20,
      'watched_ms_today': 60000,
      'day': today(),
    });
    budget.apply({
      'limit_minutes': 0,
      'watched_ms_today': 60000,
      'day': today(),
    });
    await Future<void>.delayed(Duration.zero);
    final restored = TimeBudget(api);
    await restored.restoreCached();
    expect(restored.limited, isFalse);
  });

  test('默认不限制：spend 累计今日用量但永不耗尽', () {
    final budget = TimeBudget(
      apiWith(MockClient((r) async => http.Response('{}', 200))),
    );
    expect(budget.limited, isFalse);
    expect(budget.exhausted, isFalse);
    budget.spend(120000);
    expect(budget.watchedMsToday, 120000);
    expect(budget.watchedMinutes, 2);
    expect(budget.exhausted, isFalse);
  });

  test('限额下扣减触发 exhausted，之后不再累计', () {
    final budget = TimeBudget(
      apiWith(MockClient((r) async => http.Response('{}', 200))),
    );
    budget.apply({
      'limit_minutes': 10,
      'watched_ms_today': 9 * 60000,
      'day': today(),
    });
    expect(budget.limited, isTrue);
    expect(budget.remainingMinutes, 1);
    budget.spend(30000);
    expect(budget.exhausted, isFalse);
    budget.spend(30000);
    expect(budget.exhausted, isTrue);
    expect(budget.remainingMinutes, 0);
    budget.spend(5000);
    expect(budget.watchedMsToday, 10 * 60000);
  });

  test('apply 校正：同天取服务端与本地较大值，换天以服务端为准', () {
    final budget = TimeBudget(
      apiWith(MockClient((r) async => http.Response('{}', 200))),
    );
    budget.apply({
      'limit_minutes': 30,
      'watched_ms_today': 60000,
      'after_limit_collection_id': 'c1',
      'day': today(),
    });
    expect(budget.afterLimitCollectionId, 'c1');
    budget.spend(1000);
    // 服务端还没收到最新一批上报（本地较大值保留）。
    budget.apply({
      'limit_minutes': 30,
      'watched_ms_today': 50000,
      'day': today(),
    });
    expect(budget.watchedMsToday, 61000);
    // 服务端日期前进（换天）→ 以服务端重新开始。
    budget.apply({
      'limit_minutes': 30,
      'watched_ms_today': 1000,
      'day': '2020-01-01',
    });
    expect(budget.watchedMsToday, 1000);
  });

  test('restoreCached 恢复当天的限额与用量，跨天清零', () async {
    SharedPreferences.setMockInitialValues({
      'time_budget_http://home:8765': jsonEncode({
        'limit_minutes': 20,
        'watched_ms': 5 * 60000,
        'after_limit_collection_id': 'c9',
        'day': today(),
      }),
    });
    final budget = TimeBudget(
      apiWith(MockClient((r) async => http.Response('{}', 200))),
    );
    await budget.restoreCached();
    expect(budget.limited, isTrue);
    expect(budget.limitMinutes, 20);
    expect(budget.watchedMsToday, 5 * 60000);
    // 离线期间安静模式也知道该留哪些内容。
    expect(budget.afterLimitCollectionId, 'c9');

    // 缓存来自之前某天：限额保留，今日用量清零。
    SharedPreferences.setMockInitialValues({
      'time_budget_http://home:8765': jsonEncode({
        'limit_minutes': 20,
        'watched_ms': 5 * 60000,
        'day': '2020-01-01',
      }),
    });
    final other = TimeBudget(
      apiWith(MockClient((r) async => http.Response('{}', 200))),
    );
    await other.restoreCached();
    expect(other.limitMinutes, 20);
    expect(other.watchedMsToday, 0);
  });

  test('load 从服务端读取额度；旧服务端 404 时静默保留原额度', () async {
    final budget = TimeBudget(
      apiWith(
        MockClient(
          (r) async => http.Response(
            jsonEncode({
              'limit_minutes': 15,
              'watched_ms_today': 60000,
              'day': today(),
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    await budget.load();
    expect(budget.limitMinutes, 15);
    expect(budget.watchedMsToday, 60000);

    budget.apply({'limit_minutes': 30, 'watched_ms_today': 0, 'day': today()});
    final stale = TimeBudget(
      apiWith(
        MockClient(
          (r) async => http.Response(
            jsonEncode({'detail': 'not found'}),
            404,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    stale.apply({'limit_minutes': 30, 'watched_ms_today': 0, 'day': today()});
    await stale.load();
    expect(stale.limitMinutes, 30);
  });
}
