// 回归测试：故事编排「插入对话」的节点构建。
// 覆盖 buildInsertedTalkRecord 的 roleIds 复制语义——新节点必须
// 复制而非共享原节点的 roleIds 列表，否则任一方原地修改会互相污染。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_logic.dart';

void main() {
  test('insertTalkId 分配唯一 ID（跳过已占用）', () {
    final talks = <String, dynamic>{
      '32010101': {'roleIds': <dynamic>[1]},
      '32010102': {'roleIds': <dynamic>[2]},
    };
    expect(insertTalkId('32010101', talks), '32010103');
  });

  test('buildInsertedTalkRecord 复制原节点 roleIds，不共享引用', () {
    final curTalk = <String, dynamic>{'roleIds': <dynamic>[1, 2]};
    final record = buildInsertedTalkRecord(curTalk, '32010103', <dynamic>[]);

    expect(record['roleIds'], [1, 2]);

    // 编辑器修改新节点 roleIds（原地 add），原节点不受影响
    (record['roleIds'] as List).add(3);
    expect(curTalk['roleIds'], [1, 2],
        reason: '新节点的修改不应污染原节点的 roleIds');

    // 反向同理：修改原节点不影响新节点
    (curTalk['roleIds'] as List).clear();
    expect(record['roleIds'], [1, 2, 3],
        reason: '原节点的修改不应污染新节点的 roleIds');
  });

  test('buildInsertedTalkRecord 无原节点时 roleIds 为空', () {
    final record = buildInsertedTalkRecord(null, '32010103', <dynamic>[]);
    expect(record['roleIds'], <dynamic>[]);
    expect(record['id'], 32010103);
    expect(record['content'], '【新插入的对话】');
    expect(record['nextTalk'], <dynamic>[]);
  });

  test('buildInsertedTalkRecord 保留原节点 nextTalk 跳转', () {
    final curTalk = <String, dynamic>{'roleIds': <dynamic>[1]};
    final record = buildInsertedTalkRecord(curTalk, '32010103', <dynamic>[32010104]);
    expect(record['nextTalk'], [32010104]);
  });
}
