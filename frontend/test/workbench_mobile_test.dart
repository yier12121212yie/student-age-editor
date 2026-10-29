// B3 移动端逐个验收（12 个工作台）。
//
// 覆盖 ux_roadmap_r2.md B3 的验收口径：
//   * 390×844 与 360×640 两种手机尺寸下，12 个工作台**无横向/像素溢出**；
//   * 窄屏主从形态可用：底部动作条「打开编辑」进入编辑页、「设置」以底部滑出层展开；
//   * 「打开→编辑→保存」端到端（每批取一个代表：目标 / 事件 / 仓库），保存经
//     `PUT /api/cfg/<cfg>` 落盘；
//   * 触控目标：底部动作条点击区高度 ≥44dp。
//
// 每个工作台用各自单测里的真实最小数据起见，避免空表把「无溢出」测成「空态无溢出」。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/chats/idle_chat_workbench.dart';
import 'package:student_age_editor/features/blocks/blocks_workbench.dart';
import 'package:student_age_editor/features/events/event_workbench.dart';
import 'package:student_age_editor/features/external/external_dialogues_workbench.dart';
import 'package:student_age_editor/features/goals/goals_workbench.dart';
import 'package:student_age_editor/features/json/json_workbench.dart';
import 'package:student_age_editor/features/messages/messages_workbench.dart';
import 'package:student_age_editor/features/minigames/minigames_workbench.dart';
import 'package:student_age_editor/features/person/person_workbench.dart';
import 'package:student_age_editor/features/social/social_workbench.dart';
import 'package:student_age_editor/features/space/space_workbench.dart';
import 'package:student_age_editor/features/warehouse/warehouse_workbench.dart';

const _sizes = <Size>[Size(390, 844), Size(360, 640)];

/// 记录写盘的表名（PUT /api/cfg/<cfg>）。
final _savedCfgs = <String>[];

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

/// 各工作台单测里的真实最小数据（合并成一份 mock）。
Map<String, Map<String, dynamic>> _tables() => {
      'KZoneContentCfg': {
        '1001': {
          'id': 1001,
          'role': 10,
          'title': '周记一则',
          'content': '今天天气很好。',
          'imgs': <dynamic>[],
          'thumbs': [
            [10, 0]
          ],
          'comments': [
            [100101, 0]
          ],
          'options': <dynamic>[],
          'cond': <dynamic>[],
        },
      },
      'KZoneCommentCfg': {
        '100101': {
          'id': 100101,
          'roles': [10],
          'parent': 0,
          'content': '第一条评论',
          'comments': <dynamic>[],
          'options': <dynamic>[],
          'effect': <dynamic>[],
          'condition': <dynamic>[],
        },
      },
      'IntentCfg': {
        '1': {
          'id': 1,
          'name': '考进年级前十',
          'group': 999,
          'desc': '努力学习，冲进前十。',
          'npc': 10,
          'finishType': 0,
          'round': 0,
          'before': 0,
          'next': 0,
          'targetRound': 0,
          'weight': 1,
          'tag': 1,
          'renshengguan': 0,
          'demand': [
            [1, 1]
          ],
          'condition': <dynamic>[],
          'reward': <dynamic>[],
          'fail': <dynamic>[],
          'finishTalk': <dynamic>[],
          'failTalk': <dynamic>[],
        },
      },
      'PhoneMsgCfg': {
        '100': {
          'id': 100,
          'role': 10,
          'content': '在吗？',
          'next': [101],
          'option': '',
          'cond': <dynamic>[],
          'effect': <dynamic>[],
        },
      },
      'TalkCfg': {
        '1001': {
          'id': 1001,
          'content': '嗨，早啊',
          'roleIds': [10],
          'nextTalk': <dynamic>[],
          'nextTalk2': <dynamic>[],
        },
      },
      'EvtCfg': {
        '1': {
          'id': 1,
          'title': '开学第一天',
          'type': 0,
          'talkId': [101],
          'rate': 1,
          'npc': 10,
          'maxcount': 0,
          'mapId': 0,
          'effect': <dynamic>[],
          'condition': [
            [1, 1, 3, 5]
          ],
          'displayType': 0,
          'content': '',
          'desc': '',
          'maxoptions': 0,
          'miniGame': <dynamic>[],
          'options': [201],
          'probability': <dynamic>[],
          'replace': <dynamic>[],
          'weight': 1,
        },
      },
      'EvtTypeCfg': {
        '0': {'id': 0, 'name': '回合开始触发', 'type': [1, 3], 'emptyIsTrue': 0},
      },
      'OptionCfg': {
        '201': {'id': 201, 'content': '去上学', 'nextEvtId': 0},
      },
      'MinigameCfg': {
        '5': {'id': 5, 'name': '数独', 'tips': '6×6 数独', 'bgm': 0},
      },
      'MinigameActionCfg': {
        '501': {
          'id': 501,
          'cost': 10,
          'effect': <dynamic>[],
          'loseTalk': 3003,
          'mode': 0,
          'needRelation': 1,
          'parms': [30, 60],
          'startTalk': 3001,
          'winTalk': 3002,
        },
      },
      'GuideCfg': {
        '501': {'id': 501, 'url': 'guide_sudoku', 'tips': '原版玩法说明'},
      },
      'RelationCfg': {
        '1': {'id': 1, 'name': '朋友'},
      },
      'GiftEvtCfg': {
        '1': {
          'id': 1,
          'npc': [10, 20],
          'item': 100,
          'talkId': [
            [2001],
            [2002]
          ],
          'type': [0, 1],
          'cond': <dynamic>[],
          'redpoint': 0,
        },
      },
      'InteractCfg': {
        '1': {
          'id': 1,
          'npc': 10,
          'name': '课间',
          'text': '课间闲聊',
          'map': [101],
          'talkId': 4001,
          'cond': <dynamic>[],
          'effect': <dynamic>[],
        },
      },
      'ItemCfg': {
        '1': {
          'id': 1,
          'name': '苹果',
          'icon': 'item_apple',
          'type': 1,
          'itemTag': [5],
          'effect': <dynamic>[],
          'usingEffect': <dynamic>[],
          'value': 5,
          'sell': 3,
          'desc': '一个苹果',
          'talkId': 0,
          'maxcount': 99,
          'btn': '吃',
          'clothType': 0,
          'needDLC': 0,
          'precondition': <dynamic>[],
          'rarity': 1,
          'sex': 0,
          'subType': 0,
        },
      },
      'BookCfg': {
        '300': {
          'id': 300,
          'name': '语文书',
          'type': 3001,
          'icon': '',
          'itemTag': <dynamic>[],
          'capacity': 10,
          'effect': <dynamic>[],
          'value': -1,
          'sell': -1,
          'desc': '课本书',
          'themes': <dynamic>[],
          'need': <dynamic>[],
          'precondition': <dynamic>[],
          'talk': '',
          'usingEffect': <dynamic>[],
        },
      },
      'ShopCfg': {
        '1': {
          'id': 1,
          'group': 0,
          'price': 10,
          'next': 0,
          'time': 0,
          'discountRound': 0,
          'type': 1,
          'maxcount': 0,
          'precondition': <dynamic>[],
          'probability': 1,
          'buyTalk': '欢迎光临',
          'disappearTime': 0,
          'limcount': 0,
        },
      },
      'ItemTypeCfg': {
        '1': {'id': 1, 'name': '消耗品'},
        '3001': {'id': 3001, 'name': '故事书'},
      },
      'ItemTagCfg': {
        '5': {'id': 5, 'name': '食物'},
      },
      'PersonCfg': {
        '10': {
          'id': 10,
          'name': '测试人物',
          'gender': 2,
          'birthday': [1995, 3, 15],
          'url': ['role_full/p1.png'],
          'url2': ['role_full/p2.png'],
        },
      },
      'PersonGrowCfg': {
        '10': {
          'id': 10,
          'attr': [5, 6, 7],
          'grow': [
            [1, 1, 1]
          ],
          'ItemPref': [
            [1, 3]
          ],
          'personalitys': [10, 0, 0, 10, 10, 0, 0, 10],
        },
      },
      'ModFaceCfg': {
        '10000': {
          'id': 10000,
          'name': '默认',
          'icon': 'face/i.png',
          'icon_xx': 'face/i.png',
        },
      },
      'PersonAttrCfg': {
        '1': {'id': 1, 'name': ['智力']},
      },
      'TraitsCfg': {
        '1': {'id': 1, 'name': '开朗'},
      },
      'PersonStateCfg': {
        '1': {'id': 1, 'name': '生病'},
      },
      'KZoneProfileCfg': {
        '1': {
          'id': 1,
          'name': '小雨',
          'desc': '记录每一天',
          'marriage': [0],
          'hometown': '北京',
          'living': '上海',
          'job': '学生',
          'school': '希望中学',
          'isVip': 1,
          'theme': 1,
          'bgm': 0,
          'font': 101,
          'fontColor': 0,
          'fontSize': 40,
          'icon': 0,
        },
      },
      'KZoneMessageBoardCfg': {
        '1': {
          'id': 1,
          'roles': [10, 1],
          'content': '生日快乐！',
          'isPrivate': 0,
          'round': 0,
          'reply': 0,
          'cond': <dynamic>[],
        },
      },
      'KZoneAvatarCfg': {
        '1': {'id': 1, 'icon': 'avatar_1', 'state': 0, 'type': 0},
      },
      'KZoneColorCfg': {
        '1': {
          'id': 1,
          'name': '经典蓝',
          'bg': '#EAF6FF',
          'imgColor': '#4A90D9',
          'navBg': '#4A90D9',
          'nameTxt': '#FFFFFF',
        },
      },
      'KZoneFontCfg': {
        '101': {'id': 101, 'name': '默认字体'},
      },
    };

/// 各工作台右栏 label（窄屏底部动作条的第二项文案）。
const _rightLabels = <String, String>{
  '社交': '动态设置',
  '目标': '目标设置',
  '消息': '短信设置',
  '闲聊': '对话预览',
  '事件': '概览与引用',
  '小游戏': '游戏概览',
  '外部对话': '对话预览',
  '仓库': '概览与引用',
  '人物': '立绘预览',
  '空间': '空间设置',
  'JSON': '表信息',
  '积木库': '说明',
};

/// 12 个工作台 → 工厂（只依赖 state）。
final _workbenches = <String, Widget Function(AppState)>{
  '社交': (s) => SocialWorkbench(state: s),
  '目标': (s) => GoalsWorkbench(state: s),
  '消息': (s) => MessagesWorkbench(state: s),
  '闲聊': (s) => IdleChatWorkbench(state: s),
  '事件': (s) => EventWorkbench(state: s),
  '小游戏': (s) => MinigamesWorkbench(state: s),
  '外部对话': (s) => ExternalDialoguesWorkbench(state: s),
  '仓库': (s) => WarehouseWorkbench(state: s),
  '人物': (s) => PersonWorkbench(state: s),
  '空间': (s) => SpaceWorkbench(state: s),
  'JSON': (s) => JsonWorkbench(state: s),
  '积木库': (s) => BlocksWorkbench(state: s),
};

void main() {
  setUp(() {
    _savedCfgs.clear();
    SharedPreferences.setMockInitialValues({});
    final tables = _tables();
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'PUT' && path.startsWith('/api/cfg/')) {
        _savedCfgs.add(path.substring('/api/cfg/'.length));
        return _json({'ok': true, 'mtime_ns': 2});
      }
      if (path.startsWith('/api/cfg/')) {
        final cfg = path.substring('/api/cfg/'.length);
        return _json({
          'data': tables[cfg] ?? <String, dynamic>{},
          'exists': true,
          'mtime_ns': 1,
        });
      }
      if (path == '/api/roles') {
        return _json({
          'roles': [
            {'id': '10', 'name': '测试人物', 'portrait1': '', 'portrait2': ''},
          ],
        });
      }
      if (path == '/api/state') {
        return _json({'mod_name': '测试模组', 'ok': true});
      }
      if (path == '/api/effect/parse') {
        return _json({
          'ok': true,
          'status': 'ok',
          'translations': const [],
          'rows': const [],
        });
      }
      if (path == '/api/effect_suggest') {
        return _json({'items': const []});
      }
      return _json({'data': {}, 'ok': true});
    });
  });

  tearDown(() => ApiClient.instance.client = http.Client());

  Future<void> mount(WidgetTester t, AppState s, String name, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      // 真实宿主（移动壳 / 桌面壳）本身是 Material Scaffold；这里补上，
      // 否则窄屏动作条的 Material InkWell 找不到 Material 祖先。
      home: Scaffold(body: _workbenches[name]!(s)),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
  }

  // ---------------- 1. 12 个工作台 × 2 种手机尺寸：无溢出 + 主从形态可用 ----------------
  for (final name in _workbenches.keys) {
    final rightLabel = _rightLabels[name]!;
    for (final size in _sizes) {
      final tag = '${size.width.toInt()}×${size.height.toInt()}';
      testWidgets('$name @ $tag：无溢出 + 底部动作条', (t) async {
        await mount(t, AppState()..modName = '测试模组', name, size);

        expect(t.takeException(), isNull, reason: '$name 在 $tag 溢出');
        // 窄屏主从形态：列表铺满 + 底部「打开编辑 / <右栏名>」动作条。
        expect(find.text('打开编辑'), findsOneWidget,
            reason: '$name 在 $tag 缺底部动作条');
        expect(find.text(rightLabel), findsOneWidget,
            reason: '$name 在 $tag 缺右栏入口');
      });

      testWidgets('$name @ $tag：打开编辑页 → 设置滑出层，均可返回', (t) async {
        await mount(t, AppState()..modName = '测试模组', name, size);

        await t.tap(find.text('打开编辑'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(find.byType(BackButton), findsOneWidget,
            reason: '$name 未 push 出编辑页');
        expect(t.takeException(), isNull);

        // 编辑页底部「设置」→ 底部滑出层（列表页那份在下层，取最后一个）。
        await t.tap(find.text(rightLabel).last);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(t.takeException(), isNull);

        // 点遮罩收起滑出层，再返回列表页。
        await t.tapAt(const Offset(8, 8));
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.byType(BackButton));
        await t.pump(const Duration(milliseconds: 400));
        expect(find.text('打开编辑'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }

  // ---------------- 2. 触控目标 ≥44dp（底部动作条） ----------------
  testWidgets('底部动作条点击区高度 ≥44dp', (t) async {
    await mount(t, AppState()..modName = '测试模组', '社交', const Size(390, 844));

    final tapArea = find.ancestor(
      of: find.text('打开编辑'),
      matching: find.byType(InkWell),
    );
    expect(tapArea, findsWidgets);
    final h = t.getSize(tapArea.first).height;
    expect(h, greaterThanOrEqualTo(44),
        reason: '动作条点击区高度 $h < 44dp');
  });

  // ---------------- 3. 打开→编辑→保存（每批一个代表） ----------------
  // 手机宽度下编辑区在「打开编辑」push 出的编辑页里（右栏改为底部滑出层）。
  // 三个代表各自沿用其单测里已验证的「置脏」动作，保存经 PUT /api/cfg/<cfg> 落盘。
  Future<void> openEditor(WidgetTester t) async {
    await t.tap(find.text('打开编辑'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> saveAndExpect(WidgetTester t, String name, String cfg) async {
    // 编辑后编辑页必须实时翻脏（否则 SaveBar 禁用、点保存无 PUT）。
    // 这条同时是「窄屏编辑页/滑出层非快照」的回归断言。
    expect(find.text('有未保存的修改'), findsWidgets, reason: '$name 编辑后未置脏');
    expect(find.text('保存修改'), findsWidgets, reason: '$name 缺保存条');
    await t.tap(find.text('保存修改').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(_savedCfgs, contains(cfg), reason: '$name 未保存到 $cfg');
    // 等保存成功的 InfoBar 自动关闭，避免遗留定时器。
    await t.pump(const Duration(seconds: 4));
    expect(t.takeException(), isNull);
  }

  // 批次1 代表：JSON（选表 EvtCfg → 改原始 JSON → 保存写回 EvtCfg）。
  testWidgets('批次1 代表「JSON」：打开→编辑→保存', (t) async {
    await mount(t, AppState()..modName = '测试模组', 'JSON', const Size(390, 844));

    // 列表页即左栏配置表列表：过滤并选中 EvtCfg。
    await t.enterText(find.byType(fluent.TextBox).first, 'EvtCfg');
    await t.pump();
    await t.tap(find.text('EvtCfg').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    await openEditor(t);
    // 中栏即原始 JSON 编辑区（最靠后的文本框）；改内容触发脏状态。
    await t.enterText(
        find.byType(fluent.TextBox).last, '{"id":1,"title":"改过了"}');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await saveAndExpect(t, 'JSON', 'EvtCfg');
  });

  // 批次2 代表：外部对话（切换「仅播放对话」置脏 → 保存写回 GiftEvtCfg）。
  testWidgets('批次2 代表「外部对话」：打开→编辑→保存', (t) async {
    await mount(t, AppState()..modName = '测试模组', '外部对话', const Size(390, 844));
    await openEditor(t);
    await t.tap(find.text('仅播放对话').first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await saveAndExpect(t, '外部对话', 'GiftEvtCfg');
  });

  // 批次3 代表：仓库（切「标签」页 → 点「食物」标签置脏 → 保存写回 ItemCfg）。
  testWidgets('批次3 代表「仓库」：打开→编辑→保存', (t) async {
    await mount(t, AppState()..modName = '测试模组', '仓库', const Size(390, 844));
    await openEditor(t);
    await t.tap(find.text('标签').first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.text('食物').first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await saveAndExpect(t, '仓库', 'ItemCfg');
  });
}
