import 'dart:io';

/// 出题器自检：跑一遍所有年级、所有题型，检查：
///   - 每道题都能生成（不 nil、不抛异常）
///   - 答案判分能判对标准答案 + 常见变体写法
import 'package:math_coach/quiz/generator.dart';
import 'package:math_coach/quiz/question.dart';

void main() {
  var total = 0;
  var failures = 0;

  for (var grade = 1; grade <= 6; grade++) {
    final gen = QuizGenerator(seed: 20261011 + grade);
    final qs = <QuizQuestion>[];
    try {
      qs.addAll(gen.generateMany(grade: grade, count: 40));
    } catch (e) {
      stdout.writeln('✗ G$grade 生成异常: $e');
      failures++;
      continue;
    }
    stdout.writeln('── $grade 年级：生成 ${qs.length} 题');
    for (final q in qs) {
      total++;
      final selfOk = q.answer.check(q.answer.display);
      if (!selfOk) {
        failures++;
        stdout.writeln('   ✗ 自判失败 [${q.kind}] ${q.stem} → 答案 ${q.answer.display}');
      }
      final problems = <String>[];
      if (q.stem.trim().isEmpty) problems.add('题干为空');
      if (q.solutionSteps.isEmpty) problems.add('没有讲解步骤');
      if (q.answer.display.trim().isEmpty) problems.add('答案为空');
      if (problems.isNotEmpty) {
        failures++;
        stdout.writeln('   ✗ [${q.kind}] ${problems.join('、')}');
      }
    }
  }

  // 判分的宽容度：同一答案的不同写法都要判对
  stdout.writeln('');
  stdout.writeln('── 判分宽容度 ──');
  void expect(String why, bool got) {
    if (!got) failures++;
    stdout.writeln('   ${got ? '✓' : '✗'} $why');
  }

  final ans = QuizAnswer(display: '9 …… 2', value: 9, tolerance: 0.0);
  expect('"9……2" 判为对', ans.check('9……2'));
  expect('"9 …… 2" 判为对', ans.check('9 …… 2'));
  expect('"9...2" 判为对', ans.check('9...2'));
  expect('"9余2" 判为对', ans.check('9余2'));
  expect('"8……2" 判为错', !ans.check('8……2'));

  final num1 = QuizAnswer(display: '43', value: 43);
  expect('"43" 判为对', num1.check('43'));
  expect('"43 " 带空格判为对', num1.check(' 43 '));
  expect('全角"４３" 判为对', num1.check('４３'));
  expect('"42" 判为错', !num1.check('42'));

  final dec = QuizAnswer(display: '28.26', value: 28.26, tolerance: 0.06);
  expect('"28.26" 判为对', dec.check('28.26'));
  expect('"28.26 平方厘米" 带单位判为对', dec.check('28.26 平方厘米'));
  // 教材有的要求保留两位、有的一位，孩子写一位小数时不能判错
  expect('"28.3"（保留一位）判为对', dec.check('28.3'));
  expect('"29"（差太多）判为错', !dec.check('29'));

  final frac = QuizAnswer(display: '15', value: 15);
  expect('"15.00" 判为对', frac.check('15.00'));

  stdout.writeln('');
  stdout.writeln('共 $total 题，失败 $failures 项');
  stdout.writeln(failures == 0 ? '✅ 出题器自检通过' : '❌ 有问题，见上');
}
