/// AI 设置：填自己的 key、选供应商与模型、测连通性。
///
/// 「不填也能用」是这个页面的设计前提：整个 App 的本地能力（出题、判分、
/// 复习、导出）不依赖任何外部服务，AI 只是拍照识题与讲解这两块的增强。
library;

import 'package:flutter/material.dart';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/llm.dart';

import '../state.dart';

class AiSettings extends StatefulWidget {
  final AppState state;
  const AiSettings({super.key, required this.state});

  @override
  State<AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<AiSettings> {
  late final TextEditingController _key;
  late final TextEditingController _chatModel;
  late final TextEditingController _visionModel;
  late final TextEditingController _visionKey;
  late final TextEditingController _baseUrl;
  late final TextEditingController _visionBaseUrl;
  late String _provider;
  String? _testResult;
  bool _testing = false;
  bool _testAllOk = false;

  @override
  void initState() {
    super.initState();
    final c = widget.state.aiConfig;
    _provider = c.provider;
    _key = TextEditingController(text: c.apiKey);
    _chatModel = TextEditingController(text: c.chatModel);
    _visionModel = TextEditingController(text: c.visionModel);
    _visionKey = TextEditingController(text: c.visionApiKey);
    _baseUrl = TextEditingController(text: c.baseUrl);
    _visionBaseUrl = TextEditingController(text: c.visionBaseUrl);
  }

  @override
  void dispose() {
    _key.dispose();
    _chatModel.dispose();
    _visionModel.dispose();
    _visionKey.dispose();
    _baseUrl.dispose();
    _visionBaseUrl.dispose();
    super.dispose();
  }

  void _applyPreset(String p) {
    final preset = AiConfig.presets[p];
    if (preset == null) return;
    setState(() {
      _provider = p;
      // 预设带地址就连地址一起填；自定义模式地址留给用户改
      if (preset.baseUrl.isNotEmpty) {
        _baseUrl.text = preset.baseUrl;
        _chatModel.text = preset.chatModel;
      }
      if (preset.visionModel.isNotEmpty) {
        _visionModel.text = preset.visionModel;
        _visionBaseUrl.text = preset.baseUrl; // 同一家时复用地址
      }
    });
  }

  /// 地址一律以输入框为准 —— 预设只是帮用户填好，不是写死的。
  /// （之前自定义模式根本没地方填地址，等于这个功能不存在。）
  AiConfig _collect() => widget.state.aiConfig.copyWith(
        provider: _provider,
        baseUrl: _baseUrl.text.trim(),
        apiKey: _key.text.trim(),
        chatModel: _chatModel.text.trim(),
        visionModel: _visionModel.text.trim(),
        visionBaseUrl: _visionBaseUrl.text.trim(),
        visionApiKey: _visionKey.text.trim(),
      );

  Future<void> _save() async {
    await widget.state.saveAiConfig(_collect());
    if (!mounted) return;
    setState(() => _testResult = '已保存在本机（key 不会上传）');
  }

  /// 真连一次。**两个模型都测**：只测文字的话，识别那一路配错了照样拍照失败。
  Future<void> _test() async {
    final cfg = _collect();
    if (cfg.apiKey.isEmpty) {
      setState(() => _testResult = '先填 key 再测');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final lines = <String>[];
    var allOk = true;

    // ① 文字模型
    try {
      // token 预算要给足：deepseek-v4-flash 这类**推理模型**会先输出一段
      // 思维链（reasoning_content），再给正式回复。只给 16 的话思考还没
      // 结束就被截断，content 会是空字符串 —— 测试必然报失败（实测复现过）。
      final r = await LlmClient(cfg)
          .chat([const LlmMessage('user', '回复两个字：正常')], maxTokens: 512);
      lines.add('✅ 解题模型 ${r.model}：${r.latencyMs} ms，回复"${r.text.trim()}"');
      await widget.state.activityLog?.record('solve',
          detail: '连通性测试（解题模型）通过', latencyMs: r.latencyMs, model: r.model,
          tokens: r.totalTokens);
    } catch (e) {
      allOk = false;
      lines.add('❌ 解题模型：$e');
      await widget.state.activityLog?.record('solve', detail: '解题模型连通性测试失败：$e', ok: false);
    }

    // ② 识别模型（没填就明确告诉用户拍照用不了）
    if (cfg.visionModel.isEmpty) {
      lines.add('⚠ 没填识别模型 —— 拍照识题不可用（解题不受影响）');
      allOk = false;
    } else {
      try {
        final r = await LlmClient(cfg).chat(
            [const LlmMessage('user', '回复两个字：正常')],
            vision: true,
            maxTokens: 512);
        lines.add('✅ 识别模型 ${r.model}：${r.latencyMs} ms');
        await widget.state.activityLog?.record('ocr',
            detail: '连通性测试（识别模型）通过', latencyMs: r.latencyMs, model: r.model,
            tokens: r.totalTokens);
      } catch (e) {
        allOk = false;
        var msg = '❌ 识别模型：$e';
        // 聚合站常见坑：模型名列表里有，但它其实是画图模型，chat 接口根本不接受。
        if (e is LlmError && e.modelMissing) {
          msg = '$msg\n→ 这个模型走不了对话接口（多半是画图模型），换成 qwen3-vl-plus 试试';
        }
        lines.add(msg);
        await widget.state.activityLog?.record('ocr', detail: '识别模型连通性测试失败：$e', ok: false);
      }
    }

    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = lines.join('\n');
      _testAllOk = allOk;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = AiConfig.presets[_provider]?.keyHint ?? '';
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('供应商', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _provider,
            isExpanded: true,
            decoration: _dec(),
            style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
            items: [
              for (final e in AiConfig.presets.entries)
                DropdownMenuItem<String>(value: e.key, child: Text(e.value.label)),
            ],
            onChanged: (v) => v == null ? null : _applyPreset(v),
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(hint, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          ],
          const SizedBox(height: 12),
          _field('接口地址 baseUrl', _baseUrl, hint: 'https://api.deepseek.com/v1'),
          const SizedBox(height: 10),
          _field('API key（解题用）', _key, obscure: true, hint: 'sk-…'),
          const SizedBox(height: 10),
          _field('文字模型名', _chatModel, hint: 'deepseek-v4-flash / glm-4-flash / qwen-plus'),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          const Text('拍照识别（默认与解题同一家，地址留空即复用上面）',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _field('识别接口地址（留空 = 用上面的）', _visionBaseUrl,
              hint: 'https://api.agicto.cn/v1'),
          const SizedBox(height: 10),
          _field('识别模型名', _visionModel, hint: 'deepseek-v4-flash / qwen3-vl-plus'),
          const SizedBox(height: 4),
          Text(
              '识别不出时会自动换备用模型 ${widget.state.aiConfig.visionFallbackModel.isEmpty ? "（未设）" : widget.state.aiConfig.visionFallbackModel} 再试一次',
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          const SizedBox(height: 10),
          _field('识别模型的 key（同一家则留空，自动复用上面的 key）', _visionKey, obscure: true,
              hint: '可留空'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_tethering, size: 17),
                  label: const Text('测试连接', style: TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined, size: 17),
                  label: const Text('保存', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: _testResult!.startsWith('✅')
                    ? const Color(0xFFF0FDF4)
                    : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Text(_testResult!,
                  style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: _testAllOk ? const Color(0xFF166534) : const Color(0xFF334155))),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _dec() => InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );

  Widget _field(String label, TextEditingController c,
          {bool obscure = false, String? hint}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
          const SizedBox(height: 4),
          TextField(
            controller: c,
            obscureText: obscure,
            style: const TextStyle(fontSize: 13),
            decoration: _dec().copyWith(hintText: hint, hintStyle: const TextStyle(fontSize: 11.5)),
          ),
        ],
      );
}
