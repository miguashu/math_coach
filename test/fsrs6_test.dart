import 'package:test/test.dart';
import 'package:math_coach/review/fsrs.dart';

/// FSRS-6 数值对照测试。**本文件的数值段由 tool/gen_fsrs_refs.py 生成，别手改**。
///
/// 这里每一个期望值都不是手算的，而是**官方实现算出来的**：
/// `pip install fsrs` 装 py-fsrs，直接调它的 `_next_difficulty` /
/// `_next_stability` / `_initial_stability` / `_initial_difficulty` /
/// `_next_interval` 导出参考值，再逐条断言我们的 Dart 实现。
///
/// 为什么要这么较真：公式里 21 个参数、十几个 exp/pow，
/// 手抄错一个系数照样"跑得通"，但间隔就全歪了 ——
/// 而"间隔歪了"在孩子身上的表现是"该复习的没复习"，家长根本看不出来。
/// 重新生成：`python tool/gen_fsrs_refs.py`（见 docs/app/02-复习页.md）。
void main() {
  final fsrs = Fsrs6();

  group('FSRS-6 与官方实现逐条对照', () {
    test('初始稳定性 S0 与初始难度 D0', () {
      expect(fsrs.initialStability(Rating.values[0]), closeTo(0.212, 1e-12));
      expect(fsrs.initialStability(Rating.values[1]), closeTo(1.2931, 1e-12));
      expect(fsrs.initialStability(Rating.values[2]), closeTo(2.3065, 1e-12));
      expect(fsrs.initialStability(Rating.values[3]), closeTo(8.2956, 1e-12));

      expect(fsrs.initialDifficulty(Rating.values[0]), closeTo(6.4133, 1e-12));
      expect(fsrs.initialDifficulty(Rating.values[1]), closeTo(5.112170705601056, 1e-12));
      expect(fsrs.initialDifficulty(Rating.values[2]), closeTo(2.118103970459016, 1e-12));
      expect(fsrs.initialDifficulty(Rating.values[3]), closeTo(1.0, 1e-12));
    });

    test('decay 与 factor 与官方一致', () {
      expect(fsrs.decay, closeTo(-0.1542, 1e-12));
      expect(fsrs.factor, closeTo(0.9803464944134797, 1e-12));
    });

    test('稳定性更新：4 种评分 x 8 组 (D, S, R)', () {
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.9, rating: Rating.values[0]),
        closeTo(0.6968564784839522, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.9, rating: Rating.values[1]),
        closeTo(7.856756113855405, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.9, rating: Rating.values[2]),
        closeTo(11.075750106177924, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.9, rating: Rating.values[3]),
        closeTo(18.125072373860636, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.5, rating: Rating.values[0]),
        closeTo(1.3473560590496496, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.5, rating: Rating.values[1]),
        closeTo(31.655234872898554, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.5, rating: Rating.values[2]),
        closeTo(50.647547178082064, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.5, rating: Rating.values[3]),
        closeTo(92.2390911098299, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 8.0, stability: 1.0,
            retrievability: 0.9, rating: Rating.values[0]),
        closeTo(0.30775829187838816, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 8.0, stability: 1.0,
            retrievability: 0.9, rating: Rating.values[1]),
        closeTo(1.972038454401077, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 8.0, stability: 1.0,
            retrievability: 0.9, rating: Rating.values[2]),
        closeTo(2.6162927409396026, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 8.0, stability: 1.0,
            retrievability: 0.9, rating: Rating.values[3]),
        closeTo(4.027154674505781, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 2.0, stability: 20.0,
            retrievability: 0.95, rating: Rating.values[0]),
        closeTo(1.8934063277417201, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 2.0, stability: 20.0,
            retrievability: 0.95, rating: Rating.values[1]),
        closeTo(37.351005867633326, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 2.0, stability: 20.0,
            retrievability: 0.95, rating: Rating.values[2]),
        closeTo(48.85102405659016, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 2.0, stability: 20.0,
            retrievability: 0.95, rating: Rating.values[3]),
        closeTo(74.03508295558771, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 1.0, stability: 100.0,
            retrievability: 0.9, rating: Rating.values[0]),
        closeTo(4.136507004033951, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 1.0, stability: 100.0,
            retrievability: 0.9, rating: Rating.values[1]),
        closeTo(250.4396074368163, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 1.0, stability: 100.0,
            retrievability: 0.9, rating: Rating.values[2]),
        closeTo(350.14899806587346, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 1.0, stability: 100.0,
            retrievability: 0.9, rating: Rating.values[3]),
        closeTo(568.5040584775744, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 10.0, stability: 0.5,
            retrievability: 0.8, rating: Rating.values[0]),
        closeTo(0.20144381499418745, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 10.0, stability: 0.5,
            retrievability: 0.8, rating: Rating.values[1]),
        closeTo(0.8787412326443029, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 10.0, stability: 0.5,
            retrievability: 0.8, rating: Rating.values[2]),
        closeTo(1.1297659338947506, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 10.0, stability: 0.5,
            retrievability: 0.8, rating: Rating.values[3]),
        closeTo(1.6794886175914783, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.1, rating: Rating.values[0]),
        closeTo(2.605082116488652, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.1, rating: Rating.values[1]),
        closeTo(64.37638497535377, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.1, rating: Rating.values[2]),
        closeTo(105.05584465472859, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 5.0, stability: 3.0,
            retrievability: 0.1, rating: Rating.values[3]),
        closeTo(194.14039145384118, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 6.5, stability: 45.0,
            retrievability: 0.85, rating: Rating.values[0]),
        closeTo(2.939934710078303, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 6.5, stability: 45.0,
            retrievability: 0.85, rating: Rating.values[1]),
        closeTo(98.26464412076191, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 6.5, stability: 45.0,
            retrievability: 0.85, rating: Rating.values[2]),
        closeTo(133.5677487874325, 1e-9),
      );
      expect(
        fsrs.nextStability(difficulty: 6.5, stability: 45.0,
            retrievability: 0.85, rating: Rating.values[3]),
        closeTo(210.87853670398235, 1e-9),
      );
    });

    test('难度更新：4 种评分 x 8 组 (D, S, R)', () {
      expect(fsrs.nextDifficulty(5.0, Rating.values[0]), closeTo(8.341762369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[1]), closeTo(6.665995369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[2]), closeTo(4.9902283692968386, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[3]), closeTo(3.3144613692968385, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[0]), closeTo(8.341762369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[1]), closeTo(6.665995369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[2]), closeTo(4.9902283692968386, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[3]), closeTo(3.3144613692968385, 1e-12));
      expect(fsrs.nextDifficulty(8.0, Rating.values[0]), closeTo(9.327841969296838, 1e-12));
      expect(fsrs.nextDifficulty(8.0, Rating.values[1]), closeTo(8.657535169296837, 1e-12));
      expect(fsrs.nextDifficulty(8.0, Rating.values[2]), closeTo(7.987228369296838, 1e-12));
      expect(fsrs.nextDifficulty(8.0, Rating.values[3]), closeTo(7.316921569296838, 1e-12));
      expect(fsrs.nextDifficulty(2.0, Rating.values[0]), closeTo(7.3556827692968385, 1e-12));
      expect(fsrs.nextDifficulty(2.0, Rating.values[1]), closeTo(4.674455569296839, 1e-12));
      expect(fsrs.nextDifficulty(2.0, Rating.values[2]), closeTo(1.9932283692968382, 1e-12));
      expect(fsrs.nextDifficulty(2.0, Rating.values[3]), closeTo(1.0, 1e-12));
      expect(fsrs.nextDifficulty(1.0, Rating.values[0]), closeTo(7.0269895692968385, 1e-12));
      expect(fsrs.nextDifficulty(1.0, Rating.values[1]), closeTo(4.010608969296839, 1e-12));
      expect(fsrs.nextDifficulty(1.0, Rating.values[2]), closeTo(1.0, 1e-12));
      expect(fsrs.nextDifficulty(1.0, Rating.values[3]), closeTo(1.0, 1e-12));
      expect(fsrs.nextDifficulty(10.0, Rating.values[0]), closeTo(9.985228369296838, 1e-12));
      expect(fsrs.nextDifficulty(10.0, Rating.values[1]), closeTo(9.985228369296838, 1e-12));
      expect(fsrs.nextDifficulty(10.0, Rating.values[2]), closeTo(9.985228369296838, 1e-12));
      expect(fsrs.nextDifficulty(10.0, Rating.values[3]), closeTo(9.985228369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[0]), closeTo(8.341762369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[1]), closeTo(6.665995369296838, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[2]), closeTo(4.9902283692968386, 1e-12));
      expect(fsrs.nextDifficulty(5.0, Rating.values[3]), closeTo(3.3144613692968385, 1e-12));
      expect(fsrs.nextDifficulty(6.5, Rating.values[0]), closeTo(8.834802169296838, 1e-12));
      expect(fsrs.nextDifficulty(6.5, Rating.values[1]), closeTo(7.661765269296838, 1e-12));
      expect(fsrs.nextDifficulty(6.5, Rating.values[2]), closeTo(6.4887283692968385, 1e-12));
      expect(fsrs.nextDifficulty(6.5, Rating.values[3]), closeTo(5.315691469296839, 1e-12));
    });

    test('稳定性 -> 间隔（天）', () {
      expect(fsrs.nextInterval(0.5), 1);
      expect(fsrs.nextInterval(1.0), 1);
      expect(fsrs.nextInterval(3.0), 3);
      expect(fsrs.nextInterval(10.0), 10);
      expect(fsrs.nextInterval(30.0), 30);
      expect(fsrs.nextInterval(100.0), 100);
      expect(fsrs.nextInterval(365.0), 365);
    });
  });

  group('边际递减：稳定性不能指数爆炸', () {
    test('连续答对时增长倍率必须一路下降（简化版做不到）', () {
      // 这是换 FSRS-6 的核心理由。自研简化版是 S *= factor * ((11-D)/normD)，
      // 倍率恒定 → 连续答对 10 次就是 4^10，只能靠 maxInterval 硬钳掩盖。
      // FSRS-6 有 S^-w9 项，记得越牢增长越慢，倍率自然收敛。
      const fsrs = Fsrs6();
      var d = 5.0;
      var s = 3.0;
      final ratios = <double>[];
      for (var i = 0; i < 12; i++) {
        final next = fsrs.nextStability(
            difficulty: d, stability: s, retrievability: 0.9, rating: Rating.easy);
        ratios.add(next / s);
        s = next;
        d = fsrs.nextDifficulty(d, Rating.easy);
      }
      // 逐次倍率必须单调下降
      for (var i = 1; i < ratios.length; i++) {
        expect(ratios[i], lessThan(ratios[i - 1]),
            reason: '第 $i 次的增长倍率不该比上一次还大');
      }
      // 12 次之后倍率必须已经砍掉一大半（官方实现实测：6.04 → 1.89）
      expect(ratios.first, closeTo(6.04169, 1e-4));
      expect(ratios.last, closeTo(1.88878, 1e-4));
      expect(ratios.last, lessThan(ratios.first / 3));
    });

    test('40 次之后增速趋近于 1，而不是靠 maxInterval 硬钳', () {
      // 注意：这里断言的是**增速**，不是 S 的绝对值。
      // 我一开始写的是 S < 100000，实测 40 次 easy 后 S≈2.46e10 —— 期望错了。
      // 真 FSRS-6 的 S 本来就会一直涨（记得越牢就该间隔越久），
      // 关键是第 n 次的倍率要往 1 收敛：实测 n=40 时倍率≈1.193，n=60 时≈1.120。
      // 简化版是恒定倍率，4^40≈1.2e24，比真 FSRS-6 大 14 个数量级，
      // 那才是"必须靠 maxInterval 掩盖"的那一种。
      const fsrs = Fsrs6();
      var d = 5.0;
      var s = 3.0;
      var ratio = 0.0;
      for (var i = 0; i < 40; i++) {
        final next = fsrs.nextStability(
            difficulty: d, stability: s, retrievability: 0.9, rating: Rating.easy);
        ratio = next / s;
        s = next;
        d = fsrs.nextDifficulty(d, Rating.easy);
      }
      expect(s, greaterThan(0));
      expect(s.isFinite, isTrue);
      expect(ratio, greaterThan(1.0)); // 还在涨
      expect(ratio, lessThan(1.25)); // 但已经没什么可涨的了
      // 倍率单调收敛到第 40 次仍在继续下降
      expect(ratio, lessThan(1.88878));
    });
  });

  group('四级评分都要真的用上', () {
    test('四个评分给出四个不同的稳定性', () {
      const fsrs = Fsrs6();
      final vals = <double>{};
      for (final r in Rating.values) {
        vals.add(fsrs.nextStability(
            difficulty: 5, stability: 3, retrievability: 0.9, rating: r));
      }
      // 四个评分必须有四个不同结果 —— 少一个就说明有评分被"合并"了
      expect(vals.length, 4);
    });

    test('again 稳定性下降，hard/good/easy 依次更高', () {
      const fsrs = Fsrs6();
      double st(Rating r) => fsrs.nextStability(
          difficulty: 5, stability: 3, retrievability: 0.9, rating: r);
      expect(st(Rating.again), lessThan(3.0));
      expect(st(Rating.hard), greaterThan(st(Rating.again)));
      expect(st(Rating.good), greaterThan(st(Rating.hard)));
      expect(st(Rating.easy), greaterThan(st(Rating.good)));
    });

    test('难度：easy 降、again 升，hard/good 居中', () {
      const fsrs = Fsrs6();
      double d(Rating r) => fsrs.nextDifficulty(5.0, r);
      expect(d(Rating.easy), lessThan(d(Rating.good)));
      expect(d(Rating.good), lessThan(d(Rating.hard)));
      expect(d(Rating.hard), lessThan(d(Rating.again)));
    });
  });

  group('评分决策入口 ratingFor（全项目唯一）', () {
    test('答错只能是 again', () {
      // 答错了还自评"很简单"也不许生效 —— 对错是判出来的，不是感觉出来的
      expect(ratingFor(correct: false), Rating.again);
      expect(ratingFor(correct: false, selfRated: Rating.easy), Rating.again);
      expect(ratingFor(correct: false, selfRated: Rating.hard), Rating.again);
    });

    test('答对默认 good', () {
      expect(ratingFor(correct: true), Rating.good);
    });

    test('答对时三档自评都真的传得进去', () {
      expect(ratingFor(correct: true, selfRated: Rating.hard), Rating.hard);
      expect(ratingFor(correct: true, selfRated: Rating.good), Rating.good);
      expect(ratingFor(correct: true, selfRated: Rating.easy), Rating.easy);
    });

    test('答对了却自评"不会"→ 退回 good（自相矛盾的输入要吞掉）', () {
      expect(ratingFor(correct: true, selfRated: Rating.again), Rating.good);
    });

    test('自评三档不含 again', () {
      expect(selfReportRatings, <Rating>[Rating.hard, Rating.good, Rating.easy]);
      expect(selfReportRatings.any((r) => !r.isPass), isFalse);
      expect(Rating.again.isPass, isFalse);
      expect(Rating.easy.isPass, isTrue);
    });
  });

  group('间隔预览：让自评不是盲选', () {
    test('四档给出四个不同的间隔，且 hard < good < easy', () {
      final now = DateTime(2026, 1, 1);
      final sched = FsrsScheduler();
      final st = sched.review(FsrsState.initial(now), Rating.good, now);
      final p = sched.previewIntervals(st, st.due);
      expect(p.length, 4);
      expect(p[Rating.again], const Duration()); // 答错 → 马上再来
      expect(p[Rating.hard]!, lessThan(p[Rating.good]!));
      expect(p[Rating.good]!, lessThan(p[Rating.easy]!));
    });

    test('预览和真做必须算出同一个 due（不能按钮写 3 天、落账 5 天）', () {
      final now = DateTime(2026, 1, 1);
      final sched = FsrsScheduler();
      final st = sched.review(FsrsState.initial(now), Rating.good, now);
      final p = sched.previewIntervals(st, st.due);
      for (final r in Rating.values) {
        final real = sched.review(st, r, st.due);
        expect(real.due.difference(st.due), p[r],
            reason: '${r.name} 的预览和落账不一致');
      }
    });

    test('答错那一档是 lapseStep（默认 0 = 马上）', () {
      final now = DateTime(2026, 1, 1);
      final sched = FsrsScheduler(
          config: const FsrsConfig(lapseStep: Duration(minutes: 10)));
      final st = sched.review(FsrsState.initial(now), Rating.good, now);
      expect(sched.previewIntervals(st, st.due)[Rating.again],
          const Duration(minutes: 10));
    });
  });

  group('调度器集成', () {
    test('首次学习用初始稳定性（不是拿 0 去算）', () {
      final now = DateTime(2026, 1, 1);
      final s = FsrsScheduler().review(FsrsState.initial(now), Rating.good, now);
      expect(s.stability, closeTo(2.3065, 1e-9)); // S0(good) = w[2]
      expect(s.reps, 1);
      expect(s.lastReview, now);
    });

    test('答错后立刻回到队首（lapseStep），不是排到几天后', () {
      final now = DateTime(2026, 1, 1);
      final sched = FsrsScheduler();
      var s = sched.review(FsrsState.initial(now), Rating.good, now);
      s = sched.review(s, Rating.again, now.add(const Duration(days: 5)));
      expect(s.lapses, 1);
      // 默认 lapseStep 是 0 —— 立刻又能练
      expect(s.due.isAfter(now.add(const Duration(days: 5))), isFalse);
      expect(s.stability, lessThan(2.3065));
    });

    test('答对后间隔落在 1..maxInterval 之间', () {
      final now = DateTime(2026, 1, 1);
      final sched = FsrsScheduler();
      var s = FsrsState.initial(now);
      for (var i = 0; i < 30; i++) {
        s = sched.review(s, Rating.easy, now.add(Duration(days: i * 30)));
      }
      final gap = s.due.difference(now.add(const Duration(days: 29 * 30))).inDays;
      expect(gap, greaterThanOrEqualTo(1));
      expect(gap, lessThanOrEqualTo(180));
    });

    test('间隔按先后顺序推进：越复习越久（但增速递减）', () {
      final now = DateTime(2026, 1, 1);
      final sched = FsrsScheduler();
      var s = FsrsState.initial(now);
      final gaps = <int>[];
      var t = now;
      for (var i = 0; i < 6; i++) {
        // 每次都"刚好到期"才复习，模拟真实节奏
        t = s.due;
        final prevDue = s.due;
        s = sched.review(s, Rating.good, t);
        gaps.add(s.due.difference(prevDue).inDays);
      }
      for (var i = 1; i < gaps.length; i++) {
        expect(gaps[i], greaterThanOrEqualTo(gaps[i - 1]),
            reason: '复习节奏稳定时，下一次间隔不该比上次更短');
      }
    });

    test('老备份没有 lastReview 也能读（向后兼容）', () {
      final m = <String, Object?>{
        'stability': 3.0,
        'difficulty': 5.0,
        'due': 1767225600000,
        'reps': 2,
        'lapses': 0,
      };
      final s = FsrsState.fromMap(m);
      expect(s.lastReview, isNull);
      // 没有上次时间 → 当作"刚见过"，R 按 0 天算（= 还记得）
      expect(FsrsScheduler().retrievability(s, DateTime(2026, 1, 1)),
          closeTo(1.0, 1e-9));
    });

    test('lastReview 能存能读', () {
      final now = DateTime(2026, 1, 1);
      final s = FsrsState.initial(now);
      final back = FsrsState.fromMap(s.toMap());
      expect(back.lastReview, now);
      expect(back.stability, s.stability);
    });
  });
}
