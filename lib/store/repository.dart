/// 错题本仓库（本地 JSON 持久化）。
///
/// 设计要点：
///   1) **存的是"题目参数"而不是渲染结果**。竖式存 (kind, args) 以便重放，
///      几何存 FigureSpec —— 这样导出 PDF 时能重新求解、按 PDF 精度重画，
///      而不是把屏幕上的 SVG 塞进去（那样打印会糊）。
///   2) 重要度与 FSRS 分开：重要度决定"排多前"（清单优先度），
///      FSRS 的 due 决定"什么时候该复习"（时间调度），两件事不能混为一谈。
library;

import 'dart:convert';
import 'dart:io';

import '../geometry/dsl/figure.dart';
import '../quiz/question.dart';
import '../review/fsrs.dart';
import '../typeset/vertical.dart';

/// 一条错题/待复习记录。
class ReviewRecord {
  /// 题目稳定 id
  final String id;

  final String kind;
  final String stem;
  final int grade;
  final String kpPath;
  final String? kpCode;
  final int difficulty;

  /// 正确答案文本
  final String answer;

  /// 分步讲解
  final List<String> steps;

  /// 几何题的 spec（用于重新求解画图）
  final Map<String, Object?>? figureSpec;

  /// 竖式重放参数：(kind, [args])
  final String? verticalKind;
  final List<int> verticalArgs;

  /// FSRS 状态
  final FsrsState fsrs;

  /// 重要度 0..10（决定在清单里的优先度）
  final int importance;

  /// 连续答对次数
  final int streak;

  final int wrongCount;
  final int rightCount;
  final DateTime createdAt;
  final DateTime lastSeen;

  const ReviewRecord({
    required this.id,
    required this.kind,
    required this.stem,
    required this.grade,
    required this.kpPath,
    required this.answer,
    required this.steps,
    required this.fsrs,
    required this.importance,
    required this.streak,
    required this.wrongCount,
    required this.rightCount,
    required this.createdAt,
    required this.lastSeen,
    this.kpCode,
    this.difficulty = 2,
    this.figureSpec,
    this.verticalKind,
    this.verticalArgs = const [],
  });

  ReviewRecord copyWith({
    FsrsState? fsrs,
    int? importance,
    int? streak,
    int? wrongCount,
    int? rightCount,
    DateTime? lastSeen,
  }) =>
      ReviewRecord(
        id: id,
        kind: kind,
        stem: stem,
        grade: grade,
        kpPath: kpPath,
        kpCode: kpCode,
        difficulty: difficulty,
        answer: answer,
        steps: steps,
        figureSpec: figureSpec,
        verticalKind: verticalKind,
        verticalArgs: verticalArgs,
        fsrs: fsrs ?? this.fsrs,
        importance: importance ?? this.importance,
        streak: streak ?? this.streak,
        wrongCount: wrongCount ?? this.wrongCount,
        rightCount: rightCount ?? this.rightCount,
        createdAt: createdAt,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  /// 需要重点关照（重要度达到阈值）
  bool get needsAttention => ImportancePolicy.defaultPolicy.needsAttention(importance);

  /// 是否已到复习时间
  bool isDue(DateTime now) => !fsrs.due.isAfter(now);

  Map<String, Object?> toMap() => {
        'id': id,
        'kind': kind,
        'stem': stem,
        'grade': grade,
        'kpPath': kpPath,
        'kpCode': kpCode,
        'difficulty': difficulty,
        'answer': answer,
        'steps': steps,
        'figureSpec': figureSpec,
        'verticalKind': verticalKind,
        'verticalArgs': verticalArgs,
        'fsrs': fsrs.toMap(),
        'importance': importance,
        'streak': streak,
        'wrongCount': wrongCount,
        'rightCount': rightCount,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastSeen': lastSeen.millisecondsSinceEpoch,
      };

  factory ReviewRecord.fromMap(Map<String, Object?> m) => ReviewRecord(
        id: m['id'] as String,
        kind: (m['kind'] as String?) ?? '',
        stem: (m['stem'] as String?) ?? '',
        grade: (m['grade'] as int?) ?? 3,
        kpPath: (m['kpPath'] as String?) ?? '',
        kpCode: m['kpCode'] as String?,
        difficulty: (m['difficulty'] as int?) ?? 2,
        answer: (m['answer'] as String?) ?? '',
        steps: ((m['steps'] as List?) ?? const []).map((e) => '$e').toList(),
        figureSpec: (m['figureSpec'] as Map?)?.cast<String, Object?>(),
        verticalKind: m['verticalKind'] as String?,
        verticalArgs: ((m['verticalArgs'] as List?) ?? const []).map((e) => e as int).toList(),
        fsrs: FsrsState.fromMap((m['fsrs'] as Map?)?.cast<String, Object?>() ?? const {}),
        importance: (m['importance'] as int?) ?? 0,
        streak: (m['streak'] as int?) ?? 0,
        wrongCount: (m['wrongCount'] as int?) ?? 0,
        rightCount: (m['rightCount'] as int?) ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch((m['createdAt'] as int?) ?? 0),
        lastSeen: DateTime.fromMillisecondsSinceEpoch((m['lastSeen'] as int?) ?? 0),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'stem': stem,
        'grade': grade,
        'kpPath': kpPath,
        'difficulty': difficulty,
        'importance': importance,
        'wrongCount': wrongCount,
        'rightCount': rightCount,
        'streak': streak,
        'due': fsrs.due.millisecondsSinceEpoch,
        'isDue': isDue(DateTime.now()),
        'answer': answer,
        'steps': steps,
      };
}

/// 错题本仓库。
class WrongBookRepository {
  final File file;
  final FsrsScheduler scheduler;
  final ImportancePolicy policy;

  final Map<String, ReviewRecord> _records = {};

  WrongBookRepository({required this.file, FsrsScheduler? scheduler, ImportancePolicy? policy})
      : scheduler = scheduler ?? const FsrsScheduler(),
        policy = policy ?? ImportancePolicy.defaultPolicy;

  /// 数据文件路径（放在用户目录下，避免误删工程时被一起删掉）。
  static File defaultFile() {
    final base = Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final dir = Directory('$base${Platform.pathSeparator}.math_coach');
    return File('${dir.path}${Platform.pathSeparator}wrongbook.json');
  }

  Future<void> load() async {
    _records.clear();
    if (!await file.exists()) return;
    try {
      final txt = await file.readAsString();
      if (txt.trim().isEmpty) return;
      final m = jsonDecode(txt);
      final list = (m['records'] as List?) ?? const [];
      for (final e in list) {
        final r = ReviewRecord.fromMap((e as Map).cast<String, Object?>());
        _records[r.id] = r;
      }
    } catch (e) {
      // 数据文件损坏不能让 App 起不来：备份后用空库继续
      try {
        await file.rename('${file.path}.broken-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
    }
  }

  Future<void> save() async {
    await file.parent.create(recursive: true);
    final data = {
      'version': 1,
      'savedAt': DateTime.now().toIso8601String(),
      'records': _records.values.map((e) => e.toMap()).toList(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  ReviewRecord? get(String id) => _records[id];

  /// 直接写入一条记录（导入备份用）。调用方负责之后 [save] 落盘。
  ///
  /// 刻意不做任何合并策略 —— 策略在 `store/backup.dart` 里，
  /// 那里要同时看得见新旧两条才能决定谁当底子。
  void put(ReviewRecord r) {
    _records[r.id] = r;
  }

  List<ReviewRecord> get all => _records.values.toList()
    ..sort((a, b) => b.importance.compareTo(a.importance));

  int get count => _records.length;

  /// 统计：答就对了
  ({int due, int attention, int mastered}) stats(DateTime now) {
    var due = 0;
    var attention = 0;
    var mastered = 0;
    for (final r in _records.values) {
      if (r.isDue(now)) due++;
      if (r.needsAttention) attention++;
      if (r.importance == 0 && r.rightCount > 0 && r.wrongCount == 0) mastered++;
    }
    return (due: due, attention: attention, mastered: mastered);
  }

  /// 到期的复习队列：先重要度、再到期时间。
  List<ReviewRecord> dueQueue(DateTime now, {int limit = 20}) {
    final list = _records.values.where((r) => r.isDue(now)).toList();
    list.sort((a, b) {
      final c = b.importance.compareTo(a.importance);
      return c != 0 ? c : a.fsrs.due.compareTo(b.fsrs.due);
    });
    return list.take(limit).toList();
  }

  /// 记一次作答：更新 FSRS 与重要度，落盘。
  Future<ReviewRecord> recordAttempt(
    QuizQuestion q, {
    required bool correct,
    Rating rating = Rating.good,
    Map<String, Object?>? figureSpec,
    String? verticalKind,
    List<int> verticalArgs = const [],
  }) async {
    final now = DateTime.now();
    final prev = _records[q.id];
    if (prev == null) {
      final created = ReviewRecord(
        id: q.id,
        kind: q.kind,
        stem: q.stem,
        grade: q.grade,
        kpPath: q.kpPath,
        kpCode: q.kpCode,
        difficulty: q.difficulty,
        answer: q.answer.display,
        steps: q.solutionSteps,
        figureSpec: figureSpec,
        verticalKind: verticalKind,
        verticalArgs: verticalArgs,
        fsrs: FsrsScheduler().review(FsrsState.initial(now), rating, now),
        importance: correct ? 0 : 1,
        streak: correct ? 1 : 0,
        wrongCount: correct ? 0 : 1,
        rightCount: correct ? 1 : 0,
        createdAt: now,
        lastSeen: now,
      );
      _records[q.id] = created;
      await save();
      return created;
    }

    final applied = policy.apply(
      importance: prev.importance,
      streak: prev.streak,
      correct: correct,
    );
    final nextFsrs = scheduler.review(prev.fsrs, rating, now);
    final updated = prev.copyWith(
      fsrs: nextFsrs,
      importance: applied.importance,
      streak: applied.streak,
      wrongCount: prev.wrongCount + (correct ? 0 : 1),
      rightCount: prev.rightCount + (correct ? 1 : 0),
      lastSeen: now,
    );
    _records[q.id] = updated;
    await save();
    return updated;
  }

  /// 清空（"重新开始"用）
  Future<void> clear() async {
    _records.clear();
    await save();
  }

  void delete(String id) {
    _records.remove(id);
  }
}

/// 竖式重放：导出 PDF 时按记录里的 (kind, args) 重建，
/// 保证试卷上的竖式和孩子当时看到的完全一致。
class VerticalReplay {
  /// [withAnswer] 为 false 时排出的竖式不含进位/结果（练习与试卷形态）。
  static VerticalLayout? layout(String kind, List<int> args, {bool withAnswer = true}) {
    if (args.isEmpty) return null;
    switch (kind) {
      case 'add':
        return args.length >= 2 ? VerticalTypeset.add(args[0], args[1], withAnswer: withAnswer) : null;
      case 'sub':
        return args.length >= 2 ? VerticalTypeset.sub(args[0], args[1], withAnswer: withAnswer) : null;
      case 'mul':
        return args.length >= 2 ? VerticalTypeset.mul(args[0], args[1], withAnswer: withAnswer) : null;
      default:
        return null;
    }
  }

  static LongDivision? longDivision(List<int> args, {bool withAnswer = true}) {
    if (args.length < 2) return null;
    return VerticalTypeset.div(args[0], args[1], withAnswer: withAnswer);
  }

  static FigureSpec? figure(Map<String, Object?>? spec) {
    if (spec == null || spec.isEmpty) return null;
    try {
      return FigureSpec.fromJson(spec);
    } catch (_) {
      return null;
    }
  }
}
