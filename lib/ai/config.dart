/// AI 供应商配置。
///
/// 设计要点：
/// - 主流中文供应商全部走 **OpenAI 兼容协议**（/chat/completions），
///   一个客户端通吃，切供应商只换 baseUrl + key + 模型名。
/// - 「解题」和「识别」允许配两家（各有各的 key）：有的模型只认字不认图。
/// - [visionBaseUrl] 留空表示与解题同一家，复用 [baseUrl] 与主 key ——
///   聚合站（如 agicto）就是这种情况，只填一处即可。
/// - [visionFallbackModel]：聚合站的模型可用性会变（实测同名模型有的只有
///   图像生成能力、chat 接口直接 invalid_model），所以识别留一个备用模型，
///   主模型报"模型不存在/不支持"时自动换它再试一次。
/// - key 的来路见 [builtInApiKey]：**源码里永远不出现明文 key**，
///   运行时优先用 App 私有目录里的 ai_config.json（设置页填的），
///   否则用编译期注入的 key，都不给就让用户在设置页填。
/// - 铁律不变：模型只负责讲解与出题，**答案必须过本地验算**（expr.dart）。
/// 供应商预设（用 typedef 而不是内联 record 类型：内联写法在泛型实参里不通）。
typedef AiPreset = ({
  String label,
  String baseUrl,
  String chatModel,
  String visionModel,
  String keyHint,
});

/// 编译期注入的 API key（**唯一的**"源码自带"通道）。
///
/// 为什么不放源码：本仓库是公开的，写死一个 key 等于把额度挂在路灯上。
/// 为什么不用 `dart:io` 读文件：`fromEnvironment` 是**编译期常量**，
/// 打进 APK 后就冻住了，既不会在运行时被 dump，也不占 IO；
/// 更重要的是它让"从源码 clone 出来"这件事天然是干净的。
///
/// 本机用法：见根目录 `.env.example`，
/// 复制成 `.env` 填上自己的 key，然后跑下面任一条命令都会自动带上：
/// - `dart run --dart-define-file=.env bin/serve.dart`
/// - `flutter run --dart-define-file=.env`（App）
/// - `python app/tool/build_apk.py`（构建脚本已自动挂上 `--dart-define-file`）
///
/// 拿不到就返回空串 —— 此时 App 走设置页让读者自己填，功能不受影响。
const String builtInApiKey =
    String.fromEnvironment('MATH_COACH_API_KEY', defaultValue: '');

class AiConfig {
  final String provider; // deepseek / zhipu / dashscope / custom
  final String baseUrl;  // 文字模型根地址，形如 https://api.deepseek.com/v1
  final String apiKey;
  final String chatModel;   // 文字解题/出题
  final String visionModel; // 拍照识别（空 = 未启用拍照识别）

  /// 识别模型的根地址与 key —— 识别可与文字不同家。
  /// [visionBaseUrl] 为空表示与解题同一家（复用 [baseUrl]）。
  final String visionBaseUrl;
  final String visionApiKey; // 空 = 复用主 key（同一家时正是如此）

  /// 识别模型的备胎：主模型不可用时自动顶上（见 ocr.dart）。
  final String visionFallbackModel;

  const AiConfig({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.chatModel,
    required this.visionModel,
    this.visionBaseUrl = '',
    this.visionApiKey = '',
    this.visionFallbackModel = '',
  });

  static const presets = <String, AiPreset>{
    'agicto': (
      label: 'Agicto 聚合（默认，文字+识图一家）',
      baseUrl: 'https://api.agicto.cn/v1',
      chatModel: 'deepseek-v4-flash',
      visionModel: 'deepseek-v4-flash',
      keyHint: '已预置，开箱即用；也可换成自己的 agicto key',
    ),
    'deepseek': (
      label: 'DeepSeek（文字解题）',
      baseUrl: 'https://api.deepseek.com/v1',
      chatModel: 'deepseek-chat',
      visionModel: '',
      keyHint: 'platform.deepseek.com 申请，sk- 开头',
    ),
    'zhipu': (
      label: '智谱 GLM（识别+解题一家搞定）',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      chatModel: 'glm-4-flash',
      visionModel: 'glm-4v-flash',
      keyHint: 'bigmodel.cn 申请，免费模型直接可用',
    ),
    'dashscope': (
      label: '阿里通义千问',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      chatModel: 'qwen-plus',
      visionModel: 'qwen-vl-plus',
      keyHint: '阿里云百炼申请，sk- 开头',
    ),
    'custom': (
      label: '自定义（OpenAI 兼容）',
      baseUrl: '',
      chatModel: '',
      visionModel: '',
      keyHint: '填 baseUrl / 模型名 / key',
    ),
  };

  /// 默认配置：Agicto 聚合站 + DeepSeek V4。
  ///
  /// 实测（2026-10-16，本机真实联网）：
  /// - `deepseek-v4-flash` 文字解题 2.7 s，讲解能稳定分出 5 步；
  /// - 同一个模型**能收图片**，两张测试题图 OCR 全对（2.7 s / 3.1 s），
  ///   所以解题与识图不必分两家，填一处就行；
  /// - 备胎 `qwen3-vl-plus` 同样可用（1.6~1.9 s，OCR 全对）。
  ///
  /// 这里的 key 走[builtInApiKey]注入（编译期），源码里不会出现明文。
  /// 「装完就能用」靠本地 `.env` 实现 —— 见仓库根 `.env.example`。
  /// 用户在「设置」里换成自己的 key 即可覆盖。
  static const AiConfig fallback = AiConfig(
    provider: 'agicto',
    baseUrl: 'https://api.agicto.cn/v1',
    apiKey: builtInApiKey,
    chatModel: 'deepseek-v4-flash',
    visionModel: 'deepseek-v4-flash',
    visionFallbackModel: 'qwen3-vl-plus',
  );

  String get effectiveVisionBaseUrl =>
      visionBaseUrl.isNotEmpty ? visionBaseUrl : baseUrl;
  String get effectiveVisionKey => visionApiKey.isNotEmpty ? visionApiKey : apiKey;

  bool get chatReady =>
      apiKey.isNotEmpty && chatModel.isNotEmpty && baseUrl.isNotEmpty;
  bool get visionReady => effectiveVisionKey.isNotEmpty && visionModel.isNotEmpty;

  AiConfig copyWith({
    String? provider,
    String? baseUrl,
    String? apiKey,
    String? chatModel,
    String? visionModel,
    String? visionBaseUrl,
    String? visionApiKey,
    String? visionFallbackModel,
  }) =>
      AiConfig(
        provider: provider ?? this.provider,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        chatModel: chatModel ?? this.chatModel,
        visionModel: visionModel ?? this.visionModel,
        visionBaseUrl: visionBaseUrl ?? this.visionBaseUrl,
        visionApiKey: visionApiKey ?? this.visionApiKey,
        visionFallbackModel: visionFallbackModel ?? this.visionFallbackModel,
      );

  Map<String, Object?> toJson() => {
        'provider': provider,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'chatModel': chatModel,
        'visionModel': visionModel,
        'visionBaseUrl': visionBaseUrl,
        'visionApiKey': visionApiKey,
        'visionFallbackModel': visionFallbackModel,
      };

  static AiConfig fromJson(Map<String, Object?> j) => AiConfig(
        provider: (j['provider'] as String?) ?? fallback.provider,
        baseUrl: (j['baseUrl'] as String?) ?? fallback.baseUrl,
        // key 给空字符串是"用户主动清空"，不要再塞回默认 key。
        apiKey: (j['apiKey'] as String?) ?? fallback.apiKey,
        chatModel: (j['chatModel'] as String?) ?? fallback.chatModel,
        visionModel: (j['visionModel'] as String?) ?? fallback.visionModel,
        visionBaseUrl:
            (j['visionBaseUrl'] as String?) ?? fallback.visionBaseUrl,
        visionApiKey: (j['visionApiKey'] as String?) ?? '',
        visionFallbackModel:
            (j['visionFallbackModel'] as String?) ?? fallback.visionFallbackModel,
      );
}
