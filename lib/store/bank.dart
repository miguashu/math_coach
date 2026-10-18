/// 衍生题库：从错题衍生出来的练习题，落盘持久化。
///
/// 为什么要单独一个库（不塞进错题本）：
///   - 错题本是「欠账清单」，按重要度和 FSRS 调度，一条记录代表**一道孩子做错过的题**；
///   - 题库是「补给站」，一条记录代表**为某道错题造出来的新练习题**，
///     它没有 FSRS 状态、不参与到期调度，只记"练过没、过没过"。
///   两者混在一起，错题本的重要度统计会被练习题稀释，"要重点看"就失真了。
///
/// 与错题本一致的规矩：
///   - 存题目参数（题干/答案写法/单位）而不是渲染结果；
///   - 数据文件坏了**改名备份后用空库继续**，不能让 App 起不来（见 repository.dart）。
library;

import 'dart:convert';
import 'dart:io';

import '../quiz/question.dart';

/// 一条衍生题记录。
class BankEntry {
  /// 稳定 id：由**规范化题干**推出来（同题不同次生成拿到同一个 id，天然去重）
  final String id;

  /// 来源错题：id 用于回查，题干用于"想不起来就看原题"
  final String sourceQuestionId;
  final String sourceStem;

  final String stem;

  /// 答案展示文本（可能含单位，如 "12 支" / "4……4"）
  final String answer;

  /// 数值形态（判分容差用；余数题给的是商）
  final double? answerValue;
  final String unit;

  /// 额外的可接受写法
  final List<String> accepts;

  /// 讲解：本地衍生题只有一句"做法和原题一样"，AI 衍生题带模型给的分步
  final List<String> steps;

  final String kpPath;
  final String? kpCode;
  final int grade;
  final int difficulty;

  /// 谁造的：'local' = 本地变体模板（答案必对）/ 'ai' = 模型现场出（已过本地复算）
  final String origin;

  final DateTime createdAt;

  /// 练习痕迹
  final int attempts;
  final int wrongCount;

  /// 连续答对次数
  final int streak;

  /// 过关（连续答对 [passStreak] 次）
  final bool passed;

  /// 连续答对几次算过关。
  ///
  /// 为什么不是"对一次就过"：这类题是**换数字**的同型题，
  /// 答对一次很可能是顺着上一题的惯性；连对两次才更像真的会了。
  /// 也不设成 3 次 —— 一道衍生题练三遍，孩子会腻，练到第三次
  /// 记住的往往是数字而不是方法。
  static const passStreak = 2;

  const BankEntry({
    required this.id,
    required this.sourceQuestionId,
    required this.sourceStem,
    required this.stem,
    required this.answer,
    required this.kpPath,
    required this.grade,
    required this.origin,
    required this.createdAt,
    this.answerValue,
    this.unit = '',
    this.accepts = const [],
    this.steps = const [],
    this.kpCode,
    this.difficulty = 2,
    this.attempts = 0,
    this.wrongCount = 0,
    this.streak = 0,
    this.passed = false,
  });

  bool get isAi => origin == 'ai';

  /// 还没做过
  bool get untouched => attempts == 0;

  BankEntry copyWith({
    int? attempts,
    int? wrongCount,
    int? streak,
    bool? passed,
  }) =>
      BankEntry(
        id: id,
        sourceQuestionId: sourceQuestionId,
        sourceStem: sourceStem,
        stem: stem,
        answer: answer,
        answerValue: answerValue,
        unit: unit,
        accepts: accepts,
        steps: steps,
        kpPath: kpPath,
        kpCode: kpCode,
        grade: grade,
        difficulty: difficulty,
        origin: origin,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        wrongCount: wrongCount ?? this.wrongCount,
        streak: streak ?? this.streak,
        passed: passed ?? this.passed,
      );

  /// 转成可练的题：id 用题库 id，答错的归档才追得回来。
  QuizQuestion toQuestion() => QuizQuestion(
        id: id,
        kpPath: kpPath,
        kpCode: kpCode,
        grade: grade,
        stem: stem,
        solutionSteps: steps,
        answer: QuizAnswer(
          display: answer,
          value: answerValue,
          unit: unit,
          accepts: accepts,
        ),
        kind: 'derived',
        difficulty: difficulty,
        // 让卡片上的徽标如实反映"谁造的题"
        source: isAi ? 'ai' : 'local',
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'sourceQuestionId': sourceQuestionId,
        'sourceStem': sourceStem,
        'stem': stem,
        'answer': answer,
        'answerValue': answerValue,
        'unit': unit,
        'accepts': accepts,
        'steps': steps,
        'kpPath': kpPath,
        'kpCode': kpCode,
        'grade': grade,
        'difficulty': difficulty,
        'origin': origin,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'attempts': attempts,
        'wrongCount': wrongCount,
        'streak': streak,
        'passed': passed,
      };

  factory BankEntry.fromMap(Map<String, Object?> m) => BankEntry(
        id: (m['id'] as String?) ?? '',
        sourceQuestionId: (m['sourceQuestionId'] as String?) ?? '',
        sourceStem: (m['sourceStem'] as String?) ?? '',
        stem: (m['stem'] as String?) ?? '',
        answer: (m['answer'] as String?) ?? '',
        answerValue: (m['answerValue'] as num?)?.toDouble(),
        unit: (m['unit'] as String?) ?? '',
        accepts: ((m['accepts'] as List?) ?? const []).map((e) => '$e').toList(),
        steps: ((m['steps'] as List?) ?? const []).map((e) => '$e').toList(),
        kpPath: (m['kpPath'] as String?) ?? '',
        kpCode: m['kpCode'] as String?,
        grade: (m['grade'] as int?) ?? 3,
        difficulty: (m['difficulty'] as int?) ?? 2,
        origin: (m['origin'] as String?) ?? 'local',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch((m['createdAt'] as int?) ?? 0),
        attempts: (m['attempts'] as int?) ?? 0,
        wrongCount: (m['wrongCount'] as int?) ?? 0,
        streak: (m['streak'] as int?) ?? 0,
        passed: (m['passed'] as bool?) ?? false,
      );
}

/// 按来源错题分组后的一组衍生题（界面按组展示）。
class BankGroup {
  final String sourceQuestionId;
  final String sourceStem;
  final List<BankEntry> entries;
  const BankGroup({
    required this.sourceQuestionId,
    required this.sourceStem,
    required this.entries,
  });

  int get pending => entries.where((e) => !e.passed).length;
  bool get allPassed => entries.isNotEmpty && pending == 0;
}

/// 题库仓库（本地 JSON 持久化）。
class QuestionBank {
  final File file;
  final Map<String, BankEntry> _entries = {};

  QuestionBank({required this.file});

  /// 同一道题反复生成不许重复入账：按**规范化题干**判重。
  ///
  /// 归一化刻意做得比判分宽松度更轻：只统一全角数字/运算符与空白，
  /// 不动标点和词序 —— 判分可以把 "8……2" 和 "8余2" 判成同一个答案，
  /// 但那两道题在卷面上是两道题，去重不该把它们合并。
  static String stemKey(String stem) {
    const full = {
      '０': '0', '１': '1', '２': '2', '３': '3', '４': '4',
      '５': '5', '６': '6', '７': '7', '８': '8', '９': '9',
      '×': '*', '÷': '/', '＋': '+', '－': '-', '−': '-',
      '＝': '=', '？': '?', '（': '(', '）': ')',
    };
    var t = stem.trim().toLowerCase();
    full.forEach((k, v) => t = t.replaceAll(k, v));
    return t.replaceAll(RegExp(r'\s+'), '');
  }

  /// 由题干推出稳定 id。
  ///
  /// 不用 `String.hashCode`：它只保证同一次运行内稳定，
  /// 跨 Dart 版本/平台可能变 —— id 变了，题库就会在升级后重复入账。
  static String idFor(String stem) => 'dv-${_fnv1a(stemKey(stem)).toRadixString(36)}';

  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  Future<void> load() async {
    _entries.clear();
    if (!await file.exists()) return;
    try {
      final txt = await file.readAsString();
      if (txt.trim().isEmpty) return;
      final m = jsonDecode(txt);
      final list = (m['entries'] as List?) ?? const [];
      for (final e in list) {
        final r = BankEntry.fromMap((e as Map).cast<String, Object?>());
        if (r.id.isEmpty || r.stem.isEmpty) continue;
        _entries[r.id] = r;
      }
    } catch (_) {
      // 坏了就挪走再用空库继续：题库丢了不致命，App 起不来才致命
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
      'entries': _entries.values.map((e) => e.toMap()).toList(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// 入账一批衍生题，返回**真正新增**的条数（重复的会被挡掉）。
  Future<int> addAll(List<BankEntry> items) async {
    final before = _entries.length;
    for (final e in items) {
      if (e.stem.isEmpty || e.answer.isEmpty) continue;
      _entries.putIfAbsent(e.id, () => e);
    }
    final added = _entries.length - before;
    if (added > 0) await save();
    return added;
  }

  List<BankEntry> get all => _entries.values.toList()
    ..sort((a, b) {
      // 没过关的排前面，其中"一次没练过"的最靠前 —— 它才是待办
      final c = (a.passed ? 1 : 0).compareTo(b.passed ? 1 : 0);
      if (c != 0) return c;
      final d = (a.attempts == 0 ? 0 : 1).compareTo(b.attempts == 0 ? 0 : 1);
      if (d != 0) return d;
      return b.createdAt.compareTo(a.createdAt);
    });

  int get count => _entries.length;

  int get pendingCount => _entries.values.where((e) => !e.passed).length;

  /// 覆盖了多少道错题（组数）
  int get sourceCount =>
      _entries.values.map((e) => e.sourceQuestionId).toSet().length;

  List<BankEntry> bySource(String sourceQuestionId) =>
      all.where((e) => e.sourceQuestionId == sourceQuestionId).toList();

  /// 未过关的题（"练未过关的"按钮用）。
  List<BankEntry> get pending => all.where((e) => !e.passed).toList();

  /// 按来源分组，组的顺序跟着 [all] 的排序走（有未过关题的组在前）。
  List<BankGroup> get groups {
    final out = <BankGroup>[];
    final seen = <String>{};
    for (final e in all) {
      if (!seen.add(e.sourceQuestionId)) continue;
      final list = bySource(e.sourceQuestionId);
      out.add(BankGroup(
        sourceQuestionId: e.sourceQuestionId,
        sourceStem: e.sourceStem,
        entries: list,
      ));
    }
    return out;
  }

  BankEntry? get(String id) => _entries[id];

  /// 记一次练习：连对 [BankEntry.passStreak] 次过关；答错清零连续数。
  Future<BankEntry?> record(String id, {required bool correct}) async {
    final prev = _entries[id];
    if (prev == null) return null;
    final streak = correct ? prev.streak + 1 : 0;
    final next = prev.copyWith(
      attempts: prev.attempts + 1,
      wrongCount: prev.wrongCount + (correct ? 0 : 1),
      streak: streak,
      // 过关只升不降：连对两次已经证明会了，后来手滑一次不该收回勋章
      passed: prev.passed || streak >= BankEntry.passStreak,
    );
    _entries[id] = next;
    await save();
    return next;
  }

  void delete(String id) => _entries.remove(id);

  Future<void> clear() async {
    _entries.clear();
    await save();
  }

  /// 删掉某道来源错题衍生的全部题目（错题本删一条时连带清理）。
  Future<int> removeBySource(String sourceQuestionId) async {
    final keys = _entries.values
        .where((e) => e.sourceQuestionId == sourceQuestionId)
        .map((e) => e.id)
        .toList();
    for (final k in keys) {
      _entries.remove(k);
    }
    if (keys.isNotEmpty) await save();
    return keys.length;
  }
}
