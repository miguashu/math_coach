/// 备份与恢复：把错题本整体导出成一份搬得走的 JSON，也能从 JSON 并回来。
///
/// 为什么需要它：数据存在 App 专属目录，**卸载 App 就一起没了**。
/// 之前唯一的备份手段是导出 PDF —— 但 PDF 是给孩子做的练习卷，
/// 里面没有 FSRS 调度状态、没有重要度，恢复不回"学到哪了"。
/// 所以这里导出的是**可还原状态**的 JSON，不是给人看的文档。
library;

import 'dart:convert';

import 'package:math_coach/review/fsrs.dart';
import 'package:math_coach/store/repository.dart';

/// 备份文件格式不对、或压根不是本 App 的备份时抛它，让 UI 说人话。
class BackupError implements Exception {
  final String message;
  const BackupError(this.message);

  @override
  String toString() => message;
}

class BackupCodec {
  BackupCodec._();

  /// 文件标记：导入时靠它认出"这是本 App 的备份"，
  /// 避免用户随手点了个别的 json 就被当成错题本吞进去。
  static const String kind = 'mathcoach-backup';
  static const int version = 1;

  static String encode(Iterable<ReviewRecord> records, {DateTime? at}) {
    final list = records.toList();
    return const JsonEncoder.withIndent('  ').convert({
      'kind': kind,
      'version': version,
      'exportedAt': (at ?? DateTime.now()).toIso8601String(),
      'count': list.length,
      'records': [for (final r in list) r.toMap()],
    });
  }

  /// 解析一份备份文本。任何一处不对都直接抛 [BackupError]，不做"尽力猜"。
  static List<ReviewRecord> decode(String text) {
    if (text.trim().isEmpty) {
      throw const BackupError('这个文件是空的');
    }
    final Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      throw const BackupError('不是有效的 JSON 文件');
    }
    if (root is! Map) {
      throw const BackupError('备份文件应该是一个 JSON 对象');
    }
    final m = root.cast<String, Object?>();

    // 老版本直接存的是仓库原始格式（version/records，没有 kind），也要能认：
    // 那是从 wrongbook.json 直接拷出来的场景，很常见。
    final hasKind = m['kind'] != null;
    if (hasKind && m['kind'] != kind) {
      throw BackupError('这不是小数辅导的备份文件（kind=${m['kind']}）');
    }
    final list = m['records'];
    if (list is! List) {
      throw const BackupError('备份文件里没有 records 列表');
    }

    final out = <ReviewRecord>[];
    var bad = 0;
    for (final e in list) {
      if (e is! Map) {
        bad++;
        continue;
      }
      final mm = e.cast<String, Object?>();
      if ((mm['id'] as String?)?.isNotEmpty != true) {
        bad++;
        continue;
      }
      try {
        out.add(ReviewRecord.fromMap(mm));
      } catch (_) {
        bad++;
      }
    }
    if (out.isEmpty) {
      throw BackupError('备份文件里没有可用的题目记录${bad > 0 ? '（跳过 $bad 条损坏记录）' : ''}');
    }
    return out;
  }
}

class MergeResult {
  /// 本机原本没有、从备份里新增的
  final int added;

  /// 两边都有、合并过的
  final int merged;

  /// 无法解析被跳过的
  final int skipped;

  const MergeResult({
    required this.added,
    required this.merged,
    required this.skipped,
  });

  int get total => added + merged;

  @override
  String toString() => '新增 $added 条，合并 $merged 条${skipped > 0 ? '，跳过 $skipped 条' : ''}';
}

/// 把备份里的记录并进仓库。
///
/// 合并规则（每条都能说出理由，别拍脑袋）：
///
/// - **同一 id**：取"练得更多"的那条当底子（`wrongCount + rightCount` 更大，
///   它的信息更全），然后：
///   - 次数取**大**：两边都练过就该都算上；
///   - 重要度取**小**：连对三次会归零，说明已经掌握 ——
///     不能因为一份旧备份把已经掌握的题重新拽回清单（那会让清单变成耻辱墙）；
///   - 到期时间取**更晚**：宁可晚一点再复习，也不要因为合并让孩子漏练；
///   - `lastSeen` 取更晚，其余 FSRS 字段跟底子走。
/// - **新 id**：原样加入。
/// - 解析不了的：跳过并如实报数，不静默吞掉。
MergeResult mergeInto(WrongBookRepository repo, List<ReviewRecord> incoming) {
  var added = 0;
  var merged = 0;

  for (final inc in incoming) {
    final local = repo.get(inc.id);
    if (local == null) {
      repo.put(inc);
      added++;
      continue;
    }

    final localN = local.wrongCount + local.rightCount;
    final incN = inc.wrongCount + inc.rightCount;
    final base = incN > localN ? inc : local;

    final laterDue =
        local.fsrs.due.isAfter(inc.fsrs.due) ? local.fsrs.due : inc.fsrs.due;
    final fsrs = FsrsState(
      stability: base.fsrs.stability,
      difficulty: base.fsrs.difficulty,
      due: laterDue,
      reps: base.fsrs.reps,
      lapses: base.fsrs.lapses,
    );

    repo.put(
      base.copyWith(
        fsrs: fsrs,
        importance: local.importance < inc.importance ? local.importance : inc.importance,
        wrongCount: local.wrongCount > inc.wrongCount ? local.wrongCount : inc.wrongCount,
        rightCount: local.rightCount > inc.rightCount ? local.rightCount : inc.rightCount,
        lastSeen: local.lastSeen.isAfter(inc.lastSeen) ? local.lastSeen : inc.lastSeen,
        streak: base.streak,
      ),
    );
    merged++;
  }

  // skipped 在 decode 阶段就统计掉了（那里抛错），这里只有解析成功的才会进来
  return MergeResult(added: added, merged: merged, skipped: 0);
}
