/// 把"识别出来 / AI 生成的题"变成 App 里能正式练习的题。
///
/// 为什么需要这一步：拍照识题和同类题最初只是**展示**题干和答案，
/// 孩子练不了、错了也进不了错题本 —— 那不叫练习。
/// 转成 QuizQuestion 之后就能走本地判分、归档、进复习队列那条既有链路。
library;

import 'package:math_coach/core/rational.dart';
import 'package:math_coach/quiz/question.dart';

import 'solver.dart';
import 'variants.dart';

class AdoptedQuestion {
  /// 转成可以判分/归档的题；[answer] 用于判分（数值优先，读不出数值就用文本比对）。
  static QuizQuestion fromGen(GenVariant v, {int grade = 3, String kpPath = '拍照识题 · 同类题'}) {
    final num = Rational.tryParse(v.answer.trim());
    return QuizQuestion(
      id: 'gen-${v.stem.hashCode}',
      kpPath: kpPath,
      stem: v.stem,
      solutionSteps: const ['先想清楚这道题在问什么', '再一步步算出答案'],
      answer: QuizAnswer(
        display: v.answer,
        value: num?.toDouble(),
        tolerance: 0.011,
        unit: v.unit,
        accepts: [v.answer],
      ),
      kind: 'gen',
      grade: grade,
      difficulty: 3,
    );
  }

  /// 从拍照识别出来的题干转题（答案可能还没讲出来，先留空文案）。
  static QuizQuestion fromStem(String stem,
      {int grade = 3, String kpPath = '拍照识题', String? answer}) {
    final num = answer == null ? null : Rational.tryParse(answer.trim());
    return QuizQuestion(
      id: 'photo-${stem.hashCode}',
      kpPath: kpPath,
      stem: stem,
      solutionSteps: const [],
      answer: QuizAnswer(
        display: answer ?? '',
        value: num?.toDouble(),
        tolerance: 0.011,
        accepts: answer == null ? const [] : [answer],
      ),
      kind: 'photo',
      grade: grade,
      difficulty: 3,
    );
  }

  /// 讲解结果里的答案（供归档时对照）。
  static String answerOf(SolveResult r) => '${r.answer}${r.unit}';
}
