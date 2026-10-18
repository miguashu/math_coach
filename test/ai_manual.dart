/// AI 层回归用例。
///
/// 本机跑不了 `dart test`（Dart VM 无法以管道模式 spawn 子进程，预编译阶段就失败），
/// 所以断言写成可直接 `dart run` 的脚本，和判分脚本同一套做法。
///
/// **不联网**：注入 FakeLlm，把"模型说了什么"的每种情况都跑一遍 ——
/// 尤其是模型偷懒只讲一步、报的答案和自己的算式对不上、没给验算式这三种。
///
/// 跑法：dart run test/ai_manual.dart
import 'dart:io';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/expr.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/log.dart';
import 'package:math_coach/ai/ocr.dart';
import 'package:math_coach/ai/solver.dart';
import 'package:math_coach/ai/variants.dart';
import 'package:math_coach/core/rational.dart';

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

/// 假模型：按队列返回内容，并记录每一次被调用时的最后一条 user 消息
/// （用来验证"打回重做"真的把原因传回去了）。
class FakeLlm implements LlmPort {
  final List<LlmReply> queue;
  final List<String> seen = [];

  /// 记录每次调用用的模型（null = 配置里的主模型），用来验证降级真的换了模型。
  final List<String?> models = [];
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
    models.add(modelOverride);
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        seen.add(m.text);
        break;
      }
    }
    if (queue.isEmpty) throw const LlmError('队列空了（不该发生）');
    return queue.removeAt(0);
  }
}

/// 第一次调用报"这个模型走不了对话接口"、第二次正常。
/// 实测里最典型的就是把画图模型（gpt-image-2-token）当成识图模型填。
class FlakyVisionLlm implements LlmPort {
  int calls = 0;
  final List<String?> models = [];
  FlakyVisionLlm();

  @override
  Future<LlmReply> chat(
    List<LlmMessage> messages, {
    bool vision = false,
    double temperature = 0.3,
    int maxTokens = 1600,
    Duration timeout = const Duration(seconds: 90),
    String? modelOverride,
  }) async {
    calls++;
    models.add(modelOverride);
    if (calls == 1) {
      throw const LlmError('接口出错（HTTP 500）：invalid_model',
          statusCode: 500, modelMissing: true);
    }
    return LlmReply(
        text: '{"stem":"237 + 158 = ?"}',
        totalTokens: 10,
        latencyMs: 100,
        model: modelOverride ?? '主模型');
  }
}

LlmReply _r(String text, {String model = 'fake-1'}) =>
    LlmReply(text: text, totalTokens: 100, latencyMs: 500, model: model);

String _good(String answer, String equation) => '''
{"steps":[
 {"title":"第一步：先算一共花了多少","detail":"把两次花的钱加在一起","math":"12+8"},
 {"title":"第二步：再算每人分多少","detail":"两个人平分，用总数除以 2","math":"20÷2"}],
 "answer":"$answer","unit":"元","equation":"$equation"}''';

String _oneStep() => '''
{"steps":[{"title":"直接算","detail":"20÷2","math":"20÷2"}],
 "answer":"10","unit":"元","equation":"(12+8)/2"}''';

Future<void> main() async {
  // ── 1. 验算器 ──────────────────────────────────────
  ck('算式 (12+8)/2', ExprEval.eval('(12+8)/2') == Rational.fromInt(10));
  ck('算式优先级 2+3*4', ExprEval.eval('2+3*4') == Rational.fromInt(14));
  ck('全角符号 3.5×4', ExprEval.eval('3.5×4') == Rational.fromInt(14));
  ck('全角除号 7÷2', ExprEval.eval('7÷2') == Rational.fromBig(BigInt.from(7), BigInt.from(2)));
  ck('非法（汉字）返回 null', ExprEval.eval('面积的一半') == null);
  ck('括号不匹配返回 null', ExprEval.eval('(1+2') == null);
  ck('除零返回 null', ExprEval.eval('5/0') == null);
  ck('容差比较 0.1+0.2 vs 0.3',
      ExprEval.matches(Rational.tryParse('0.3')!, Rational.tryParse('0.30')!));

  // 模型写验算式时几乎必然带上 "= 答案"（真机实测三道全带）。
  // 早先遇到等号直接判非法 → 每题白打回重做一次，耗时翻倍。
  ck('带等号的验算式 237+158=395',
      ExprEval.eval('237 + 158 = 395') == Rational.fromInt(395));
  ck('带等号的应用题 12-3-4=5', ExprEval.eval('12 - 3 - 4 = 5') == Rational.fromInt(5));
  ck('全角等号 12－3＝9', ExprEval.eval('12－3＝9') == Rational.fromInt(9));
  ck('等号两边自相矛盾 → null（不是"算不出来"，是这道算式错了）',
      ExprEval.eval('1 + 1 = 3') == null);
  ck('等号右边不是数字 → null', ExprEval.eval('1 + 1 = 对') == null);
  ck('两个等号 → null（不猜）', ExprEval.eval('1+2=3=3') == null);
  ck('只有等号左边为空 → null', ExprEval.eval('= 5') == null);

  // ── 2. 讲解 Agent：正常路径 ────────────────────────
  var fake = FakeLlm([_r(_good('10', '(12+8)/2'))]);
  var r = await KidSolver(fake).solve('小明买笔花 12 元，买本子花 8 元，两人平摊各付多少？');
  ck('正常：两步 + 验算一致',
      r.steps.length == 2 && r.complete && r.verifyState == VerifyState.exact && r.attempts == 1);
  ck('正常：答案与单位', r.answer == '10' && r.unit == '元');

  // 模型顺手把答案写进验算式（"(12+8)/2=10"）：应当一次通过。
  // 真机实测三道题全都因为等号被判非法、白打回一次（5 s → 10 s），故单列一条。
  fake = FakeLlm([_r(_good('10', '(12+8)/2=10'))]);
  r = await KidSolver(fake).solve('小明买笔花 12 元，买本子花 8 元，两人平摊各付多少？');
  ck('验算式带等号也一次通过（不白打回重做）',
      r.verifyState == VerifyState.exact && r.attempts == 1 && r.complete,
      'state=${r.verifyState} attempts=${r.attempts}');

  // ── 3. 只讲一步 → 必须打回重做 ────────────────────
  fake = FakeLlm([_r(_oneStep()), _r(_good('10', '(12+8)/2'))]);
  r = await KidSolver(fake).solve('同一道题');
  ck('只讲一步 → 打回重做一次', r.attempts == 2, 'attempts=${r.attempts}');
  ck('重做后讲完整', r.complete && r.steps.length == 2);
  ck('打回时把原因传给了模型',
      fake.seen.length == 2 && fake.seen[1].contains('至少要 2 步'), fake.seen.last);

  // ── 4. 答案与自己的算式不符 → 打回重做 ────────────
  fake = FakeLlm([_r(_good('9', '(12+8)/2')), _r(_good('10', '(12+8)/2'))]);
  r = await KidSolver(fake).solve('同一道题');
  ck('答案不符 → 重试并修正', r.attempts == 2 && r.verifyState == VerifyState.exact);
  ck('重做提示里带上了矛盾点', fake.seen[1].contains('不一致'), fake.seen[1]);

  // ── 5. 两次都不符 → 亮红牌（绝不冒充正确）─────────
  fake = FakeLlm([_r(_good('9', '(12+8)/2')), _r(_good('9', '(12+8)/2'))]);
  r = await KidSolver(fake).solve('同一道题');
  ck('两次不符 → mismatch', r.verifyState == VerifyState.mismatch);

  // ── 6. 没给验算式 → 必须是"未能验算"，不能是已验算 ──
  fake = FakeLlm([_r(_good('10', ''))]);
  r = await KidSolver(fake).solve('一道应用题，写不成一条算式');
  ck('无验算式 → unverifiable（不是 exact）',
      r.verifyState == VerifyState.unverifiable && r.answer == '10',
      '实际=${r.verifyState.name}');
  ck('无验算式时不算"打回理由"（只重做一次也不该无限重试）', r.attempts == 1);

  // ── 7. 模型不守 JSON 约定 → 不算讲完，但也不能崩 ──
  // 注意：兜底成一步会被判"不完整"，所以同样会打回重做一次（这是要的行为）
  fake = FakeLlm([
    _r('先把 12 和 8 加起来等于 20，再除以 2 等于 10 元。'),
    _r('再把话说一遍：先加后除，得 10 元。'),
  ]);
  r = await KidSolver(fake).solve('题');
  ck('非 JSON：兜底成一步且标不完整',
      r.steps.length == 1 && !r.complete && r.verifyState == VerifyState.unverifiable);
  ck('非 JSON：不抛异常（有兜底内容）', r.steps.first.detail.isNotEmpty);
  ck('非 JSON：也会打回重做一次', r.attempts == 2);

  // ── 8. 网络/鉴权失败要能抛出来给 UI 提示 ──────────
  var threw = false;
  try {
    await KidSolver(FakeLlm([])).solve('题');
  } catch (e) {
    threw = e is LlmError;
  }
  ck('模型报错时向上抛出（UI 才能提示）', threw);

  // ── 9. 拍照识别 ────────────────────────────────────
  fake = FakeLlm([_r('{"stem":"一个长方形的长是 8 cm，宽是 5 cm，面积是多少？","notes":"配图为长方形"}')]);
  var o = await PhotoReader(fake).read('BASE64');
  ck('识别：取出题干', o.stem.contains('长方形') && o.stem.contains('8 cm'));
  ck('识别：说明也带回来', o.notes == '配图为长方形');
  fake = FakeLlm([_r('这是一张长方形的图，长 8 宽 5。')]);
  o = await PhotoReader(fake).read('BASE64');
  ck('识别：模型不守 JSON 也能兜底出文本', o.stem.isNotEmpty);
  ck('识别：正常情况用配置里的主模型（不传 override）', fake.models.last == null);

  // 2026-10-17 家长反馈"只能出现一道题，不太合理"：一张照片上往往好几道题，
  // 现在一次全认回来。这里钉住多题解析 + 旧格式兼容 + 说明合并。
  fake = FakeLlm([
    _r('''{"items":[
      {"stem":"1. 237 + 158 = ?","notes":"第1题清楚"},
      {"stem":"2. 一个长方形长 8 厘米，宽 5 厘米，周长是多少？","notes":"配图为长方形"},
      {"stem":"3. 用竖式算一算：54 ÷ 7 =","notes":""}]}'''),
  ]);
  o = await PhotoReader(fake).read('BASE64');
  ck('识别：一张照片认回多道题', o.count == 3, '实际 ${o.count} 道');
  ck('识别：多题按顺序保留', o.items[0].contains('237') && o.items[2].contains('54 ÷ 7'),
      o.items.join(' | '));
  ck('识别：第一道题仍是 stem（老调用方不受影响）', o.stem.contains('237'));
  ck('识别：各题的说明合并到一起', o.notes != null && o.notes!.contains('配图为长方形'),
      '${o.notes}');

  // 旧格式（单个 stem 字段）也要认 —— 模型不会立刻改口
  fake = FakeLlm([_r('{"stem":"377 - 98 = ?","notes":""}')]);
  o = await PhotoReader(fake).read('BASE64');
  ck('识别：旧的单题格式照样解析', o.count == 1 && o.stem.contains('377'),
      'count=${o.count} stem=${o.stem}');

  // 模型给了一堆文字没给 JSON：整段当一道题，让家长自己改
  fake = FakeLlm([_r('图上写着：三角形的底是 6 厘米，高是 4 厘米。')]);
  o = await PhotoReader(fake).read('BASE64');
  ck('识别：没给 JSON 时整段当一道题', o.count == 1 && o.stem.contains('三角形'));

  // items 是空的 / 全没 stem：不能返回 0 道题还不吭声
  fake = FakeLlm([_r('{"items":[]}')]);
  o = await PhotoReader(fake).read('BASE64');
  ck('识别：items 为空时不静默返回 0 道', o.count >= 1, 'count=${o.count}');

  // 识图降级：聚合站里 gpt-image-2-token 这种"只能画图"的模型会报 invalid_model，
  // 这时应该自动换备用模型再来一次，而不是让用户以为拍照坏了。
  final flaky = FlakyVisionLlm();
  o = await PhotoReader(flaky, fallbackModel: 'qwen3-vl-plus').read('BASE64');
  ck('识图：主模型走不了 chat 时自动换备胎',
      o.stem == '237 + 158 = ?' && flaky.calls == 2 && flaky.models.last == 'qwen3-vl-plus',
      'calls=${flaky.calls} models=${flaky.models}');
  ck('识图：降级后报告的是实际用的模型', o.model == 'qwen3-vl-plus');

  final flaky2 = FlakyVisionLlm();
  threw = false;
  try {
    await PhotoReader(flaky2).read('BASE64');
  } catch (_) {
    threw = true;
  }
  ck('识图：没配备胎时照常报错（不静默吞掉）', threw && flaky2.calls == 1);

  // ── 10. 同类题 ─────────────────────────────────────
  final local = VariantAgent.localVariants('377-98=', 3);
  ck('本地出同类题', local != null && local!.length == 3 && local.every((e) => e.source == 'local'));
  ck('本地题答案正确（433−14=419 类）',
      local!.every((e) => ExprEval.eval(e.stem.replaceAll('=', '').replaceAll('−', '-')) ==
          Rational.tryParse(e.answer)),
      local.map((e) => '${e.stem} ${e.answer}').join(' | '));
  ck('本地不接复杂题（应用题交模型）',
      VariantAgent.localVariants('小明有 12 元，买笔花 8 元，还剩多少？', 3) == null);
  ck('除法不出循环小数',
      (VariantAgent.localVariants('9/2=', 3) ?? []).every(
          (e) => Rational.tryParse(e.answer)!.hasFiniteDecimal));

  fake = FakeLlm([
    _r('''{"items":[
      {"stem":"一根绳子长 20 米，剪去 5 米，还剩多少？","answer":"15","unit":"米","equation":"20-5"},
      {"stem":"一根绳子长 30 米，剪去 12 米，还剩多少？","answer":"18","unit":"米","equation":"30-12"},
      {"stem":"长 10 宽 6 的长方形面积","answer":"60","unit":"","equation":"10+6"}]}'''),
  ]);
  final agent = await VariantAgent(fake).generate('一根绳子长 15 米，剪去 6 米，还剩多少？', n: 3);
  ck('模型出题：通过的留下', agent.length == 2, '实际 ${agent.length}');
  ck('模型出题：答案与算式不符的被丢弃', agent.every((e) => e.stem.contains('绳子')));
  ck('模型出题：来源标 agent', agent.every((e) => e.source == 'agent'));

  // 模型完全失败时不应该崩，返回空列表（UI 会提示）
  threw = false;
  try {
    await VariantAgent(FakeLlm([])).generate('应用题', n: 2);
  } catch (_) {
    threw = true;
  }
  ck('模型失败时把异常交给调用方（UI 提示而不是静默空列表）', threw);

  // ── 11. 配置 ───────────────────────────────────────
  final cfg = AiConfig.fallback.copyWith(
      provider: 'custom',
      baseUrl: 'https://my.proxy.example/v1',
      apiKey: 'sk-x',
      chatModel: 'my-model',
      visionModel: 'my-vl',
      visionBaseUrl: 'https://my.proxy.example/v1');
  final back = AiConfig.fromJson(cfg.toJson());
  ck('自定义 baseUrl 能存住（能填地址才叫自定义）',
      back.provider == 'custom' &&
          back.baseUrl == 'https://my.proxy.example/v1' &&
          back.visionBaseUrl == 'https://my.proxy.example/v1');
  ck('配置就绪判断', back.chatReady && back.visionReady);
  final noVision = AiConfig.fallback.copyWith(apiKey: 'sk-x', visionModel: '');
  ck('没填识别模型 → visionReady=false', !noVision.visionReady);
  ck('识别 key 留空时复用主 key',
      AiConfig.fallback.copyWith(apiKey: 'sk-main').effectiveVisionKey == 'sk-main');

  // 默认那一套必须"填一处就能用"：识别地址留空即复用解题地址。
  ck('默认配置：识别地址留空时复用解题地址（一家搞定）',
      AiConfig.fallback.visionBaseUrl.isEmpty &&
          AiConfig.fallback.effectiveVisionBaseUrl == AiConfig.fallback.baseUrl);
  ck('默认配置：带备胎识别模型', AiConfig.fallback.visionFallbackModel.isNotEmpty);
  ck('备胎模型能存住',
      AiConfig.fromJson(AiConfig.fallback.toJson()).visionFallbackModel ==
          AiConfig.fallback.visionFallbackModel);
  // 旧断言是"默认配置自带 key 开箱即用"。这条契约已**主动推翻**：
  // 仓库公开，源码里写死 key 等于把额度挂在路灯上。
  // 现在 key 走编译期注入（`String.fromEnvironment`），源码必须干干净净。
  ck('源码不含明文 key（防止有人手滑把 key 写死回来）', !AiConfig.fallback.apiKey.contains('sk-'));
  ck('模型名仍然预置（开箱只是差一个 key，不是全空）',
      AiConfig.fallback.chatModel.isNotEmpty && AiConfig.fallback.baseUrl.isNotEmpty);
  ck('未注入 key 时判定为未就绪（不静默发出真实请求）', !AiConfig.fallback.chatReady);
  ck('注入 key 后即可用（同一份配置只差这一个常量）', () {
    final injected = AiConfig.fallback.copyWith(apiKey: 'sk-unit-test-only');
    return injected.chatReady && injected.visionReady;
  }());

  // ── 12. 运行记录 ───────────────────────────────────
  final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}ai_log_test.jsonl');
  if (await tmp.exists()) await tmp.delete();
  final log = ActivityLog(tmp);
  await log.load();
  await log.record('ocr', detail: '识别成功', latencyMs: 1200, model: 'glm-4v-flash', tokens: 900);
  await log.record('solve', detail: '讲解 3 步', latencyMs: 800, model: 'deepseek-chat', tokens: 500);
  await log.record('solve', detail: '超时', ok: false, latencyMs: 30000);
  final st = log.stats();
  ck('统计：总数/失败/平均耗时',
      st.total == 3 && st.failed == 1 && st.avgMs == (1200 + 800 + 30000) ~/ 3,
      'total=${st.total} failed=${st.failed} avg=${st.avgMs}');
  ck('按类型筛选', log.ofType('solve').length == 2 && log.ofType('ocr').length == 1);
  final reloaded = ActivityLog(tmp);
  await reloaded.load();
  ck('记录能持久化并读回', reloaded.stats().total == 3);
  await log.clear();
  final cleared = ActivityLog(tmp);
  await cleared.load();
  ck('清空生效', cleared.events.isEmpty);
  await tmp.delete();

  print('\n通过 $_pass 条，失败 $_fail 条');
  if (_fail > 0) exit(1);
}
