// 检查更新（GUI）：结果解析、节流/跳过/自动检查的本机偏好，以及设置页区块
// 的渲染与交互（手动检查、复制发行页链接）。全部走 MockClient，不发真网。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/update_check.dart';
import 'package:student_age_editor/features/settings/update_section.dart';

http.Response _json(String body, [int code = 200]) => http.Response(body, code,
    headers: {'content-type': 'application/json'});

const _newVersionBody = '''
{
  "ok": true,
  "current": "Alpha-v0.5",
  "latest_tag": "Alpha-v0.6",
  "latest_name": "Alpha 0.6",
  "prerelease": false,
  "published_at": "2026-01-02T03:04:05Z",
  "html_url": "https://example.com/releases/tag/Alpha-v0.6",
  "notes": "### 新增\\n- 检查更新",
  "update_available": true,
  "assets": [{"name": "setup.exe", "url": "https://x/setup.exe", "size": 12582912}]
}
''';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UpdateState.instance.resetForTest();
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  test('结果解析：完整字段', () {
    final r = UpdateCheckResult.fromJson({
      'ok': true,
      'current': 'Alpha-v0.5',
      'latest_tag': 'Alpha-v0.6',
      'latest_name': 'Alpha 0.6',
      'prerelease': true,
      'published_at': '2026-01-02T03:04:05Z',
      'html_url': 'https://x/tag',
      'notes': 'a\nb',
      'update_available': true,
      'assets': [
        {'name': 'a.exe', 'url': 'https://x/a.exe', 'size': 12582912},
        'garbage',
      ],
    });
    expect(r.ok, isTrue);
    expect(r.hasNewVersion, isTrue);
    expect(r.current, 'Alpha-v0.5');
    expect(r.latestTag, 'Alpha-v0.6');
    expect(r.latestText, 'Alpha-v0.6  Alpha 0.6');
    expect(r.prerelease, isTrue);
    expect(r.notes, 'a\nb');
    expect(r.assets.length, 2);
    expect(r.assets.first.sizeText, '12.0 MB');
    expect(r.assets.last.name, ''); // 坏附件条目被折叠成空对象而不是抛错
  });

  test('结果解析：缺字段 / 非对象 / 无发行版', () {
    final empty = UpdateCheckResult.fromJson({'ok': true});
    expect(empty.ok, isTrue);
    expect(empty.latestTag, '');
    expect(empty.noRelease, isTrue);
    expect(empty.hasNewVersion, isFalse);
    expect(empty.assets, isEmpty);
    expect(UpdateCheckResult.fromJson('nope').ok, isFalse);
  });

  test('ok=false 保留后端错误文案，且不当作「有新版本」', () {
    final r = UpdateCheckResult.fromJson({'ok': false, 'error': 'rate limited'});
    expect(r.ok, isFalse);
    expect(r.error, 'rate limited');
    expect(r.hasNewVersion, isFalse);
    expect(r.noRelease, isFalse);
  });

  test('附件体积格式化', () {
    expect(const UpdateAsset(size: 0).sizeText, '');
    expect(const UpdateAsset(size: 512 * 1024).sizeText, '512 KB');
    expect(const UpdateAsset(size: 1024 * 1024 * 3).sizeText, '3.0 MB');
  });

  test('checkForUpdates：HTTP 失败折叠成 ok=false（不抛异常）', () async {
    ApiClient.instance.client =
        MockClient((req) async => _json('{"error":"boom"}', 502));
    final r = await checkForUpdates();
    expect(r.ok, isFalse);
    expect(r.error, isNotEmpty);
  });

  test('check()：缓存 current 并写入上次尝试时间', () async {
    ApiClient.instance.client =
        MockClient((req) async => _json(_newVersionBody));
    final s = UpdateState.instance;
    final r = await s.check();
    expect(r.hasNewVersion, isTrue);
    expect(s.version, 'Alpha-v0.5');
    expect(s.lastAttemptAt, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UpdateState.prefsLastAttempt), isNotNull);
  });

  test('maybeStartupCheck：24h 内不请求、不提示', () async {
    var calls = 0;
    SharedPreferences.setMockInitialValues({
      UpdateState.prefsLastAttempt: DateTime.now().millisecondsSinceEpoch,
    });
    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/update/check') calls++;
      return _json(_newVersionBody);
    });
    final s = UpdateState.instance;
    await s.load();
    expect(await s.maybeStartupCheck(), isNull);
    expect(calls, 0, reason: '节流期内不应发出任何请求');
  });

  test('maybeStartupCheck：关闭自动检查不请求', () async {
    var calls = 0;
    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/update/check') calls++;
      return _json(_newVersionBody);
    });
    final s = UpdateState.instance;
    await s.setAutoCheck(false);
    expect(await s.maybeStartupCheck(), isNull);
    expect(calls, 0);
    await s.setAutoCheck(true);
    expect((await s.maybeStartupCheck())?.latestTag, 'Alpha-v0.6');
    expect(calls, 1);
  });

  test('跳过此版本：启动检查不再返回结果，但手动检查仍能看到', () async {
    ApiClient.instance.client =
        MockClient((req) async => _json(_newVersionBody));
    final s = UpdateState.instance;
    final first = await s.maybeStartupCheck();
    expect(first, isNotNull);
    await s.skipLatest();
    expect(s.skippedTag, 'Alpha-v0.6');
    expect(s.hasNewVersion, isFalse);
    // 手动检查不受「跳过」影响：结果照旧展示
    final again = await s.check(manual: true);
    expect(again.hasNewVersion, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UpdateState.prefsSkippedTag), 'Alpha-v0.6');
  });

  testWidgets('设置页区块：展示版本、手动检查、复制发行页链接', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/version') {
        return _json('{"ok":true,"version":"Alpha-v0.5"}');
      }
      return _json(_newVersionBody);
    });

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: UpdateCheckSection(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('关于 · 检查更新'), findsOneWidget);
    expect(find.text('Alpha-v0.5'), findsOneWidget);
    expect(find.textContaining('尚未检查'), findsOneWidget);

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('Alpha-v0.6'), findsWidgets);
    expect(find.text('更新说明'), findsOneWidget);
    expect(find.textContaining('setup.exe  (12.0 MB)'), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, contains('https://example.com/releases/tag/Alpha-v0.6'));

    // 收尾：InfoBar 自带 ~3s 自动消失计时器，不跑完 flutter_test 会报
    // "A Timer is still pending"。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
