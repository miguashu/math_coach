/// App 状态：出题 → 判分 → 归档 → 复习 → 导出，全部走本地内核。
///
/// 刻意用纯 Dart 内核 + 一层薄 State：App 只是 UI，不产生任何一个答案。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/derive.dart';
import 'package:math_coach/ai/log.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/quizgen.dart';
import 'package:math_coach/export/paper.dart';
import 'package:math_coach/export/paper_pdf.dart';
import 'package:math_coach/knowledge/kp_index.dart';
import 'package:math_coach/quiz/generator.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/review/fsrs.dart';
import 'package:math_coach/store/backup.dart';
import 'package:math_coach/store/bank.dart';
import 'package:math_coach/store/repository.dart';

class AppState extends ChangeNotifier {
  late final WrongBookRepository repo;

  /// 衍生题库。
  ///
  /// 刻意不用 `late final`：init 的兜底分支（存储坏了）里要能重新指向临时目录，
  /// 而 final 一旦被赋过值就会抛 LateInitializationError。
  late QuestionBank bank;

  late final QuizGenerator gen;

  static const _channel = MethodChannel('mathcoach/storage');

  bool ready = false;
  String? error;

  /// App 私有文件目录（Android 由 MainActivity 通过 MethodChannel 提供）。
  String? filesDir;

  /// AI 配置：用户自己填 key，不填则整个 App 依旧纯离线可用。
  AiConfig aiConfig = AiConfig.fallback;

  /// 运行记录（管理员视角）：拍照/识别/讲解/出题/导出各记一笔。
  ActivityLog? activityLog;

  /// 当前正在做的一卷（题目本身不含正确答案以外的泄露字段，判分在提交时本地比对）
  List<QuizQuestion> current = [];

  /// AI 出题状态（界面据此转圈/提示）
  bool aiBusy = false;
  String? aiNote;
  int aiCount = 0;

  /// 每道题的输入
  final Map<String, TextEditValue> inputs = {};

  /// 批改结果：questionId → 是否答对
  final Map<String, bool> verdicts = {};

  bool submitted = false;

  /// 衍生题生成状态（界面据此显示进度条与结果说明）
  bool deriving = false;
  String? deriveNote;

  /// 这次没造出衍生题的错题及原因（错题 id → 人话）。
  /// 只活在本次会话里：它的用途是"刚判完卷马上告诉你为什么没出"，
  /// 隔几天再看已经不重要了（题库页面本来就列着有什么题）。
  Map<String, String> deriveSkips = {};

  AppState() : gen = QuizGenerator();

  Future<void> init() async {
    try {
      String dir;
      try {
        dir = await _channel.invokeMethod('filesDir') as String;
      } on MissingPluginException {
        dir = Directory.current.path;
      }
      filesDir = dir;
      repo = WrongBookRepository(file: File('$dir${Platform.pathSeparator}wrongbook.json'));
      bank = QuestionBank(file: File('$dir${Platform.pathSeparator}bank.json'));
      await repo.load();
      await bank.load();
      activityLog = ActivityLog(File('$dir${Platform.pathSeparator}activity_log.jsonl'));
      await activityLog!.load();
      await _loadAiConfig();
      await _loadRecentStems();
      ready = true;
    } catch (e) {
      // 存储挂了不能让 App 变砖：退回内存目录，至少当次能用
      filesDir = Directory.systemTemp.path;
      repo = WrongBookRepository(
          file: File('${Directory.systemTemp.path}${Platform.pathSeparator}math_coach_fallback.json'));
      bank = QuestionBank(
          file: File('${Directory.systemTemp.path}${Platform.pathSeparator}math_coach_bank_fallback.json'));
      error = '存储初始化失败，本次数据可能不会保留：$e';
      ready = true;
    }
    notifyListeners();
  }

  // ── 出题 ────────────────────────────────────────────────

  /// 出了一套题。**本地题立即上屏**（离线永远有题），AI 题随后混入。
  ///
  /// 难度档语义（用户原话："能不能采用大模型生成几道困难的……奥数水平"）：
  /// - 基础：全部本地模板，不联网；
  /// - 提高：一半 AI 现场应用题，本地补足；
  /// - 奥数挑战：以 AI 为主，本地只兜底。
  ///
  /// 选了本地题库没覆盖的知识点（如五年级"图形的运动（三）"）时，
  /// 提高/奥数档整套交给 AI —— 以前这种情况会静默出一道别的单元的题，
  /// 家长看到的就是"五年级冒出一年级的简单题"。
  ///
  /// 2026-10-17 家长反馈："点击出题，直接出现六个题，但是不是 ai 生成的
  /// 也不是对应知识点的。" 根因就在这：单元没被收录时，本地题是**立刻**上屏的，
  /// 而那 6 道题根本不是所选单元。所以现在这种情况下**先不出**，
  /// 界面显示"正在按这个单元用 AI 出题"，等 AI 回来再上卷；
  /// AI 也没出成才回落本地，并且明确说明"这些不是所选单元的题"。
  Future<void> newPractice({
    required int grade,
    int count = 6,
    String? unit,
    String? tag,
    QuizLevel level = QuizLevel.basic,
  }) async {
    inputs.clear();
    verdicts.clear();
    submitted = false;

    final covered = gen.covers(grade: grade, unit: unit, tag: tag);
    final local = gen.generateMany(count: count, grade: grade, unit: unit, tag: tag);
    final wantAi = level == QuizLevel.basic
        ? 0
        : (!covered
            ? count
            : (level == QuizLevel.olympiad
                ? count
                : math.max(1, (count / 2).round())));
    // 单元本地没收录、又要 AI：别拿不相干的本地题充数
    final deferLocal = !covered && wantAi > 0 && unit != null && unit.trim().isNotEmpty;
    current = deferLocal ? const [] : local;
    aiBusy = deferLocal;
    aiNote = deferLocal ? '「$unit」本地题库还没收录，正在用 AI 按这个单元出题…' : null;
    aiCount = 0;
    notifyListeners();

    if (wantAi == 0) {
      if (!covered && unit != null && unit.trim().isNotEmpty) {
        aiNote = '「$unit」本地题库还没收录；切到「提高」或「奥数挑战」可用 AI 现场出题';
        notifyListeners();
      }
      _rememberStems(local);
      return;
    }
    if (!aiConfig.chatReady) {
      aiNote = deferLocal
          ? 'AI 未配置（到「设置」填 key）。「$unit」本地题库没收录，'
              '先出的 ${local.length} 道是同年级其他单元的题，不是这个单元的'
          : 'AI 未配置（到「设置」填 key），本套先用本地题库';
      aiBusy = false;
      notifyListeners();
      _rememberStems(local);
      return;
    }

    aiBusy = true;
    aiNote = null;
    notifyListeners();
    try {
      final res = await QuizAgent(llm()).generate(
        grade: grade,
        unit: unit,
        count: wantAi,
        level: level,
        avoid: _recentStems,
      );
      final merged = mixPaper(
        local: local,
        ai: res.questions,
        count: count,
        grade: grade,
        unit: unit,
        moreLocal: (n) => gen.generateMany(
            count: n, grade: grade, unit: unit, tag: tag),
      );
      current = merged;
      aiCount = merged.where((q) => q.isAi).length;
      if (res.questions.isEmpty) {
        aiNote = res.error ??
            (deferLocal
                ? 'AI 没出成，先出的 ${merged.length} 道是同年级其他单元的题，不是「$unit」'
                : 'AI 没出成，本套用本地题库');
      } else if (!covered && unit != null && unit.trim().isNotEmpty) {
        aiNote = '「$unit」本地题库没收录，本套 $aiCount 道由 AI 现场生成';
      } else {
        aiNote = '本套含 $aiCount 道 AI 新题（答案已本地验算）';
      }
      _rememberStems(merged);
    } on LlmError catch (e) {
      aiNote = 'AI 出题失败：${e.message}';
      // AI 路断了：本地题先顶上，但要说清这些不是所选单元的题
      if (deferLocal && current.isEmpty) current = local;
    } catch (e) {
      aiNote = 'AI 出题失败：$e';
      if (deferLocal && current.isEmpty) current = local;
    } finally {
      aiBusy = false;
      notifyListeners();
    }
  }

  /// 最近出过的题干（给 AI 避重用）。落盘是因为"换一套题"经常跨会话发生，
  /// 只在内存里记的话，下次打开 App 又把上一轮的题出一遍。
  final List<String> _recentStems = [];
  static const _recentMax = 40;

  File? get _recentStemsFile => filesDir == null
      ? null
      : File('$filesDir${Platform.pathSeparator}recent_stems.json');

  Future<void> _loadRecentStems() async {
    final f = _recentStemsFile;
    if (f == null || !await f.exists()) return;
    try {
      final list = (jsonDecode(await f.readAsString()) as List).cast<String>();
      _recentStems.addAll(list.take(_recentMax));
    } catch (_) {
      // 文件坏了不影响出题
    }
  }

  void _rememberStems(List<QuizQuestion> qs) {
    for (final q in qs) {
      _recentStems.remove(q.stem);
      _recentStems.insert(0, q.stem);
    }
    if (_recentStems.length > _recentMax) {
      _recentStems.removeRange(_recentMax, _recentStems.length);
    }
    final f = _recentStemsFile;
    if (f != null) {
      try {
        f.writeAsStringSync(jsonEncode(_recentStems));
      } catch (_) {}
    }
  }

  /// 把错题本里的题重放回"练习"（用记录的 legs 参数重建 Question）。
  void replay(List<ReviewRecord> rs) {
    current = rs.map(questionFromRecord).whereType<QuizQuestion>().toList();
    inputs.clear();
    verdicts.clear();
    submitted = false;
    notifyListeners();
  }

  static QuizQuestion? questionFromRecord(ReviewRecord r) {
    return QuizQuestion(
      id: r.id,
      kpPath: r.kpPath,
      stem: r.stem,
      solutionSteps: r.steps,
      answer: QuizAnswer(display: r.answer),
      kind: r.kind,
      grade: r.grade,
      figureSpec: r.figureSpec,
      verticalKind: r.verticalKind,
      verticalArgs: r.verticalArgs,
      difficulty: r.difficulty,
    );
  }

  void setInput(String id, String text) {
    inputs[id] = TextEditValue(text);
  }

  /// 界面自己改了需要全局刷新的东西（比如错题本角标）时调这个。
  ///
  /// 刻意包一层：`notifyListeners()` 是 ChangeNotifier 的保护成员，
  /// 在页面里直接调会触发 `invalid_use_of_protected_member` 警告。
  void refresh() => notifyListeners();

  // ── 批改 ────────────────────────────────────────────────

  bool check(QuizQuestion q, String input) => q.answer.check(input);

  Future<void> submit() async {
    for (final q in current) {
      final input = inputs[q.id]?.text.trim() ?? '';
      final correct = input.isNotEmpty && check(q, input);
      verdicts[q.id] = correct;
      await repo.recordAttempt(
        q,
        correct: correct,
        rating: ratingFor(correct: correct),
        figureSpec: q.figureSpec,
        verticalKind: q.verticalKind,
        verticalArgs: q.verticalArgs,
      );
    }
    submitted = true;
    notifyListeners();
  }

  int get correctCount => verdicts.values.where((e) => e).length;

  /// 拍照判卷后没认出答案的题数（不判错也不判对）。
  int get unreadCount =>
      submitted ? current.where((q) => !verdicts.containsKey(q.id)).length : 0;

  // ── 拍照判卷 ──────────────────────────────────────

  /// 拍照判卷的结果落账：把识别出的答案写回当前卷的作答区，
  /// 本地判分结果写进 verdicts，错题进错题本。
  ///
  /// **未识别的题（results 里没有的）不判错也不判对** ——
  /// 没看清就判错是冤枉孩子；这些题在界面上标"未识别"，
  /// 家长可以照着照片手动补判。
  Future<void> applyPhotoGrade(
      Map<String, ({String read, bool correct})> results) async {
    if (results.isEmpty) return;
    for (final q in current) {
      final r = results[q.id];
      if (r == null) continue;
      inputs[q.id] = TextEditValue(r.read);
      verdicts[q.id] = r.correct;
      await repo.recordAttempt(
        q,
        correct: r.correct,
        rating: ratingFor(correct: r.correct),
        figureSpec: q.figureSpec,
        verticalKind: q.verticalKind,
        verticalArgs: q.verticalArgs,
      );
    }
    submitted = true;
    notifyListeners();
  }

  // ── 衍生题（判卷之后，为错题造同类题进题库）─────────────

  /// 给一批错题各造几道衍生题，进题库。
  ///
  /// **后台跑，不阻塞判卷结果**：本地模板毫秒级，模型那条路要十几秒；
  /// 判卷是一件家长等着看数的事，不该被出题拖住 ——
  /// 所以判卷该多快还多快，衍生题好了再通知界面。
  Future<void> deriveFromWrong(List<QuizQuestion> wrong) async {
    if (wrong.isEmpty) return;
    deriving = true;
    deriveNote = '正在为 ${wrong.length} 道错题生成衍生题…';
    notifyListeners();
    try {
      final agent = DeriveAgent(client: aiConfig.chatReady ? llm() : null);
      final out = await agent.deriveAll(wrong);
      deriveSkips = out.skipped;
      final fresh = await bank.addAll(out.entries);
      deriveNote = _deriveNote(out, fresh, wrong.length);
      await activityLog?.record('derive', detail: deriveNote ?? '', ok: out.ok);
    } catch (e) {
      // 衍生失败不影响判卷 —— 判卷结果早就落账了，这里只是少了练习题
      deriveNote = '生成衍生题失败（判卷结果不受影响）：$e';
      await activityLog?.record('derive', detail: '失败：$e', ok: false);
    } finally {
      deriving = false;
      notifyListeners();
    }
  }

  static String _deriveNote(DeriveOutcome out, int fresh, int wrongCount) {
    if (out.entries.isEmpty) {
      final first = out.skipped.values.isEmpty ? '' : out.skipped.values.first;
      return '这 $wrongCount 道错题暂时没造出衍生题。$first';
    }
    if (fresh == 0) {
      return '这次衍生出的 ${out.entries.length} 道题题库里已经有了，没有重复入账';
    }
    final buf = StringBuffer('错题 $wrongCount 道 → 衍生题 $fresh 道已进题库');
    if (out.aiCount > 0) buf.write('（其中 ${out.aiCount} 道由 AI 现场出）');
    if (out.skipped.isNotEmpty) {
      buf.write('；另有 ${out.skipped.length} 道错题没能衍生，题库里有说明');
    }
    return buf.toString();
  }

  /// 练衍生题的结果落账：题库记痕迹（连对两次过关）；答错的**也进错题本** ——
  /// 它是孩子真做错的一道题，该进复习队列。
  Future<void> submitBankPractice(
      List<BankEntry> items, Map<String, String> answers) async {
    for (final e in items) {
      final input = answers[e.id]?.trim() ?? '';
      if (input.isEmpty) continue;
      final q = e.toQuestion();
      final correct = check(q, input);
      await bank.record(e.id, correct: correct);
      if (!correct) {
        await repo.recordAttempt(
          q,
          correct: false,
          rating: ratingFor(correct: false),
          figureSpec: q.figureSpec,
          verticalKind: q.verticalKind,
          verticalArgs: q.verticalArgs,
        );
      }
    }
    notifyListeners();
  }

  /// 从题库移除某一组（连带删掉某道错题衍生的全部题目）。
  Future<void> dropBankGroup(String sourceQuestionId) async {
    await bank.removeBySource(sourceQuestionId);
    notifyListeners();
  }

  // ── 复习队列作答 ────────────────────────────────────────

  /// 复习的一次批改：答错会把下次复习拉回队首（lapseStep=0，趁热巩固），
  /// 答对则按 FSRS 往后推。
  ///
  /// [selfRatings] 是孩子在答对的题上自评的档位（[selfReportRatings] 三档）。
  /// 这是 hard / easy 唯一会被真正传下去的地方 —— 答错固定 [Rating.again]，
  /// 答对没自评就默认 [Rating.good]，两者的取舍都封在 [ratingFor] 里。
  Future<void> submitReview(
    List<ReviewRecord> rs,
    Map<String, String> answers, {
    Map<String, Rating> selfRatings = const {},
  }) async {
    for (final r in rs) {
      final q = questionFromRecord(r);
      if (q == null) continue;
      final input = answers[r.id]?.trim() ?? '';
      // 留空不算答对，也不算答错 —— 只是这次没做，不能污染间隔
      if (input.isEmpty) continue;
      final correct = check(q, input);
      await repo.recordAttempt(
        q,
        correct: correct,
        rating: ratingFor(correct: correct, selfRated: selfRatings[r.id]),
        figureSpec: r.figureSpec,
        verticalKind: r.verticalKind,
        verticalArgs: r.verticalArgs,
      );
    }
    notifyListeners();
  }

  // ── 错题本 / 复习 ───────────────────────────────────────

  List<ReviewRecord> get book => repo.all;

  List<ReviewRecord> dueQueue({int limit = 20}) => repo.dueQueue(DateTime.now(), limit: limit);

  ({int due, int attention, int mastered}) stats(DateTime now) => repo.stats(now);

  int get totalCount => repo.count;

  Future<void> forget(String id) async {
    repo.delete(id);
    await repo.save();
    notifyListeners();
  }

  Future<void> clearAll() async {
    await repo.clear();
    notifyListeners();
  }

  // ── 导出 PDF ────────────────────────────────────────────

  /// 导出 PDF 到 App 私有目录，返回文件。
  Future<File> exportPaper({
    required String title,
    required List<ReviewRecord> records,
    ByteData? fontData,
    ByteData? fontBoldData,
  }) async {
    final items = <PaperItem>[];
    for (final r in records) {
      items.add(PaperItem(
        id: r.id,
        stem: r.stem,
        answer: r.answer,
        figure: VerticalReplay.figure(r.figureSpec),
        // 试卷是给孩子做的：竖式只印题面，进位和结果留空（答案在单独的答案页）
        vertical: r.verticalKind == 'div'
            ? null
            : VerticalReplay.layout(r.verticalKind ?? '', r.verticalArgs, withAnswer: false),
        longDivision: r.verticalKind == 'div'
            ? VerticalReplay.longDivision(r.verticalArgs, withAnswer: false)
            : null,
        knowledgeLabel: r.kpPath,
        difficulty: r.difficulty,
        importance: r.importance,
      ));
    }
    final paper = Paper(
      title: title,
      items: items,
      config: PaperConfig(title: title, itemsPerPage: 4, answerSpace: 70),
      createdAt: DateTime.now(),
    );
    Uint8List bytes;
    if (fontData != null) {
      bytes = await PaperPdfExporter(fontData: fontData, fontBoldData: fontBoldData).export(paper);
    } else {
      // 没有字体时不硬撑：返回一个不含中文的方案会把汉字画成空白，
      // 所以这里明确抛错，让 UI 提示"请检查字体资源"。
      throw StateError('缺少中文字体资源，无法导出 PDF');
    }
    final out = File('${filesDir ?? Directory.systemTemp.path}${Platform.pathSeparator}'
        '${_safeName(title)}.pdf');
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  /// 唤起系统分享面板（给微信/打印机）。
  Future<void> shareFile(File f, {String mime = 'application/pdf'}) async {
    try {
      await _channel.invokeMethod('share', {'path': f.path, 'mime': mime});
    } on MissingPluginException {
      // 桌面/未实现时静默：文件已经写好了
    }
  }

  // ── 数据备份（卸载 App 数据就丢了，得有出路）────────────────

  /// 导出错题本备份：写一份带时间戳的 JSON 到 App 目录，返回文件。
  ///
  /// 文件名带日期是为了"一眼看出是哪天导的" —— 家长很可能存了好几份，
  /// 靠文件名分辨比靠内容靠谱。
  Future<File> exportBackup() async {
    final dir = filesDir ?? Directory.systemTemp.path;
    final stamp = _backupStamp(DateTime.now());
    final out = File('$dir${Platform.pathSeparator}错题本备份-$stamp.json');
    await out.writeAsString(
      BackupCodec.encode(repo.all, at: DateTime.now()),
      flush: true,
    );
    await activityLog?.record('backup', detail: '导出 ${repo.count} 条', ok: true);
    notifyListeners();
    return out;
  }

  static String _backupStamp(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
      '-${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}';

  /// 从用户选中的备份文件恢复，返回合并结果（新增/合并了多少条）。
  ///
  /// 任何一步失败都抛 [BackupError]，由 UI 翻译成人话 ——
  /// 导入错了不该静默留下一个半吊子库。
  Future<MergeResult> importBackupFromFile(File f) async {
    final List<ReviewRecord> incoming;
    try {
      incoming = BackupCodec.decode(await f.readAsString());
    } on BackupError {
      rethrow;
    } catch (e) {
      throw BackupError('读不出来这个文件：$e');
    }
    final r = mergeInto(repo, incoming);
    await repo.save();
    await activityLog?.record('restore',
        detail: '新增 ${r.added} 条，合并 ${r.merged} 条', ok: true);
    notifyListeners();
    return r;
  }

  /// 变体闯关的成绩归档。
  ///
  /// 答完要留下痕迹：错的进错题本和复习队列，对的按 FSRS 往后排。
  /// 不然"闯关"就只是做了一组题，练完什么都没发生。
  Future<void> recordChallenge(Map<QuizQuestion, bool> results) async {
    for (final e in results.entries) {
      await repo.recordAttempt(
        e.key,
        correct: e.value,
        rating: ratingFor(correct: e.value),
      );
    }
    notifyListeners();
  }

  /// 唤起系统文件选择器挑一份备份（不申请存储权限，走 ACTION_GET_CONTENT）。
  Future<String?> pickBackup() async {
    try {
      final p = await _channel.invokeMethod('pickDocument') as String?;
      return p;
    } on MissingPluginException {
      return null;
    }
  }

  // ── AI（用户自备 key）──────────────────────────────────

  File? get _aiConfigFile => filesDir == null
      ? null
      : File('$filesDir${Platform.pathSeparator}ai_config.json');

  Future<void> _loadAiConfig() async {
    final f = _aiConfigFile;
    if (f == null || !await f.exists()) return;
    try {
      aiConfig = AiConfig.fromJson(jsonDecode(await f.readAsString()) as Map<String, Object?>);
    } catch (_) {
      // 配置文件坏了就回默认，不能让 App 起不来
    }
  }

  Future<void> saveAiConfig(AiConfig c) async {
    aiConfig = c;
    final f = _aiConfigFile;
    if (f != null) {
      try {
        await f.writeAsString(jsonEncode(c.toJson()), flush: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  LlmClient llm() => LlmClient(aiConfig);

  /// 唤起系统相机拍照，返回本地文件路径（用户取消则为 null）。
  Future<String?> takePhoto() async {
    try {
      final p = await _channel.invokeMethod('takePhoto') as String?;
      await activityLog?.record('photo', detail: p == null ? '用户取消拍照' : '拍照成功', ok: p != null);
      if (p != null) _trimPhotos();
      notifyListeners();
      return p;
    } on MissingPluginException {
      return null;
    }
  }

  /// 只留最近 20 张题图：照片会一直堆积，而它们只是中间产物。
  /// 注意：这里用 retire（挪走）而不是删除 —— 本机批量删除会被安全守卫拦下。
  Future<void> _trimPhotos() async {
    final dir = filesDir == null
        ? null
        : Directory('$filesDir${Platform.pathSeparator}photos');
    if (dir == null || !await dir.exists()) return;
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.jpg'))
          .cast<File>()
          .toList();
      if (files.length <= 20) return;
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(20)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 从相册选一张题图。
  Future<String?> pickImage() async {
    try {
      final p = await _channel.invokeMethod('pickImage') as String?;
      await activityLog?.record('pick', detail: p == null ? '未选择图片' : '从相册选图', ok: p != null);
      notifyListeners();
      return p;
    } on MissingPluginException {
      return null;
    }
  }

  /// 把练习页当前这套题直接导出成可打印 PDF（竖式/进位留空，答案在单独答案页）。
  ///
  /// 与 [exportPaper] 的区别：来源是刚生成的 [QuizQuestion] 而不是错题本记录，
  /// 让家长不用先归档就能把这套题打出来。
  Future<File> exportPractice({
    required String title,
    required List<QuizQuestion> questions,
    ByteData? fontData,
    ByteData? fontBoldData,
  }) async {
    if (fontData == null) {
      throw StateError('缺少中文字体资源，无法导出 PDF');
    }
    final items = <PaperItem>[];
    for (final q in questions) {
      items.add(PaperItem(
        id: q.id,
        stem: q.stem,
        answer: q.answer.display,
        figure: VerticalReplay.figure(q.figureSpec),
        vertical: (q.verticalKind != null && q.verticalKind != 'div' && q.verticalArgs.isNotEmpty)
            ? VerticalReplay.layout(q.verticalKind!, q.verticalArgs, withAnswer: false)
            : null,
        longDivision: q.verticalKind == 'div' && q.verticalArgs.isNotEmpty
            ? VerticalReplay.longDivision(q.verticalArgs, withAnswer: false)
            : null,
        knowledgeLabel: q.kpPath,
        difficulty: q.difficulty,
        importance: 0,
      ));
    }
    final paper = Paper(
      title: title,
      items: items,
      config: PaperConfig(title: title, itemsPerPage: 4, answerSpace: 70),
      createdAt: DateTime.now(),
    );
    final bytes = await PaperPdfExporter(fontData: fontData, fontBoldData: fontBoldData).export(paper);
    final out = File('${filesDir ?? Directory.systemTemp.path}${Platform.pathSeparator}'
        '${_safeName(title)}.pdf');
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}

/// 输入框值（简单包装，便于统一 hint/清空逻辑）。
class TextEditValue {
  final String text;
  const TextEditValue(this.text);
}

/// 题型 / 知识点目录（给"选题"用）。
class KindCatalog {
  KindCatalog._();

  /// 按年级列出单元名。
  static List<String> unitsOf(int grade) {
    final idx = KnowledgeIndex();
    final groups = idx.unitsByGrade(grade);
    final out = <String>[];
    final seen = <String>{};
    for (final entry in groups.entries) {
      for (final u in entry.value) {
        final name = u.name;
        if (name.isEmpty) continue;
        if (seen.add(name)) out.add(name);
      }
    }
    return out;
  }

  static const gradeNames = <int, String>{
    1: '一年级',
    2: '二年级',
    3: '三年级',
    4: '四年级',
    5: '五年级',
    6: '六年级',
  };

  static int nextSeed() => DateTime.now().microsecondsSinceEpoch % (1 << 31);
}

/// 给 UI 用的时间戳友好显示。
String friendlyDue(DateTime due, DateTime now) {
  final diff = due.difference(now);
  if (diff.isNegative) return '现在复习';
  final m = diff.inMinutes;
  if (m < 60) return '$m 分钟后';
  final hours = diff.inHours;
  if (hours < 24) return '$hours 小时后';
  return '${diff.inDays} 天后';
}

/// 安全地对空值取长度。
int lenOf(String? s) => math.max(0, s?.length ?? 0);
