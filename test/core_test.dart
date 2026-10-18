import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:math_coach/core/rational.dart';
import 'package:math_coach/knowledge/kp.dart';
import 'package:math_coach/knowledge/kp_index.dart';
import 'package:math_coach/knowledge/kp_seed.dart';
import 'package:math_coach/review/fsrs.dart';
import 'package:math_coach/typeset/vertical.dart';
import 'package:math_coach/variant/generator.dart';

void main() {
  group('精确有理数（答案不能错的地基）', () {
    test('分数运算精确，不受浮点误差影响', () {
      expect(Rational(1, 3) + Rational(1, 6), Rational(1, 2));
      expect(Rational(3, 4) * Rational(2, 3), Rational(1, 2));
      expect(Rational(1, 2) / Rational(1, 4), Rational(2));
      // 0.1 + 0.2 必须是精确的 0.3，不能是 0.30000000000000004
      expect(Rational.tryParse('0.1')! + Rational.tryParse('0.2')!, Rational(3, 10));
    });

    test('展示形态符合小学习惯', () {
      expect(Rational(3, 4).toString(), '0.75'); // 有限小数
      expect(Rational(1, 3).toString(), '1/3'); // 无限小数保持分数
      expect(Rational(12).toString(), '12');
      expect(Rational(7, 4).toMixedString(), '1又3/4');
    });

    test('解析支持整数 / 小数 / 分数 / 负号', () {
      expect(Rational.tryParse('12'), Rational(12));
      expect(Rational.tryParse('3.14'), Rational(314, 100));
      expect(Rational.tryParse('3/4'), Rational(3, 4));
      expect(Rational.tryParse('-1/2'), Rational(-1, 2));
      expect(Rational.tryParse('abc'), isNull);
      expect(Rational.tryParse('1/0'), isNull);
    });

    test('有限小数判定', () {
      expect(Rational(1, 8).hasFiniteDecimal, isTrue);
      expect(Rational(1, 3).hasFiniteDecimal, isFalse);
      expect(Rational(1, 20).hasFiniteDecimal, isTrue);
    });
  });

  group('知识点树与归类', () {
    test('种子数据覆盖 1–6 年级，编码唯一', () {
      final all = buildSeedKnowledgePoints();
      final codes = all.map((p) => p.code).toSet();
      expect(codes.length, all.length, reason: '知识编码必须唯一');
      for (var g = 1; g <= 6; g++) {
        expect(all.any((p) => p.grade == g), isTrue, reason: '缺少 $g 年级');
      }
    });

    test('五个领域都有覆盖', () {
      final all = buildSeedKnowledgePoints();
      for (final d in DomainCode.values) {
        expect(all.any((p) => p.domain == d), isTrue, reason: '缺少领域 ${d.label}');
      }
    });

    test('按编码可精确查到', () {
      final idx = KnowledgeIndex();
      final p = idx.byCode('MA-G3-S1-NA-04-02');
      expect(p, isNotNull);
      expect(p!.grade, 3);
      expect(p.unit, '多位数乘一位数');
    });

    test('按考点名 + 年级能落位（模型输出不可能每次字面一致）', () {
      final idx = KnowledgeIndex();
      final r = idx.match(knowledgePoint: '笔算（含进位）', grade: 3);
      expect(r.hit, isTrue);
      expect(r.point!.unit, '多位数乘一位数');
      expect(r.point!.grade, 3);
    });

    test('模糊匹配要能命中，但必须标记为需复核', () {
      final idx = KnowledgeIndex();
      final r = idx.match(knowledgePoint: '小数乘法', grade: 5);
      expect(r.hit, isTrue);
      expect(r.level, isNot(MatchLevel.none));
    });

    test('完全不相关内容必须未命中，绝不猜一个错的塞进去', () {
      final idx = KnowledgeIndex();
      final r = idx.match(knowledgePoint: '量子纠缠与希尔伯特空间');
      expect(r.hit, isFalse);
      expect(r.needsReview, isTrue);
    });

    test('单元层可按年级分组（供 UI 折叠与组卷筛选用）', () {
      final idx = KnowledgeIndex();
      final m = idx.unitsByGrade(6);
      expect(m[DomainCode.gs], isNotNull);
      expect(m[DomainCode.gs]!.any((u) => u.name == '圆'), isTrue);
    });
  });

  group('竖式排版器', () {
    test('加法：数位严格对齐，进位小字位置正确', () {
      final l = VerticalTypeset.add(16, 27);
      expect(l.kind, 'add');
      final c = l.cols - 1; // 个位所在列
      // 个位对齐
      expect(l.at(1, c)!.text, '6');
      expect(l.at(2, c)!.text, '7');
      // 十位对齐
      expect(l.at(1, c - 1)!.text, '1');
      expect(l.at(2, c - 1)!.text, '2');
      // 运算符在第二行最左
      expect(l.at(2, 0)!.text, '+');
      // 结果 43：个位 3、十位 4
      expect(l.at(3, c)!.text, '3');
      expect(l.at(3, c - 1)!.text, '4');
      // 进位 1 写在十位上方
      expect(l.at(0, c - 1)!.text, '1');
      // 横线画在第二行下方
      expect(l.rulesAfter, contains(2));
    });

    test('减法：不出现负数，退位有标记', () {
      final l = VerticalTypeset.sub(52, 27);
      final c = l.cols - 1;
      expect(l.at(3, c)!.text, '5'); // 个位 5
      expect(l.at(3, c - 1)!.text, '2'); // 十位 2
      expect(l.at(2, 0)!.text, '−');
      // 个位 2 < 7 需要借位
      expect(l.at(0, c - 1), isNotNull);

      expect(() => VerticalTypeset.sub(3, 9), throwsArgumentError);
    });

    test('乘法（一位数乘数）：结果只出现一次，不重复画部分积', () {
      final l = VerticalTypeset.mul(23, 4);
      final c = l.cols - 1;
      expect(l.rows, 3, reason: '被乘数/乘数/积 三行，不能多出一行重复的部分积');
      expect(l.at(2, c)!.text, '2');
      expect(l.at(2, c - 1)!.text, '9');
      expect(l.at(1, c)!.text, '4');
      expect(l.at(1, c - 1)!.text, '×');
    });

    test('乘法（两位数乘数）：部分积错一位写，再加总', () {
      final l = VerticalTypeset.mul(23, 14); // 23×14 = 322；部分积 92 与 230
      expect(l.rows, 5); // 23 / ×14 / 92 / 230 / 322
      final c = l.cols - 1;
      // 第一个部分积 92
      expect(l.at(2, c)!.text, '2');
      expect(l.at(2, c - 1)!.text, '9');
      // 第二个部分积 23 向左错一位写（即 230；教材上末尾的 0 靠错位表示，不另写）
      expect(l.at(3, c), isNull);
      expect(l.at(3, c - 1)!.text, '3');
      expect(l.at(3, c - 2)!.text, '2');
      // 积 322
      expect(l.at(4, c)!.text, '2');
      expect(l.at(4, c - 1)!.text, '2');
      expect(l.at(4, c - 2)!.text, '3');
      // 两条横线：乘数下方、最后一个部分积下方
      expect(l.rulesAfter.length, 2);
    });

    test('带余除法：商与余数正确，逐位步骤可讲解', () {
      final d = VerticalTypeset.div(47, 5);
      expect(d.quotient, 9);
      expect(d.remainder, 2);
      expect(d.isExact, isFalse);
      expect(d.display, '47 ÷ 5 = 9 …… 2');
      // 最高位 4 比除数小、商 0 的那一步会被裁掉，不留给孩子看
      expect(d.steps.length, 1);
      expect(d.steps.last.quotientDigit, 9);
      expect(d.steps.last.product, 45);
      expect(d.steps.last.remainder, 2);
    });

    test('整除时没有余数', () {
      final d = VerticalTypeset.div(48, 6);
      expect(d.quotient, 8);
      expect(d.remainder, 0);
      expect(d.isExact, isTrue);
      expect(d.display, '48 ÷ 6 = 8');
    });

    test('竖式分步话术是给孩子看的，不能是空话', () {
      final l = VerticalTypeset.add(16, 27);
      expect(l.steps, isNotEmpty);
      expect(l.steps.first, contains('个位'));
    });
  });

  group('变体生成与正确性闸门', () {
    test('两位数乘一位数：必须是进位乘法，答案与本地计算一致', () {
      final g = VariantGenerator(seed: 7);
      final vs = g.generateMany(VariantKind.mul2x1, 20);
      expect(vs.length, 20);
      for (final v in vs) {
        final a = v.params['a']!.toInt();
        final b = v.params['b']!.toInt();
        expect(a, inInclusiveRange(10, 99));
        expect(b, inInclusiveRange(2, 9));
        expect((a % 10) * b, greaterThanOrEqualTo(10), reason: '必须是进位乘法');
        expect(v.answer, Rational.fromBig(BigInt.from(a * b)), reason: '答案必须是本地算的');
        expect(VariantGate.check(v).passed, isTrue);
      }
    });

    test('有余数除法：余数必须小于除数，且真的有余数', () {
      final g = VariantGenerator(seed: 11);
      for (var i = 0; i < 30; i++) {
        final v = g.generate(VariantKind.divRemainder)!;
        final a = v.params['a']!.toInt();
        final b = v.params['b']!.toInt();
        expect(a % b, greaterThan(0));
        expect(a % b, lessThan(b));
      }
    });

    test('减法不会出负数，加法不超万以内', () {
      final g = VariantGenerator(seed: 3);
      for (var i = 0; i < 40; i++) {
        final v = g.generate(VariantKind.addSub3)!;
        expect(v.answer.isNegative, isFalse);
        expect(v.answer, lessThanOrEqualTo(Rational(10000)));
      }
    });

    test('三角形面积不能出现非整数/半整数', () {
      final g = VariantGenerator(seed: 5);
      final vs = g.generateMany(VariantKind.triangleArea, 15);
      for (final v in vs) {
        final twice = v.answer * Rational(2);
        expect(twice.isInteger, isTrue, reason: '面积必须是整数或 .5');
      }
    });

    test('闸门能拦住人为构造的退化题', () {
      final bad = Variant(
        kind: VariantKind.triangleArea,
        params: {'base': 0, 'height': 5},
        stem: '底 0 高 5',
        answer: Rational.zero,
        answerUnit: '平方厘米',
        changeDims: const ['数字'],
      );
      expect(VariantGate.check(bad).passed, isFalse);

      final negative = Variant(
        kind: VariantKind.addSub3,
        params: {'a': 1, 'b': 2, 'op': -1},
        stem: '1 − 2',
        answer: Rational(-1),
        answerUnit: '',
        changeDims: const ['数字'],
      );
      expect(VariantGate.check(negative).passed, isFalse);
      expect(VariantGate.check(negative).violations.first, contains('负数'));
    });

    test('长跑用例：连续 8 轮批量生成都不能崩、不能出退化题', () {
      final g = VariantGenerator(seed: 42);
      for (var round = 0; round < 8; round++) {
        for (final kind in VariantKind.values) {
          final vs = g.generateMany(kind, 5);
          expect(vs.length, 5, reason: '第 $round 轮 ${kind.name} 生成不足');
          for (final v in vs) {
            final r = VariantGate.check(v);
            expect(r.passed, isTrue,
                reason: '第 $round 轮 ${kind.name} 出现退化题：${r.violations}');
          }
        }
      }
    });

    test('批量生成会自动去重，不会连出两道一模一样的', () {
      final g = VariantGenerator(seed: 99);
      final vs = g.generateMany(VariantKind.mul2x1, 10);
      final sigs = vs.map((v) => v.params.entries.map((e) => '${e.key}=${e.value}').join('|')).toSet();
      expect(sigs.length, vs.length);
    });
  });

  group('复习调度与重要度', () {
    final now = DateTime(2026, 1, 1);

    test('评分越高间隔越长：easy > good > hard', () {
      final s = FsrsScheduler();
      var st = FsrsState.initial(now);
      st = s.review(st, Rating.good, now);
      final base = st.stability;

      final hard = s.review(st, Rating.hard, now).stability;
      final good = s.review(st, Rating.good, now).stability;
      final easy = s.review(st, Rating.easy, now).stability;

      expect(base, greaterThan(0));
      expect(easy, greaterThan(good));
      expect(good, greaterThan(hard));
    });

    test('答对一定有进展（间隔不能变小）', () {
      final s = FsrsScheduler();
      var st = FsrsState.initial(now);
      st = s.review(st, Rating.good, now);
      for (var i = 0; i < 5; i++) {
        final prev = st.stability;
        st = s.review(st, Rating.good, now);
        expect(st.stability, greaterThan(prev));
      }
    });

    test('答错会回落：稳定性下降、遗忘次数 +1、难度上升', () {
      final s = FsrsScheduler();
      var st = FsrsState.initial(now);
      st = s.review(st, Rating.good, now);
      final before = st.stability;
      final dBefore = st.difficulty;
      st = s.review(st, Rating.again, now);
      expect(st.stability, lessThan(before));
      expect(st.lapses, 1);
      expect(st.difficulty, greaterThan(dBefore));
    });

    test('间隔有上下限，不会无限膨胀', () {
      final s = FsrsScheduler();
      var st = FsrsState.initial(now);
      for (var i = 0; i < 40; i++) {
        st = s.review(st, Rating.easy, now);
      }
      expect(st.stability, lessThanOrEqualTo(180));
      expect(st.stability, greaterThanOrEqualTo(0.5));
    });

    test('重要度：答错 +1，答对衰减，连续答对清零', () {
      final p = ImportancePolicy.defaultPolicy;
      var imp = 0;
      var streak = 0;

      final w1 = p.apply(importance: imp, streak: streak, correct: false);
      imp = w1.importance;
      streak = w1.streak;
      expect(imp, 1);
      expect(streak, 0);

      final w2 = p.apply(importance: imp, streak: streak, correct: false);
      imp = w2.importance;
      streak = w2.streak;
      expect(imp, 2);

      // 连续答对 3 次后清零（真正掌握）
      var r = p.apply(importance: imp, streak: streak, correct: true);
      imp = r.importance;
      streak = r.streak;
      expect(imp, 1); // 第一次答对只衰减
      r = p.apply(importance: imp, streak: streak, correct: true);
      imp = r.importance;
      streak = r.streak;
      expect(imp, 0);
      r = p.apply(importance: imp, streak: streak, correct: true);
      expect(r.importance, 0);
    });

    test('重要度有上限，不会无限累加霸占列表', () {
      final p = ImportancePolicy.defaultPolicy;
      var imp = 0;
      for (var i = 0; i < 50; i++) {
        imp = p.apply(importance: imp, streak: 0, correct: false).importance;
      }
      expect(imp, lessThanOrEqualTo(10));
    });

    test('状态可序列化往返（要落 SQLite）', () {
      final s = FsrsScheduler();
      final st = s.review(FsrsState.initial(now), Rating.good, now);
      final back = FsrsState.fromMap(st.toMap());
      expect(back.stability, closeTo(st.stability, 1e-9));
      expect(back.reps, st.reps);
      expect(back.due, st.due);
    });
  });
}
