/// OpenAI 兼容的聊天补全客户端（DeepSeek / 智谱 / 通义兼容模式通用）。
///
/// 只用 dart:io 的 HttpClient，不引任何三方包 —— 这个项目的依赖纪律：
/// 内核零三方依赖，App 也是。图片输入走 base64 data URL（视觉模型标准格式）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

class LlmMessage {
  final String role; // system / user / assistant
  final String text;
  final String? imageBase64; // jpeg base64，非空时本条带图
  const LlmMessage(this.role, this.text, {this.imageBase64});
}

class LlmReply {
  final String text;
  final int totalTokens;
  final int latencyMs;
  final String model;
  const LlmReply({
    required this.text,
    required this.totalTokens,
    required this.latencyMs,
    required this.model,
  });
}

class LlmError implements Exception {
  final String message;
  final int? statusCode;

  /// 模型不存在 / 这个模型不走 chat 接口。
  /// 聚合站很常见（实测：`gpt-image-2-token` 只能画图，chat 直接 invalid_model），
  /// 上层可据此换备用模型再试一次，而不是让用户对着报错发呆。
  final bool modelMissing;

  const LlmError(this.message, {this.statusCode, this.modelMissing = false});
  @override
  String toString() => statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// 模型调用端口 —— 抽象出来是为了**能测**：
/// 讲解/识别/出题三处逻辑不该依赖"真的联网"，
/// 测试时注入 FakeLlm 就能把"模型说了什么"的每种情况都跑一遍。
abstract class LlmPort {
  Future<LlmReply> chat(
    List<LlmMessage> messages, {
    bool vision,
    double temperature,
    int maxTokens,
    Duration timeout,
    String? modelOverride,
  });
}

class LlmClient implements LlmPort {
  final AiConfig cfg;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  LlmClient(this.cfg);

  /// [vision] 为 true 时走识别供应商（可能是另一家）。
  /// [modelOverride] 用于临时换模型（识别主模型不可用时降级）。
  @override
  Future<LlmReply> chat(
    List<LlmMessage> messages, {
    bool vision = false,
    double temperature = 0.3,
    int maxTokens = 1600,
    Duration timeout = const Duration(seconds: 90),
    String? modelOverride,
  }) async {
    final baseUrl = vision ? cfg.effectiveVisionBaseUrl : cfg.baseUrl;
    final key = vision ? cfg.effectiveVisionKey : cfg.apiKey;
    final model = modelOverride ?? (vision ? cfg.visionModel : cfg.chatModel);
    if (baseUrl.isEmpty || model.isEmpty || key.isEmpty) {
      throw const LlmError('AI 配置不完整：请到「设置」填写 key 和模型名');
    }

    final body = {
      'model': model,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'messages': [
        for (final m in messages)
          m.imageBase64 == null
              ? {'role': m.role, 'content': m.text}
              : {
                  'role': m.role,
                  'content': [
                    {'type': 'text', 'text': m.text},
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:image/jpeg;base64,${m.imageBase64}'},
                    },
                  ],
                },
      ],
    };

    final sw = Stopwatch()..start();
    try {
      final req = await _http
          .postUrl(Uri.parse('$baseUrl/chat/completions'))
          .timeout(timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join();
      sw.stop();

      if (res.statusCode != 200) {
        throw LlmError(_friendlyError(res.statusCode, text),
            statusCode: res.statusCode, modelMissing: _isModelMissing(text));
      }
      final j = jsonDecode(text) as Map<String, Object?>;
      final choices = (j['choices'] as List?) ?? const [];
      String content = '';
      String reasoning = '';
      String finish = '';
      if (choices.isNotEmpty) {
        final c0 = choices.first;
        if (c0 is Map) {
          finish = (c0['finish_reason'] ?? '').toString();
          final msg = c0['message'];
          if (msg is Map) {
            content = (msg['content'] ?? '').toString();
            // 推理模型（deepseek-v4-flash 这类）会先吐思维链再给正式回复。
            // 单独把它取出来：它是判断"是不是被 token 预算截断"的唯一依据。
            reasoning = (msg['reasoning_content'] ?? '').toString();
          }
        }
      }
      if (content.isEmpty) {
        // 推理模型（deepseek-v4-flash 这类）会先输出一段思维链，再给正式回复。
        // 预算被思维链吃光时 finish_reason=length、content 为空 ——
        // 这不是模型坏了，是给的钱不够。这里自动放大预算补一次，
        // 别让每个调用方各自去猜。（实测：测试连接原来只给 16，必然踩坑。）
        if (finish == 'length' && reasoning.isNotEmpty && maxTokens < 4000) {
          return chat(messages,
              vision: vision,
              temperature: temperature,
              maxTokens: maxTokens * 4,
              timeout: timeout,
              modelOverride: modelOverride);
        }
        // 已经放到很大还是空：如实说明病因，别假装成功
        if (finish == 'length' && reasoning.isNotEmpty) {
          throw LlmError(
            '模型的思考过程用完了 token 预算（max_tokens=$maxTokens），'
            '正式回复还没来得及输出。请把 max_tokens 调大，或换一个非推理模型。',
          );
        }
        if (finish == 'length') {
          throw LlmError('回复被截断（max_tokens=$maxTokens 太小），请调大后重试。');
        }
        throw const LlmError('模型返回了空内容');
      }
      final usage = j['usage'];
      final tokens =
          usage is Map ? ((usage['total_tokens'] ?? 0) as num).toInt() : 0;
      return LlmReply(
        text: content,
        totalTokens: tokens,
        latencyMs: sw.elapsedMilliseconds,
        model: model,
      );
    } on TimeoutException {
      throw const LlmError('请求超时（90 秒），请检查网络');
    } on SocketException catch (e) {
      throw LlmError('网络不可用：${e.message}');
    }
  }

  /// 把常见错误码翻译成人话，家长不是程序员。
  static String _friendlyError(int code, String body) {
    String detail = '';
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        detail = (j['error']['message'] ?? '').toString();
      }
    } catch (_) {}
    switch (code) {
      case 401:
        return 'API key 无效或过期（401）${_tail(detail)}';
      case 402:
        return '账户余额不足（402）${_tail(detail)}';
      case 429:
        return '请求太频繁或额度用完（429）${_tail(detail)}';
      default:
        return '接口出错（HTTP $code）${_tail(detail)}';
    }
  }

  /// 从错误体里认出「这个模型走不了 chat」——各家说法不统一，只能枚举。
  static bool _isModelMissing(String body) {
    final b = body.toLowerCase();
    for (final k in const [
      'invalid_model',
      'model_not_found',
      'model not exist',
      'does not exist',
      'no available',
      'unsupported model',
    ]) {
      if (b.contains(k)) return true;
    }
    return false;
  }

  static String _tail(String d) => d.isEmpty ? '' : '：${d.length > 120 ? d.substring(0, 120) : d}';
}
