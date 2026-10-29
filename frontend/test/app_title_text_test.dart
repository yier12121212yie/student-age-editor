// 浏览器标签页标题拼装（core/app_title_text.dart）回归。
//
// 背景：Web 版是单页应用，同时开多个标签页时标题原本恒为静态文案，分不清
// 哪个是哪个模组/文档。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/app_title_text.dart';

void main() {
  test('无模组无文档：基础标题', () {
    expect(
      composeAppTitle(modName: '', modDisplayName: '', docTitle: null),
      kBaseAppTitle,
    );
  });

  test('只选模组：模组名 + 基础标题', () {
    expect(
      composeAppTitle(modName: 'my_mod', modDisplayName: '我的模组'),
      '我的模组 — $kBaseAppTitle',
    );
  });

  test('文档优先于模组', () {
    expect(
      composeAppTitle(
          modName: 'my_mod', modDisplayName: '我的模组', docTitle: 'TalkCfg'),
      'TalkCfg · 我的模组 — $kBaseAppTitle',
    );
  });

  test('文档名与模组展示名相同时不重复', () {
    expect(
      composeAppTitle(
          modName: 'my_mod', modDisplayName: '我的模组', docTitle: '我的模组'),
      '我的模组 — $kBaseAppTitle',
    );
  });

  test('展示名缺失时回落到基础标题而不是空串', () {
    expect(
      composeAppTitle(modName: 'my_mod', modDisplayName: '  ', docTitle: ' '),
      'my_mod — $kBaseAppTitle',
    );
  });

  test('只有文档没有模组：文档 + 基础标题', () {
    expect(
      composeAppTitle(modName: '', modDisplayName: '', docTitle: '预览 #12'),
      '预览 #12 — $kBaseAppTitle',
    );
  });
}
