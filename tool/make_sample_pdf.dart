/// 生成一份样例试卷 PDF，用于验证「几何引擎 → 竖式排版 → PDF 导出」整条链路。
///
/// 用法：
///   dart tool/make_sample_pdf.dart [输出路径]
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;
import 'package:math_coach/export/paper.dart';
import 'package:math_coach/export/paper_pdf.dart';
import 'package:math_coach/geometry/dsl/figure.dart';
import 'package:math_coach/geometry/solver/solver.dart';
import 'package:math_coach/knowledge/kp_index.dart';
import 'package:math_coach/typeset/vertical.dart';
import 'package:math_coach/variant/generator.dart';

Future<pw.Font> _loadFont(String path) async {
  final f = File(path);
  if (!f.existsSync()) {
    stderr.writeln('字体不存在: $path');
    exit(2);
  }
  final bytes = await f.readAsBytes();
  return pw.Font.ttf(bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes));
}

void main(List<String> args) async {
  final outPath = args.isNotEmpty ? args[0] : 'build/样例练习卷.pdf';

  const fontPath = r'C:\Windows\Fonts\simhei.ttf';
  final f = File(fontPath);
  if (!f.existsSync()) {
    stderr.writeln('字体不存在: $fontPath');
    exit(2);
  }
  final bytes0 = await f.readAsBytes();
  final fontData = bytes0.buffer.asByteData(bytes0.offsetInBytes, bytes0.lengthInBytes);
  // 黑体本身够醒目；真项目可换成常规体 + 粗体分开
  final fontBoldData = fontData;

  final idx = KnowledgeIndex();
  String kpLabel(String? name, int grade) {
    if (name == null) return '';
    final r = idx.match(knowledgePoint: name, grade: grade);
    return r.point?.path ?? '';
  }

  // ── 1) 图形题：答案全部由本地算出来 ──────────────────────
  final circle = FigureSolver.solve(
      FigureSpec(type: FigureType.circle, params: {'r': 3}, grade: 6));
  final trapezoid = FigureSolver.solve(FigureSpec(
      type: FigureType.trapezoid, params: {'top': 4, 'bottom': 8, 'height': 5}, grade: 5));
  final lattice = FigureSolver.solve(FigureSpec(
      type: FigureType.latticePolygon, params: {'seed': 7, 'width': 5, 'height': 4}, shade: true, grade: 5));
  final composite = FigureSolver.solve(FigureSpec(
      type: FigureType.compositeRectSemicircle, params: {'w': 6, 'h': 4}, grade: 5));
  final cubeNet = FigureSolver.solve(FigureSpec(type: FigureType.cubeNet, grade: 5));

  final items = <PaperItem>[
    PaperItem(
      id: 'q1',
      stem: '一个圆的半径是 3 厘米，它的面积是多少？（π 取 3.14）',
      figure: FigureSpec(type: FigureType.circle, params: {'r': 3}, grade: 6),
      answer: '${circle.facts['area']?.display ?? ''}（≈ ${(circle.facts['area']!.approx).toStringAsFixed(2)} 平方厘米）',
      knowledgeLabel: kpLabel('圆的面积', 6),
      difficulty: 3,
      importance: 2,
    ),
    PaperItem(
      id: 'q2',
      stem: '一个梯形，上底 4 厘米，下底 8 厘米，高 5 厘米，面积是多少？',
      figure: FigureSpec(
          type: FigureType.trapezoid, params: {'top': 4, 'bottom': 8, 'height': 5}, grade: 5),
      answer: trapezoid.facts['area']?.display ?? '',
      knowledgeLabel: kpLabel('梯形面积', 5),
      difficulty: 2,
      importance: 1,
    ),
    PaperItem(
      id: 'q3',
      stem: '下面这个图形画在边长 1 厘米的方格纸上，它的面积是多少平方厘米？',
      figure: FigureSpec(
          type: FigureType.latticePolygon, params: {'seed': 7, 'width': 5, 'height': 4}, shade: true, grade: 5),
      answer: lattice.facts['area']?.display ?? '',
      knowledgeLabel: kpLabel('组合图形面积', 5),
      difficulty: 4,
      importance: 3,
    ),
    PaperItem(
      id: 'q4',
      stem: '求下面组合图形的面积（长方形上接一个半圆，π 取 3.14）。',
      figure: FigureSpec(
          type: FigureType.compositeRectSemicircle, params: {'w': 6, 'h': 4}, grade: 5),
      answer: '${composite.facts['area']?.display ?? ''}（≈ ${composite.facts['area']!.approx.toStringAsFixed(2)} 平方厘米）',
      knowledgeLabel: kpLabel('组合图形面积', 5),
      difficulty: 4,
      importance: 2,
    ),
    PaperItem(
      id: 'q5',
      stem: '下面哪个图形可以折成正方体？（先判断，再说明理由）',
      figure: FigureSpec(type: FigureType.cubeNet, grade: 5),
      answer: cubeNet.facts['foldable']?.approx == 1 ? '可以折成正方体' : '不能折成正方体',
      knowledgeLabel: kpLabel('表面积', 5),
      difficulty: 3,
      importance: 1,
    ),

    // ── 2) 竖式题 ────────────────────────────────────────
    PaperItem(
      id: 'q6',
      stem: '用竖式计算：16 + 27 =',
      vertical: VerticalTypeset.add(16, 27),
      answer: '43',
      knowledgeLabel: kpLabel('不进位加', 1),
      difficulty: 1,
      importance: 0,
    ),
    PaperItem(
      id: 'q7',
      stem: '用竖式计算：23 × 14 =',
      vertical: VerticalTypeset.mul(23, 14),
      answer: '322',
      knowledgeLabel: kpLabel('笔算', 3),
      difficulty: 2,
      importance: 1,
    ),
    PaperItem(
      id: 'q8',
      stem: '用竖式计算：47 ÷ 5 =',
      longDivision: VerticalTypeset.div(47, 5),
      answer: '9 …… 2',
      knowledgeLabel: kpLabel('余数比除数小', 2),
      difficulty: 2,
      importance: 2,
    ),
  ];

  // ── 3) 变体题：数字本地随机、答案本地算、过正确性闸门 ──────
  final gen = VariantGenerator(seed: 20261010);
  final variants = gen.generateMany(VariantKind.mul2x1, 3);
  for (var i = 0; i < variants.length; i++) {
    final v = variants[i];
    items.add(PaperItem(
      id: 'v$i',
      stem: v.stem,
      answer: '${v.answer}${v.answerUnit.isEmpty ? '' : ' ${v.answerUnit}'}',
      knowledgeLabel: kpLabel('笔算（含进位）', 3),
      difficulty: 2,
      importance: 3,
    ));
  }

  final paper = Paper(
    title: '六年级错题练习卷（样例）',
    items: items,
    config: const PaperConfig(
      title: '六年级错题练习卷（样例）',
      itemsPerPage: 3,
      answerSpace: 66,
      answerPlacement: AnswerPlacement.end,
      showKnowledge: true,
    ),
    createdAt: DateTime.now(),
  );

  final exporter = PaperPdfExporter(fontData: fontData, fontBoldData: fontBoldData);
  final bytes = await exporter.export(paper);

  final out = File(outPath);
  await out.parent.create(recursive: true);
  await out.writeAsBytes(bytes);

  stdout.writeln('PDF 已生成: ${out.absolute.path}');
  stdout.writeln('题目数: ${paper.count}   大小: ${(bytes.lengthInBytes / 1024 / 1024).toStringAsFixed(2)} MB');

  // 顺带把每题的"本地算出的答案"打出来供核对
  stdout.writeln('');
  stdout.writeln('── 本地算出的答案（模型不参与给数）──');
  for (var i = 0; i < Paper.sortForPrint(paper.items).length; i++) {
    final it = Paper.sortForPrint(paper.items)[i];
    stdout.writeln('${i + 1}. ${it.stem}');
    stdout.writeln('   答案：${it.answer}');
  }
}
