/// AI 出题 Agent 回归用例（离线，注入 FakeLlm）。
///
/// 本机跑不了 `dart test`（Dart VM 无法以管道模式 spawn 子进程），
/// 断言写成可直接 `dart run` 的脚本。
///
/// 覆盖重点：**答案本地算**（展示值取自 equation 复算，不是模型报的数字）、
/// 模型自相矛盾就整道丢弃、没验算式丢弃、步骤不足丢弃、"如图"题丢弃、
/// 负数/循环小数丢弃、打回重做、网络失败不崩。
///
/// 跑法：dart run test/quizgen_manual.dart
import 'dart:io';

import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/quizgen.dart';

int _pass = 0;
int _fail = 0;

void ck(String name, bool ok, [String why = '']) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name ${why.isEmpty ? '' : '→ $why'}');
  }
}

class FakeLlm implements LlmPort {
  final List<LlmReply> queue;
  final List<String> seenUser = [];
  FakeLlm(this.queue);

  @override
  Future<LlmReply> chat(
    List<LlmMessage> messages, {
    bool vision = false,
    double temperature = 0.3,
    int maxTokens = 1600,
    Duration timeout = const Duration(seconds: 90),
    String? modelOverride,
  }) async {
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        seenUser.add(m.text);
        break;
      }
    }
    if (queue.isEmpty) throw const LlmError('队列空了（不该发生）');
    return queue.removeAt(0);
  }
}

LlmReply _r(String text) =>
    LlmReply(text: text, totalTokens: 100, latencyMs: 50, model: 'fake');

const _goodJson = '''
{"items":[
 {"stem":"超市里苹果每千克 7 元，妈妈买了 9 千克，一共花了多少元？",
  "answer":"63","unit":"元","equation":"7*9",
  "steps":["先想求总价用什么算：单价×数量=总价。","7×9=63，所以一共 63 元。"],
  "kp":"小数乘法·解决问题","difficulty":2},
 {"stem":"一根绳子长 40 米，剪下 3 段，每段 8 米，还剩多少米？",
  "answer":"16","unit":"米","equation":"40-3*8",
  "steps":["先算剪下去了多少：3 段每段 8 米。","3×8=24，再用总长减去剪掉的：40-24=16 米。"],
  "kp":"混合运算","difficulty":3},
 {"stem":"五名同学参加跳绳比赛，平均每人跳 126 下，他们一共跳了多少下？",
  "answer":"630","unit":"下","equation":"126*5",
  "steps":["平均数×人数=总数。","126×5=630 下。"],
  "kp":"平均数","difficulty":3}
]}''';

Future<void> main() async {
  // 1) 全部合格：答案取本地复算值，难度按档位夹紧
  {
    final llm = FakeLlm([_r(_goodJson)]);
    final res = await QuizAgent(llm).generate(grade: 5, count: 3, level: QuizLevel.boost);
    ck('三道合格题全部收下', res.questions.length == 3, '实得 ${res.questions.length}');
    ck('无错误信息', res.error == null, res.error ?? '');
    final q = res.questions.first;
    ck('答案=本地复算值（63）', q.answer == '63', q.answer);
    ck('value 可供判分', (q.value - 63).abs() < 1e-9, '${q.value}');
    ck('提高档难度不低于 3', q.difficulty >= 3, '${q.difficulty}');
    ck('步骤保留', q.steps.length == 2);
  }

  // 2) 模型答案和自己的算式对不上 → 整道丢弃
  {
    final llm = FakeLlm([
      _r('''{"items":[
 {"stem":"超市里苹果每千克 7 元，妈妈买了 9 千克，一共花了多少元？",
  "answer":"99","unit":"元","equation":"7*9",
  "steps":["单价乘数量。","7×9=99 元。"],"kp":"小数乘法","difficulty":3}
]}''')
    ]);
    final res = await QuizAgent(llm).generate(grade: 5, count: 3, level: QuizLevel.boost);
    ck('自相矛盾的题被丢弃', res.questions.isEmpty, '实得 ${res.questions.length}');
  }

  // 3) 没有 equation → 无法本地验算 → 丢弃
  {
    final llm = FakeLlm([
      _r('''{"items":[
 {"stem":"鸡兔同笼，共头 10 个、脚 28 只，求鸡兔各几只？",
  "answer":"鸡6兔4","unit":"","equation":"",
  "steps":["先假设全是鸡。","再调整。"],"kp":"假设法","difficulty":4}
]}''')
    ]);
    final res = await QuizAgent(llm).generate(grade: 4, count: 2, level: QuizLevel.olympiad);
    ck('没有验算式的题被丢弃', res.questions.isEmpty, '实得 ${res.questions.length}');
  }

  // 4) 步骤只有一步 → 丢弃
  {
    final llm = FakeLlm([
      _r('''{"items":[
 {"stem":"超市里苹果每千克 7 元，妈妈买了 9 千克，一共花了多少元？",
  "answer":"63","unit":"元","equation":"7*9",
  "steps":["7×9=63 元。"],"kp":"小数乘法","difficulty":2}
]}''')
    ]);
    final res = await QuizAgent(llm).generate(grade: 5, count: 2);
    ck('只有一步讲解的被丢弃', res.questions.isEmpty, '实得 ${res.questions.length}');
  }

  // 5) "如图"类题 → 丢弃（本地画不出模型心里那张图）
  {
    final llm = FakeLlm([
      _r('''{"items":[
 {"stem":"如下图，一个长方形被分成两部分，求阴影部分的面积是多少？",
  "answer":"24","unit":"平方厘米","equation":"6*4",
  "steps":["阴影是个长方形。","6×4=24。"],"kp":"组合图形","difficulty":3}
]}''')
    ]);
    final res = await QuizAgent(llm).generate(grade: 5, count: 2);
    ck('需要看图的题被丢弃', res.questions.isEmpty, '实得 ${res.questions.length}');
  }

  // 6) 负数与循环小数 → 丢弃
  {
    final llm = FakeLlm([
      _r('''{"items":[
 {"stem":"温度从 5 摄氏度降到零下 4 摄氏度，温差是多少摄氏度？",
  "answer":"-9","unit":"摄氏度","equation":"5-9",
  "steps":["减法算温差。","5-9=-9。"],"kp":"正负数","difficulty":3},
 {"stem":"3 个苹果平均分给 7 个人，每人得多少个？",
  "answer":"3/7","unit":"个","equation":"3/7",
  "steps":["除法。","3÷7=3/7。"],"kp":"分数","difficulty":4}
]}''')
    ]);
    final res = await QuizAgent(llm).generate(grade: 6, count: 2);
    ck('负数与循环小数都被丢弃', res.questions.isEmpty, '实得 ${res.questions.length}');
  }

  // 7) 打回重做：第一次只给 1 道合格的，第二次补齐
  {
    final llm = FakeLlm([
      _r('''{"items":[
 {"stem":"超市里苹果每千克 7 元，妈妈买了 9 千克，一共花了多少元？",
  "answer":"63","unit":"元","equation":"7*9",
  "steps":["单价乘数量。","7×9=63 元。"],"kp":"小数乘法","difficulty":2}
]}'''),
      _r(_goodJson),
    ]);
    final res = await QuizAgent(llm).generate(grade: 5, count: 3, level: QuizLevel.boost);
    ck('重做后补齐 3 道', res.questions.length == 3, '实得 ${res.questions.length}');
    ck('共发起 2 次调用', res.attempts == 2, 'attempts=${res.attempts}');
    ck('打回信息说明了原因', llm.seenUser.last.contains('本地复算'), llm.seenUser.last);
  }

  // 8) 网络失败：不抛异常，错误写进结果
  {
    final llm = FakeLlm([]); // 队列空 → 抛 LlmError
    final res = await QuizAgent(llm).generate(grade: 5, count: 3);
    ck('失败不抛异常', true);
    ck('失败时有错误信息', res.error != null && res.error!.isNotEmpty, res.error ?? '');
    ck('失败时无题目', res.questions.isEmpty && !res.ok);
  }

  // 9) 已出过的题进 prompt（避重）
  {
    final llm = FakeLlm([_r(_goodJson)]);
    await QuizAgent(llm).generate(
        grade: 5, count: 3, avoid: ['一辆汽车 3 小时行 180 千米，平均每小时行多少千米？']);
    ck('避重清单进了 prompt', llm.seenUser.first.contains('已出过的题'), llm.seenUser.first);
    ck('避重清单含原题', llm.seenUser.first.contains('3 小时行 180 千米'));
  }

  // 10) 知识点本地归类：年级优先
  {
    final p1 = classifyKp('旋转', grade: 5);
    ck('G5 旋转归到五下图形的运动（三）', p1.contains('图形的运动') && p1.startsWith('五下'), p1);
    final p2 = classifyKp('长方体的体积', grade: 5);
    ck('G5 体积归到长方体和正方体', p2.contains('长方体和正方体'), p2);
    final p3 = classifyKp('完全不存在的知识点XYZ', grade: 5, unit: '植树问题');
    ck('归不上时按单元归类', p3.contains('植树问题'), p3);
    final p4 = classifyKp('完全不存在的知识点XYZ', grade: 5);
    ck('连单元都归不上时给综合应用', p4 == '综合应用', p4);
    // 年级卡死：模型在五年级卷子上自称"分数除法"（那是六年级的考点），
    // 不能把卷子标成六上 —— 宁可标综合应用
    final p5 = classifyKp('分数除法', grade: 5);
    ck('自称隔壁年级考点时不挂错年级', !p5.startsWith('六'), p5);
    final p6 = classifyKp('分数除法', grade: 6);
    ck('六年级问分数除法能归上', p6.contains('分数除法') && p6.startsWith('六'), p6);
  }

  // 11) 模型把 JSON 包在 ``` 代码块里也要能解析
  {
    final llm = FakeLlm([
      _r('```json\n$_goodJson\n```')
    ]);
    final res = await QuizAgent(llm).generate(grade: 5, count: 3);
    ck('代码块包裹的 JSON 能解析', res.questions.length == 3, '实得 ${res.questions.length}');
  }

  // 12) 超过 3 道时分批调用（每批 ≤3），批与批之间互相避重
  {
    final llm = FakeLlm([_r(_goodJson), _r(_goodJson)]);
    final res =
        await QuizAgent(llm).generate(grade: 5, count: 6, level: QuizLevel.olympiad);
    ck('6 道分 2 批调用', llm.seenUser.length == 2, '实调 ${llm.seenUser.length} 次');
    ck('第一批只要 3 道', llm.seenUser.first.contains('请出 3 道题'), llm.seenUser.first);
    ck('第二批避开了第一批的题干',
        llm.seenUser.last.contains('苹果每千克 7 元'), llm.seenUser.last);
    ck('合并后 6 道', res.questions.length == 6, '实得 ${res.questions.length}');
  }

  print('\n$_pass 通过 / $_fail 失败');
  if (_fail > 0) exit(1);
}
