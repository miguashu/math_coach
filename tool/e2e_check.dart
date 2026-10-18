/// 端到端验收脚本：直接进进程内的 API 层，跑一遍完整流程
/// （出卷 → 判分 → 归档 → 复习队列 → 导出 PDF），
/// 不依赖浏览器，也不需要网络。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:math_coach/export/paper.dart';
import 'package:math_coach/export/paper_pdf.dart';
import 'package:math_coach/knowledge/kp_index.dart';
import 'package:math_coach/quiz/generator.dart';
import 'package:math_coach/review/fsrs.dart';
import 'package:math_coach/store/repository.dart';

int failures = 0;

void check(String why, bool ok) {
  if (!ok) failures++;
  stdout.writeln('  ${ok ? '✓' : '✗'} $why');
}

Future<void> main() async {
  final index = KnowledgeIndex();
  final tmpDir = await Directory.systemTemp.createTemp('mathcoach_e2e');
  final repo = WrongBookRepository(file: File('${tmpDir.path}/wrongbook.json'));
  await repo.load();

  stdout.writeln('═══ 1) 出卷：答案不下发 ═══');
  final gen = QuizGenerator(seed: 42, index: index);
  final paper = gen.generateMany(grade: 6, count: 6);
  check('生成 6 题', paper.length == 6);
  check('每题都有讲解步骤', paper.every((q) => q.solutionSteps.isNotEmpty));
  check('每题都有非空答案', paper.every((q) => q.answer.display.trim().isNotEmpty));
  final withFigure = paper.where((q) => q.figureSvg != null).length;
  final withVert = paper.where((q) => q.verticalSvg != null).length;
  stdout.writeln('     （其中配图题 $withFigure 道、竖式题 $withVert 道）');

  stdout.writeln('');
  stdout.writeln('═══ 2) 判分 + 归档 ═══');
  // 前 3 道答对，后 3 道故意答错
  for (var i = 0; i < paper.length; i++) {
    final q = paper[i];
    final correct = i < 3;
    final ans = correct ? q.answer.display : '错答案';
    final ok = q.answer.check(ans);
    check('第 ${i + 1} 题判分正确（${correct ? '该判对' : '该判错'}）', ok == correct);
    await repo.recordAttempt(
      q,
      correct: ok,
      rating: ok ? Rating.good : Rating.again,
      figureSpec: q.figureSpec,
      verticalKind: q.verticalKind,
      verticalArgs: q.verticalArgs,
    );
  }
  check('错题本有 6 条', repo.count == 6);
  final wrong3 = repo.all.where((r) => r.wrongCount > 0).length;
  check('其中 3 条记了错误', wrong3 == 3);
  final important = repo.all.where((r) => r.importance >= 1).length;
  check('答错的题重要度 ≥ 1', important == 3);

  stdout.writeln('');
  stdout.writeln('═══ 3) 重要度衰减（不是单调累加）═══');
  final target = repo.all.firstWhere((r) => r.importance >= 1);
  final before = target.importance;
  for (var i = 0; i < 3; i++) {
    final q = paper.firstWhere((e) => e.id == target.id);
    await repo.recordAttempt(q,
        correct: true,
        rating: Rating.good,
        figureSpec: q.figureSpec,
        verticalKind: q.verticalKind,
        verticalArgs: q.verticalArgs);
  }
  final after = repo.get(target.id)!.importance;
  check('连续答对 3 次后重要度从 $before 降到 $after', after < before);
  check('答对 3 次后重要度归零', after == 0);

  stdout.writeln('');
  stdout.writeln('═══ 4) FSRS 间隔调度 ═══');
  final dueCount = repo.dueQueue(DateTime.now().add(const Duration(days: 200))).length;
  check('很久以后基本都到期', dueCount >= 5);
  final todayDue = repo.dueQueue(DateTime.now()).length;
  check('今天就有题要做（$todayDue 条）', todayDue >= 1);
  final r0 = repo.all.firstWhere((r) => r.wrongCount > 0);
  check('答错的题 1 小时内回到队列（不是排到明天）',
      r0.isDue(DateTime.now().add(const Duration(hours: 1))));
  final rOk = repo.all.firstWhere((r) => r.wrongCount == 0 && r.rightCount > 0);
  check('答对的题排到了更远的将来', !rOk.isDue(DateTime.now().add(const Duration(hours: 1))));

  stdout.writeln('');
  stdout.writeln('═══ 4.5) 低年级：竖式题能出也能导出 ═══');
  final gen3 = QuizGenerator(seed: 7, index: index);
  final paper3 = gen3.generateMany(grade: 3, count: 8);
  final vert3 = paper3.where((q) => q.verticalSvg != null).length;
  check('3 年级出到 $vert3 道竖式题', vert3 >= 1);
  check('竖式题都带重放参数',
      paper3.where((q) => q.verticalSvg != null).every((q) => q.verticalKind != null));

  stdout.writeln('');
  stdout.writeln('═══ 5) 持久化：关掉再打开不丢 ═══');
  final repo2 = WrongBookRepository(file: File('${tmpDir.path}/wrongbook.json'));
  await repo2.load();
  check('重新加载后记录数一致（${repo2.count}）', repo2.count == repo.count);
  final sameId = repo2.get(repo.all.first.id);
  check('记录内容可还原', sameId != null && sameId.stem == repo.all.first.stem);
  check('FSRS due 被还原', sameId!.fsrs.due.millisecondsSinceEpoch ==
      repo.all.first.fsrs.due.millisecondsSinceEpoch);

  stdout.writeln('');
  stdout.writeln('═══ 6) 导出 PDF（含图与竖式）═══');
  final fontFile = File(r'C:\Windows\Fonts\simhei.ttf');
  if (!await fontFile.exists()) {
    stdout.writeln('  ! 找不到中文字体，跳过');
    failures++;
  } else {
    final bytes = await fontFile.readAsBytes();
    final fd = ByteData.sublistView(bytes);
    final items = <PaperItem>[
      for (final r in repo2.all)
        PaperItem(
          id: r.id,
          stem: r.stem,
          figure: VerticalReplay.figure(r.figureSpec),
          vertical: VerticalReplay.layout(r.verticalKind ?? '', r.verticalArgs),
          longDivision: r.verticalKind == 'div'
              ? VerticalReplay.longDivision(r.verticalArgs)
              : null,
          answer: r.answer,
          knowledgeLabel: r.kpPath,
          difficulty: r.difficulty,
          importance: r.importance,
        ),
    ];
    check('从错题本还原出 ${items.length} 道 PaperItem', items.length == repo2.count);
    final hasFig = items.where((e) => e.figure != null).length;
    check('其中有图/竖式可重放的题目 $hasFig 道', hasFig >= 1);

    final p = Paper(
      title: '端到端验收卷',
      items: items,
      config: const PaperConfig(
        title: '端到端验收卷',
        itemsPerPage: 4,
        answerSpace: 70,
        answerPlacement: AnswerPlacement.end,
        showKnowledge: true,
      ),
      createdAt: DateTime.now(),
    );
    final exporter = PaperPdfExporter(fontData: fd, fontBoldData: fd);
    final pdf = await exporter.export(p);
    final out = File('build/e2e.pdf');
    await out.create(recursive: true);
    await out.writeAsBytes(pdf);
    check('生成 PDF：${out.path}（${(pdf.lengthInBytes / 1024).toStringAsFixed(1)} KB）',
        pdf.lengthInBytes > 3000);
  }

  await tmpDir.delete(recursive: true);

  stdout.writeln('');
  stdout.writeln(failures == 0 ? '✅ 端到端验收通过' : '❌ 有 $failures 项失败');
  if (failures > 0) exit(1);
}
