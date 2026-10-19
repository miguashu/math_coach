/// 复习调度（**FSRS-6**）+ 重要度衰减。
///
/// ## 为什么换成真 FSRS-6
///
/// 之前这里是自研简化版，稳定性用 `S * factor * ((11-D)/normD)` 线性相乘。
/// 那个写法有个致命毛病：**连续答对会指数爆炸**（factor 3.2 时答对 10 次就是 4^10），
/// 只能靠 `maxInterval = 180 天` 硬钳住把症状盖住 —— 参数调错了却看不出来。
///
/// 真 FSRS-6 的稳定性增长带 **边际递减项** `S^(-w9)`：
/// 记得越牢，再练一次的收益越小，间隔会自然收敛，不需要靠钳制遮掩。
///
/// ## 参数与公式来源
///
/// 21 个默认参数与全部公式逐条对齐
/// `open-spaced-repetition/py-fsrs`（FSRS-6，MIT）。
/// **数值由 `test/fsrs6_test.dart` 对着官方实现生成的参考值逐条断言** ——
/// 不是"照着论文手抄一遍"，抄错一个系数测试就会红。
///
/// ## 刻意没做完整状态机
///
/// 官方实现有 Learning / Review / Relearning 三态 + 同日复习的
/// `short_term_stability`。这里**只实现跨天复习（Review）这条主路径**：
/// 本项目的场景是错题本，孩子不会在同一天把一道错题翻出来练八遍，
/// 而且答错走的是 [FsrsConfig.lapseStep]（几分钟后回来重练一次），
/// 不走 Anki 的 learning steps。
///
/// 但**遗忘分支里的 `min(长时, 短时)` 保留了** —— 那两项是 FSRS-6 原生的，
/// 官方就是这么写的，不是我们多加的。
library;

import 'dart:math' as math;

enum Rating {
  again(1, '不会'),
  hard(2, '有点难'),
  good(3, '会了'),
  easy(4, '很简单');

  const Rating(this.value, this.label);
  final int value;
  final String label;

  /// 这一档算"过了"。只有 again 不算。
  bool get isPass => this != Rating.again;

  static Rating fromValue(int v) =>
      values.firstWhere((r) => r.value == v, orElse: () => Rating.good);
}

/// 答对之后可自评的三档（again 不在里面）。
///
/// 答案都对了还自评"不会"是自相矛盾 —— [ratingFor] 会把它当成 good。
const List<Rating> selfReportRatings = <Rating>[
  Rating.hard,
  Rating.good,
  Rating.easy,
];

/// 一次作答该记哪一档评分 —— **全项目唯一的评分决策入口**。
///
/// 之前每个调用点各写一遍 `correct ? Rating.good : Rating.again`，
/// 结果 hard / easy 从来没人传，四级评分里两档是死的。现在统一走这里：
/// - 答错 → 只能是 [Rating.again]（不会就是不会，没有"错得有点难"这一说）
/// - 答对 → 默认 [Rating.good]；有自评就用自评（自评成 again 也退回 good）
///
/// 想让 hard/easy 真的生效，调用方把 [selfRated] 传进来即可。
Rating ratingFor({required bool correct, Rating? selfRated}) {
  if (!correct) return Rating.again;
  if (selfRated == null || !selfRated.isPass) return Rating.good;
  return selfRated;
}

/// FSRS-6 的 21 个默认参数。
///
/// 顺序与含义（照抄官方，别重排 —— 索引就是语义）：
/// ```
/// w[0..3]    首次学习各评分的初始稳定性 S0(again/hard/good/easy)
/// w[4..5]    初始难度 D0(g) = w4 - e^(w5*(g-1)) + 1
/// w[6]       难度随评分的变化量
/// w[7]       难度的均值回归强度（把 D 往 D0(easy) 方向拉一点）
/// w[8..10]   答对时稳定性的增长
/// w[11..14]  遗忘后稳定性的重建
/// w[15]      hard 惩罚
/// w[16]      easy 奖励
/// w[17..19]  同日复习的短时稳定性（我们只在遗忘分支用到 w17*w18）
/// w[20]      遗忘曲线衰减 decay
/// ```
class Fsrs6Params {
  static const List<double> w = <double>[
    0.212, 1.2931, 2.3065, 8.2956, //  S0
    6.4133, 0.8334, 3.0194, 0.001, //  D0 / 难度
    1.8722, 0.1666, 0.796, //       答对增长
    1.4835, 0.0614, 0.2629, 1.6483, // 遗忘重建
    0.6014, 1.8729, //              hard 惩罚 / easy 奖励
    0.5425, 0.0912, 0.0658, //      短时稳定性
    0.1542, //                      decay
  ];

  /// 稳定性下限（官方 STABILITY_MIN）。防止出现 0 或负数。
  static const double stabilityMin = 0.001;

  /// 难度范围。
  static const double difficultyMin = 1.0;
  static const double difficultyMax = 10.0;
}

/// FSRS-6 核心算法 —— **纯函数，无状态，可逐条对照测试**。
class Fsrs6 {
  final List<double> w;

  /// 目标留存率：希望复习时还有多大概率记得（默认 0.9）。
  /// 这个值本身就是个产品旋钮：想让孩子记得更牢就调高（间隔变短）。
  final double desiredRetention;

  const Fsrs6({this.w = Fsrs6Params.w, this.desiredRetention = 0.9});

  /// 遗忘曲线衰减。
  double get decay => -w[20];

  /// 0.9^(1/decay) - 1，FSRS 用它把"稳定性"换算成"留存率"。
  double get factor => math.pow(0.9, 1 / decay) - 1;

  double _clampS(double v) =>
      v < Fsrs6Params.stabilityMin ? Fsrs6Params.stabilityMin : v;

  double _clampD(double v) => v < Fsrs6Params.difficultyMin
      ? Fsrs6Params.difficultyMin
      : (v > Fsrs6Params.difficultyMax ? Fsrs6Params.difficultyMax : v);

  /// 首次学习的初始稳定性 S0(g) = w[g-1]。
  double initialStability(Rating g) => _clampS(w[g.value - 1]);

  /// 初始难度 D0(g) = w4 - e^(w5*(g-1)) + 1，钳到 1..10。
  double initialDifficulty(Rating g) =>
      _clampD(w[4] - math.exp(w[5] * (g.value - 1)) + 1);

  /// 上面那个公式**不钳**的版本 —— 均值回归要用未钳制的值。
  double _initialDifficultyRaw(Rating g) =>
      w[4] - math.exp(w[5] * (g.value - 1)) + 1;

  /// 当前还能想起来的概率 R。
  ///
  /// `elapsedDays` 是距上次复习过了几天（可以是小数）。
  /// 刚复习完 R=1；随着时间推移按幂函数衰减。
  double retrievability(double elapsedDays, double stability) {
    final s = stability < Fsrs6Params.stabilityMin
        ? Fsrs6Params.stabilityMin
        : stability;
    return math.pow(1 + factor * (elapsedDays < 0 ? 0 : elapsedDays) / s, decay)
        .toDouble();
  }

  /// 难度更新：先按评分移动，再做**线性阻尼**（越接近 10 移动越慢）
  /// 和**均值回归**（往 D0(easy) 方向拉一点，防止 D 长时间漂移到极端）。
  double nextDifficulty(double difficulty, Rating g) {
    final arg1 = _initialDifficultyRaw(Rating.easy);
    final delta = -(w[6] * (g.value - 3));
    final arg2 = difficulty + (10 - difficulty) * delta / 9;
    return _clampD(w[7] * arg1 + (1 - w[7]) * arg2);
  }

  /// 稳定性更新。答错走[nextForgetStability]，答对走[nextRecallStability]。
  double nextStability({
    required double difficulty,
    required double stability,
    required double retrievability,
    required Rating rating,
  }) {
    if (rating == Rating.again) {
      return _clampS(nextForgetStability(
        difficulty: difficulty,
        stability: stability,
        retrievability: retrievability,
      ));
    }
    return _clampS(nextRecallStability(
      difficulty: difficulty,
      stability: stability,
      retrievability: retrievability,
      rating: rating,
    ));
  }

  /// 遗忘后的稳定性：长时重建与"短时衰减"取**较小**者。
  ///
  /// 含 `D^-w12` —— 难的内容忘得更快、重建更慢，这是简化版完全没有的。
  double nextForgetStability({
    required double difficulty,
    required double stability,
    required double retrievability,
  }) {
    final longTerm = w[11] *
        math.pow(difficulty, -w[12]) *
        (math.pow(stability + 1, w[13]) - 1) *
        math.exp((1 - retrievability) * w[14]);
    final shortTerm = stability / math.exp(w[17] * w[18]);
    return math.min(longTerm.toDouble(), shortTerm);
  }

  /// 答对后的稳定性增长。
  ///
  /// 关键是 `S^-w9` 这个**边际递减**项：S 越大增长越慢 → 自然收敛，
  /// 不像线性相乘那样指数爆炸。hard 有惩罚、easy 有奖励。
  double nextRecallStability({
    required double difficulty,
    required double stability,
    required double retrievability,
    required Rating rating,
  }) {
    final hardPenalty = rating == Rating.hard ? w[15] : 1.0;
    final easyBonus = rating == Rating.easy ? w[16] : 1.0;
    return stability *
        (1 +
            math.exp(w[8]) *
                (11 - difficulty) *
                math.pow(stability, -w[9]) *
                (math.exp((1 - retrievability) * w[10]) - 1) *
                hardPenalty *
                easyBonus);
  }

  /// 稳定性 → 复习间隔（天）。FSRS-6 原生公式，至少 1 天。
  int nextInterval(double stability) {
    final days =
        (stability / factor) * (math.pow(desiredRetention, 1 / decay) - 1);
    final n = days.round();
    return n < 1 ? 1 : n;
  }
}

class FsrsState {
  /// 记忆稳定性（天）。越大代表记得越牢。
  final double stability;

  /// 记忆难度 1..10。越大代表越难。
  final double difficulty;

  /// 下次复习时间。
  final DateTime due;

  /// 已复习次数。
  final int reps;

  /// 遗忘（答错）次数。
  final int lapses;

  /// 上次复习时间。算"还记得多少"(retrievability) 必须要它。
  ///
  /// **可为 null**：老备份里没这个字段，[fromMap] 读不到就当第一次见。
  final DateTime? lastReview;

  const FsrsState({
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.reps,
    required this.lapses,
    this.lastReview,
  });

  static FsrsState initial(DateTime now) => FsrsState(
        stability: 0,
        difficulty: 5,
        due: now,
        reps: 0,
        lapses: 0,
        lastReview: now,
      );

  FsrsState copyWith({
    double? stability,
    double? difficulty,
    DateTime? due,
    int? reps,
    int? lapses,
    DateTime? lastReview,
  }) =>
      FsrsState(
        stability: stability ?? this.stability,
        difficulty: difficulty ?? this.difficulty,
        due: due ?? this.due,
        reps: reps ?? this.reps,
        lapses: lapses ?? this.lapses,
        lastReview: lastReview ?? this.lastReview,
      );

  Map<String, Object?> toMap() => {
        'stability': stability,
        'difficulty': difficulty,
        'due': due.millisecondsSinceEpoch,
        'reps': reps,
        'lapses': lapses,
        if (lastReview != null)
          'lastReview': lastReview!.millisecondsSinceEpoch,
      };

  static FsrsState fromMap(Map<String, Object?> m) => FsrsState(
        stability: (m['stability'] as num?)?.toDouble() ?? 0,
        difficulty: (m['difficulty'] as num?)?.toDouble() ?? 5,
        due: DateTime.fromMillisecondsSinceEpoch((m['due'] as int?) ?? 0),
        reps: (m['reps'] as int?) ?? 0,
        lapses: (m['lapses'] as int?) ?? 0,
        lastReview: m['lastReview'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['lastReview'] as int?) ?? 0),
      );
}

class FsrsConfig {
  /// FSRS-6 权重。默认即用官方默认参数。
  final List<double> parameters;

  /// 目标留存率。调高 → 间隔变短 → 记得更牢。
  final double desiredRetention;

  /// 最长间隔（天）。
  ///
  /// **这不是 FSRS 的行为，是本项目的业务约束**：家长工具把一道错题排到
  /// 半年一年之后再练没有意义（那时候孩子都升学了）。
  /// 真 FSRS 的上限是 36500 天。
  final double maxInterval;

  /// 答错后到下一次练习的间隔（"重学步骤"）。
  ///
  /// 为什么不能用算出来的稳定间隔：错题必须在几分钟内回来重练一次，
  /// 等到三天后再见这段讲解早就忘干净了 —— 那样错题本就失去意义了。
  final Duration lapseStep;

  const FsrsConfig({
    this.parameters = Fsrs6Params.w,
    this.desiredRetention = 0.9,
    this.maxInterval = 180,
    this.lapseStep = Duration.zero,
  });

  static const defaultConfig = FsrsConfig();
}

class FsrsScheduler {
  final FsrsConfig config;

  const FsrsScheduler({this.config = FsrsConfig.defaultConfig});

  Fsrs6 get _fsrs =>
      Fsrs6(w: config.parameters, desiredRetention: config.desiredRetention);

  /// 距上次复习过了几天（小数）。没有上次记录就当 0（刚见过，还记得）。
  double _elapsedDays(FsrsState s, DateTime now) {
    if (s.lastReview == null) return 0;
    final delta = now.difference(s.lastReview!).inSeconds / 86400.0;
    return delta < 0 ? 0 : delta;
  }

  /// 评分后更新状态。
  FsrsState review(FsrsState s, Rating r, DateTime now) => _simulate(s, r, now);

  /// 四个评分各自会把这道题推到多久之后 —— **给自评按钮用**。
  ///
  /// 没有这个，孩子点"有点难"和"很简单"是盲选，两档的区别只存在于代码里；
  /// 有了它，按钮上直接写"→ 3 天后再见"，选的人知道自己在选什么。
  /// 这也是四级评分"看得见的证据"：四档给出四个不同长度，才叫真的用上了。
  ///
  /// 返回的是**时长**不是天数：答错走 [FsrsConfig.lapseStep]（默认 0，
  /// 也就是"马上再来一次"），按天算是 0，看不出区别。
  Map<Rating, Duration> previewIntervals(FsrsState s, DateTime now) => {
        for (final r in Rating.values)
          r: _simulate(s, r, now).due.difference(now),
      };

  /// [review] 与 [previewIntervals] 共用的唯一实现 —— 预演和真做必须算出一模一样的结果，
  /// 否则按钮上写"3 天后"、落账却是 5 天后，比不给预览更糟。
  FsrsState _simulate(FsrsState s, Rating r, DateTime now) {
    final fsrs = _fsrs;
    late final double newS;
    late final double newD;

    if (s.reps == 0) {
      // 首次学习：连"第一次就答错"也走初始稳定性（= 还没学会，别排到几天后）
      newS = fsrs.initialStability(r);
      newD = fsrs.initialDifficulty(r);
    } else {
      final elapsed = _elapsedDays(s, now);
      final retriev = fsrs.retrievability(elapsed, s.stability);
      newS = fsrs.nextStability(
        difficulty: s.difficulty,
        stability: s.stability,
        retrievability: retriev,
        rating: r,
      );
      newD = fsrs.nextDifficulty(s.difficulty, r);
    }

    final didForget = r == Rating.again;
    // 间隔：答错走"重学步骤"（几分钟后回来），答对按 FSRS-6 算出来再钳上限
    final intervalDays =
        fsrs.nextInterval(newS).toDouble().clamp(1.0, config.maxInterval);

    return FsrsState(
      stability: newS,
      difficulty: newD,
      due: didForget
          ? now.add(config.lapseStep)
          : now.add(Duration(
              milliseconds: (intervalDays * 24 * 3600 * 1000).round())),
      reps: s.reps + 1,
      lapses: s.lapses + (didForget ? 1 : 0),
      lastReview: now,
    );
  }

  /// 这道题现在还能想起来的概率（0..1）。
  ///
  /// 列表排序用它比"到期了才复习"更直观：**快忘了的先复习**。
  double retrievability(FsrsState s, DateTime now) {
    if (s.reps == 0) return 0;
    return _fsrs.retrievability(_elapsedDays(s, now), s.stability);
  }
}

/// 重要度策略：答错 +1，答对衰减。
///
/// 关键点：不能单调累加。否则"练了 20 次"的考点会永远排在"错了 1 次但完全没掌握"的前面。
class ImportancePolicy {
  /// 答错时增加量。
  final int wrongDelta;

  /// 答对时衰减量。
  final int rightDecay;

  /// 连续答对多少次后清零（真正掌握）。
  final int streakToClear;

  /// 重要度上限，避免个别考点数值爆炸。
  final int max;

  const ImportancePolicy({
    this.wrongDelta = 1,
    this.rightDecay = 1,
    this.streakToClear = 3,
    this.max = 10,
  });

  static const defaultPolicy = ImportancePolicy();

  /// 返回 (新重要度, 新连对数)。
  ({int importance, int streak}) apply({
    required int importance,
    required int streak,
    required bool correct,
  }) {
    if (!correct) {
      return (
        importance: (importance + wrongDelta).clamp(0, max),
        streak: 0,
      );
    }
    final newStreak = streak + 1;
    if (newStreak >= streakToClear) {
      return (importance: 0, streak: newStreak);
    }
    return (
      importance: (importance - rightDecay).clamp(0, max),
      streak: newStreak,
    );
  }

  /// 是否需要"重点关照"：重要度 >= 3 且近期答错过。
  bool needsAttention(int importance) => importance >= 3;
}
