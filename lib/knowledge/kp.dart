/// 知识点模型：科目 → 年级 → 学期 → 领域 → 单元 → 考点（三级归类）。
///
/// 编码格式（与《识题解析 JSON 输出规范》一致）：
///   MA-G3-S1-NA-03-02
///   │   │   │   │   │   └─ 考点号（单元内两位序号）
///   │   │   │   │   └───── 单元号（年级+学期+领域 内两位序号）
///   │   │   │   └───────── 领域码
///   │   │   └───────────── 学期 S1/S2
///   │   └───────────────── 年级 G1..G6
///   └───────────────────── 科目码 MA=数学
enum DomainCode {
  na('NA', '数与代数'),
  gs('GS', '图形与几何'),
  sp('SP', '统计与概率'),
  ip('IP', '综合与实践'),
  et('ET', '数学广角');

  const DomainCode(this.code, this.label);
  final String code;
  final String label;

  static DomainCode? fromCode(String? c) {
    if (c == null) return null;
    final u = c.toUpperCase();
    for (final d in values) {
      if (d.code == u) return d;
    }
    return null;
  }

  static DomainCode? fromLabel(String? label) {
    if (label == null) return null;
    for (final d in values) {
      if (d.label == label) return d;
    }
    // 容错：「数学广角（拓展思维）」这类带括号的写法
    for (final d in values) {
      if (label.contains(d.label)) return d;
    }
    return null;
  }
}

/// 叶子考点：一个可被题目直接命中的细粒度考点。
class KnowledgePoint {
  /// 形如 MA-G3-S1-NA-03-02；内置种子一定有码，家长自建的可能为空。
  final String code;

  final int grade; // 1..6
  final int semester; // 1 或 2
  final DomainCode domain;
  final String unit; // 单元名
  final String name; // 考点名（细粒度考点标签）
  final bool custom; // 是否家长手动补充

  const KnowledgePoint({
    required this.code,
    required this.grade,
    required this.semester,
    required this.domain,
    required this.unit,
    required this.name,
    this.custom = false,
  });

  String get domainLabel => domain.label;

  /// 「三年级上 · 数与代数 · 多位数乘一位数 · 两位数乘一位数（进位）」
  String get path => '${_gradeCn(grade)}${semester == 1 ? '上' : '下'} · ${domain.label} · $unit · $name';

  Map<String, Object?> toMap() => {
        'code': code,
        'grade': grade,
        'semester': semester,
        'domain': domain.code,
        'unit': unit,
        'name': name,
        'custom': custom ? 1 : 0,
      };

  static KnowledgePoint fromMap(Map<String, Object?> m) => KnowledgePoint(
        code: m['code'] as String,
        grade: m['grade'] as int,
        semester: m['semester'] as int,
        domain: DomainCode.fromCode(m['domain'] as String?) ?? DomainCode.na,
        unit: m['unit'] as String,
        name: m['name'] as String,
        custom: (m['custom'] as int? ?? 0) == 1,
      );

  @override
  String toString() => 'KP($code $name)';
}

String _gradeCn(int g) => ['一', '二', '三', '四', '五', '六'][(g - 1).clamp(0, 5)];

/// 单元（中间层，用于 UI 折叠与组卷筛选）。
class KnowledgeUnit {
  final int grade;
  final int semester;
  final DomainCode domain;
  final int unitNo;
  final String name;
  final List<KnowledgePoint> points;

  const KnowledgeUnit({
    required this.grade,
    required this.semester,
    required this.domain,
    required this.unitNo,
    required this.name,
    required this.points,
  });

  String get label => '第$unitNo单元 · $name';
}
