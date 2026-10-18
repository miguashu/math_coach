/// 复习调度（简化 FSRS）+ 重要度衰减。
///
/// 来自方案 P1 反对八的修正：
///   - 「错一次重要度 +1」是单调累加，会让同一考点长期霸占列表顶端；
///     但"练了很多次"和"依然不会"是两回事。
///   - 所以重要度必须支持**答对后衰减**，而"什么时候该复习"交给间隔调度决定。
///
/// 这里实现的是 FSRS 的核心思想（稳定性 S、难度 D、间隔 I = f(S, D, 评分)），
/// 参数做成可配置，便于后续按真实数据校准。
library;

enum Rating {
  again(1, '不会'),
  hard(2, '有点难'),
  good(3, '会了'),
  easy(4, '很简单');

  const Rating(this.value, this.label);
  final int value;
  final String label;

  static Rating fromValue(int v) =>
      values.firstWhere((r) => r.value == v, orElse: () => Rating.good);
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

  const FsrsState({
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.reps,
    required this.lapses,
  });

  static FsrsState initial(DateTime now) => FsrsState(
        stability: 0,
        difficulty: 5,
        due: now,
        reps: 0,
        lapses: 0,
      );

  Map<String, Object?> toMap() => {
        'stability': stability,
        'difficulty': difficulty,
        'due': due.millisecondsSinceEpoch,
        'reps': reps,
        'lapses': lapses,
      };

  static FsrsState fromMap(Map<String, Object?> m) => FsrsState(
        stability: (m['stability'] as num?)?.toDouble() ?? 0,
        difficulty: (m['difficulty'] as num?)?.toDouble() ?? 5,
        due: DateTime.fromMillisecondsSinceEpoch((m['due'] as int?) ?? 0),
        reps: (m['reps'] as int?) ?? 0,
        lapses: (m['lapses'] as int?) ?? 0,
      );
}

class FsrsConfig {
  /// 首次学习各评分对应的初始稳定性（天）。
  final List<double> firstStability;

  /// 复习时各评分的增长倍率 [again, hard, good, easy]。
  final List<double> factors;

  /// 难度对间隔的抑制系数：间隔再乘 (11 − D) / normD。
  final double normD;

  /// 答错时稳定性的保留比例。
  final double lapseRetention;

  /// 答错时难度增加量。
  final double lapseDifficultyDelta;

  /// 答错后到下一次练习的间隔（"重学步骤"）。
  ///
  /// 为什么不能用算出来的稳定间隔：错题必须在几分钟内回来重练一次，
  /// 等到三天后再见这段讲解早就忘干净了 —— 那样错题本就失去意义了。
  final Duration lapseStep;

  /// 最短间隔（天）。
  final double minInterval;

  /// 最长间隔（天）。
  final double maxInterval;

  const FsrsConfig({
    this.firstStability = const [0.5, 1.0, 3.0, 7.0],
    this.factors = const [0.35, 1.2, 2.2, 3.2],
    this.normD = 8.0,
    this.lapseRetention = 0.35,
    this.lapseDifficultyDelta = 1.5,
    this.lapseStep = Duration.zero,
    this.minInterval = 0.5,
    this.maxInterval = 180,
  });

  static const defaultConfig = FsrsConfig();
}

class FsrsScheduler {
  final FsrsConfig config;

  const FsrsScheduler({this.config = FsrsConfig.defaultConfig});

  /// 评分后更新状态。
  FsrsState review(FsrsState s, Rating r, DateTime now) {
    final i = r.value - 1; // 0..3

    double newS;
    double newD;

    if (s.reps == 0 && r != Rating.again) {
      // 首次学习
      newS = config.firstStability[i];
      newD = _clamp(5 + (3 - r.value) * 1.0, 1, 10);
    } else if (r == Rating.again) {
      // 遗忘：稳定性大幅回落，难度上升。
      // 注意这里覆盖了 reps==0 的情况：第一次就答错也算"没学会"，
      // 不能按首次学习的间隔把它排到几天后去。
      newS = (s.stability * config.lapseRetention).clamp(config.minInterval, config.maxInterval);
      newD = _clamp(s.difficulty + config.lapseDifficultyDelta, 1, 10);
    } else {
      // 通过：按评分倍率增长，难度越高增长越慢
      final factor = config.factors[i];
      newD = _clamp(s.difficulty + (3 - r.value) * 0.8, 1, 10);
      final damped = factor * ((11 - newD) / config.normD);
      newS = s.stability * damped;
      // 保证答对一定有进展，否则孩子会觉得"练了也没用"
      if (newS < s.stability * 1.05) newS = s.stability * 1.05;
      newS = newS.clamp(config.minInterval, config.maxInterval);
    }

    final didForget = r == Rating.again;
    return FsrsState(
      stability: newS,
      difficulty: newD,
      // 答错后走"重学步骤"：几分钟内回到队列，而不是按稳定间隔等到明天
      due: didForget ? now.add(config.lapseStep) : now.add(Duration(milliseconds: (newS * 24 * 3600 * 1000).round())),
      reps: s.reps + 1,
      lapses: s.lapses + (didForget ? 1 : 0),
    );
  }

  double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
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
