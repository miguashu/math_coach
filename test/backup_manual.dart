/// 备份/恢复的离线回归（用 dart run 跑，本机跑不了 dart test）。
///
/// 覆盖的是"数据安全"这一块：导出格式、解析校验、合并规则。
/// 这些错了不会崩，只会**悄悄丢数据** —— 所以必须断言。
library;

import 'dart:io';

import 'package:math_coach/review/fsrs.dart';
import 'package:math_coach/store/backup.dart';
import 'package:math_coach/store/repository.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, bool cond) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
    print('  [FAIL] $name');
  }
}

ReviewRecord rec({
  required String id,
  int importance = 1,
  int wrong = 1,
  int right = 0,
  DateTime? due,
  DateTime? lastSeen,
}) {
  final now = DateTime(2026, 1, 1);
  return ReviewRecord(
    id: id,
    kind: 'add',
    stem: '题 $id',
    grade: 3,
    kpPath: '数与代数',
    answer: '1',
    steps: const ['一'],
    fsrs: FsrsState(
      stability: 1,
      difficulty: 5,
      due: due ?? now,
      reps: 1,
      lapses: 0,
    ),
    importance: importance,
    streak: 0,
    wrongCount: wrong,
    rightCount: right,
    createdAt: now,
    lastSeen: lastSeen ?? now,
  );
}

class MemRepo extends WrongBookRepository {
  MemRepo() : super(file: File('${Directory.systemTemp.path}/mc_backup_test.json'));
}

void main() async {
  print('=== 备份/恢复回归 ===');

  // 1) 编码出来能被解析回去，条数一致
  final src = [rec(id: 'a'), rec(id: 'b', importance: 4)];
  final text = BackupCodec.encode(src);
  final back = BackupCodec.decode(text);
  ok('编码后能解析回来', back.length == 2);
  ok('id 保住', back.map((e) => e.id).toSet().containsAll(['a', 'b']));
  ok('重要度保住', back.firstWhere((e) => e.id == 'b').importance == 4);

  // 2) 文件标记：不是本 App 的备份要被挡住
  var threw = false;
  try {
    BackupCodec.decode('{"kind":"other","records":[]}');
  } on BackupError {
    threw = true;
  }
  ok('别人的 json 会被拒绝', threw);

  // 3) 空文件 / 非 JSON / 没有 records 都要给出人话错误
  for (final bad in ['', 'not json', '{}', '{"kind":"mathcoach-backup"}']) {
    var t = false;
    try {
      BackupCodec.decode(bad);
    } on BackupError {
      t = true;
    }
    ok('坏输入被拒绝: ${bad.isEmpty ? "(空)" : bad}', t);
  }

  // 4) 老格式（直接拷的 wrongbook.json，没有 kind）也要能认
  final legacy = '{"version":1,"records":[${'''
  {"id":"legacy1","kind":"add","stem":"旧","grade":3,"kpPath":"x","answer":"2",
   "steps":[],"fsrs":{},"importance":2,"streak":0,"wrongCount":1,"rightCount":0,
   "createdAt":0,"lastSeen":0}'''}]}';
  final legacyRecs = BackupCodec.decode(legacy);
  ok('老格式（无 kind）也能导入', legacyRecs.length == 1);

  // 5) 合并：新 id 是新增，已有 id 是合并
  final repo = MemRepo();
  repo.put(rec(id: 'a', importance: 3, wrong: 2));
  var r = mergeInto(repo, [rec(id: 'a', wrong: 5), rec(id: 'c')]);
  ok('新 id 记为新增', r.added == 1);
  ok('已有 id 记为合并', r.merged == 1);

  // 6) 合并规则：次数取大
  final mergedA = repo.get('a')!;
  ok('错题次数取大', mergedA.wrongCount == 5);

  // 7) 合并规则：重要度取小（已掌握的不该被旧备份拽回来）
  final repo2 = MemRepo();
  repo2.put(rec(id: 'm', importance: 0, right: 3)); // 本机：连对，已掌握
  mergeInto(repo2, [rec(id: 'm', importance: 5, wrong: 4)]); // 备份：以前错得多
  ok('重要度取小（掌握了就不会被拽回清单）', repo2.get('m')!.importance == 0);

  // 8) 合并规则：到期时间取更晚（宁可晚也不要漏练）
  final repo3 = MemRepo();
  repo3.put(rec(id: 'd', due: DateTime(2026, 3, 1)));
  mergeInto(repo3, [rec(id: 'd', due: DateTime(2026, 5, 1))]);
  ok('到期取更晚', repo3.get('d')!.fsrs.due == DateTime(2026, 5, 1));

  // 9) 合并后总数
  final repo4 = MemRepo();
  repo4.put(rec(id: 'x'));
  final r4 = mergeInto(repo4, [rec(id: 'x'), rec(id: 'y'), rec(id: 'z')]);
  ok('总数正确', r4.total == 3 && repo4.count == 3);

  print('');
  print(_fail == 0 ? '全部通过（$_pass 条）' : '失败 $_fail 条 / 共 ${_pass + _fail} 条');
  if (_fail > 0) exitCode = 1;
}
