import 'kp.dart';
import 'kp_seed.dart';

/// 知识点索引：负责「模型输出的归类文本 → 知识编码」的落位。
///
/// 现实约束：模型给出的 knowledge_point 文字不可能每次都与种子表字面一致
/// （"两位数乘一位数（进位）" vs "两位数乘一位数"）。
/// 所以匹配必须分层：精确码 → 精确名 → 归一化包含 → 同年级单元名包含 → 放弃。
class KnowledgeIndex {
  final List<KnowledgePoint> points;
  final List<KnowledgeUnit> units;

  late final Map<String, KnowledgePoint> _byCode;
  late final Map<String, List<KnowledgePoint>> _byNormName;

  KnowledgeIndex({List<KnowledgePoint>? points, List<KnowledgeUnit>? units})
      : points = points ?? buildSeedKnowledgePoints(),
        units = units ?? buildSeedUnits() {
    _byCode = {for (final p in this.points) p.code: p};
    _byNormName = {};
    for (final p in this.points) {
      _byNormName.putIfAbsent(_norm(p.name), () => []).add(p);
    }
  }

  static String _norm(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[（）()【】\[\]\s、,，.。:：·・\-—_]'), '')
        .replaceAll('数学', '')
        // 「三角形的面积」vs「三角形面积」这类差一个"的"的写法必须视为同一名。
        // 曾因此把六年级的三角形面积题错标成一年级"认识图形·三角形"。
        .replaceAll('的', '');
  }

  KnowledgePoint? byCode(String? code) => code == null ? null : _byCode[code.toUpperCase()];

  /// 按考点名精确匹配（归一化后）。
  List<KnowledgePoint> byName(String name) => _byNormName[_norm(name)] ?? const [];

  /// 主入口：把模型输出的归类信息落到具体考点。
  ///
  /// 返回 null 表示没命中 —— 调用方应按规范置 knowledge_code 为空并 needs_review=true，
  /// 进入「待归类列表」由家长手动指定，绝不猜一个错的塞进去。
  MatchResult match({
    String? code,
    String? knowledgePoint,
    String? unit,
    String? domain,
    int? grade,
  }) {
    // 1) 给了码且能查到 —— 最可信
    if (code != null && code.isNotEmpty) {
      final p = byCode(code);
      if (p != null) return MatchResult(p, MatchLevel.exactCode);
    }

    // 2) 考点名命中。**年级优先于"名字更精确"**：
    //    曾按"唯一同名就直接返回"来写，结果五年级的长方形面积题
    //    只剩一个同名考点（一年级"认识图形·长方形"），标签直接掉到
    //    一上，家长看到的就是"五年级出一年级的题"。所以顺序是
    //    同年级精确名 > 同年级模糊名 > 年级差最小的候选。
    if (knowledgePoint != null && knowledgePoint.isNotEmpty) {
      final exact = byName(knowledgePoint);
      final fuzzy = _fuzzyByName(knowledgePoint);
      final sameExact =
          _narrow(exact, grade: grade, unit: unit, domain: domain, sameGradeOnly: true);
      if (sameExact != null) return MatchResult(sameExact, MatchLevel.exactName);
      final sameFuzzy =
          _narrow(fuzzy, grade: grade, unit: unit, domain: domain, sameGradeOnly: true);
      if (sameFuzzy != null) return MatchResult(sameFuzzy, MatchLevel.fuzzyName);
      // 同年级一个都没有：就近取（fuzzy 含 exact，不会漏）
      final near = _narrow(fuzzy, grade: grade, unit: unit, domain: domain);
      if (near != null) {
        final level = exact.contains(near) ? MatchLevel.exactName : MatchLevel.fuzzyName;
        return MatchResult(near, level);
      }
    }

    // 4) 退到单元级：至少把领域/单元定下来。
    //    模型经常给单元名而不是考点名（比如只说"小数乘法"），
    //    所以 knowledgePoint 也要拿去和单元名比一次。
    for (final raw in [unit, knowledgePoint]) {
      if (raw == null || raw.isEmpty) continue;
      final nu = _norm(raw);
      final hits = <KnowledgePoint>[];
      for (final p in points) {
        if (_norm(p.unit).contains(nu) || nu.contains(_norm(p.unit))) hits.add(p);
      }
      final narrowed = _narrow(hits, grade: grade, domain: domain);
      if (narrowed != null) return MatchResult(narrowed, MatchLevel.unitOnly);
    }

    return MatchResult(null, MatchLevel.none);
  }

  /// 归一化包含匹配：模型写"两位数乘一位数（进位）"，种子里有"笔算（含进位）"
  List<KnowledgePoint> _fuzzyByName(String knowledgePoint) {
    final nk = _norm(knowledgePoint);
    if (nk.isEmpty) return const [];
    final hits = <KnowledgePoint>[];
    for (final p in points) {
      final np = _norm(p.name);
      if (np.isEmpty) continue;
      if (np.contains(nk) || nk.contains(np)) hits.add(p);
    }
    return hits;
  }

  KnowledgePoint? _narrow(
    List<KnowledgePoint> cands, {
    int? grade,
    String? unit,
    String? domain,
    bool sameGradeOnly = false,
  }) {
    if (cands.isEmpty) return null;
    var list = cands;
    if (grade != null) {
      if (sameGradeOnly) {
        // 只认同年级：一个都没有就返回 null，让调用方去试模糊匹配，
        // 而不是把"名字对得上、年级差四年"的候选当正确答案。
        list = list.where((p) => p.grade == grade).toList();
        if (list.isEmpty) return null;
      } else {
        // 目标年级没有：就近取年级差最小的候选，而不是放弃过滤。
        // 否则六年级的题会落回唯一年级较早的候选（如一年级"认识图形"）。
        var best = 99;
        for (final p in list) {
          final d = (p.grade - grade).abs();
          if (d < best) best = d;
        }
        final near = list.where((p) => (p.grade - grade).abs() == best).toList();
        if (near.isNotEmpty) list = near;
      }
    }
    if (domain != null) {
      final d = DomainCode.fromLabel(domain) ?? DomainCode.fromCode(domain);
      if (d != null) {
        final g = list.where((p) => p.domain == d).toList();
        if (g.isNotEmpty) list = g;
      }
    }
    if (unit != null && unit.isNotEmpty) {
      final nu = _norm(unit);
      final g = list.where((p) => _norm(p.unit).contains(nu) || nu.contains(_norm(p.unit))).toList();
      if (g.isNotEmpty) list = g;
    }
    // 稳定排序保证同样输入永远得同样结果（避免重复归类跳来跳去）
    list = [...list]..sort((a, b) => a.code.compareTo(b.code));
    return list.first;
  }

  /// 供 UI 用：按年级取领域分组。
  Map<DomainCode, List<KnowledgeUnit>> unitsByGrade(int grade) {
    final m = <DomainCode, List<KnowledgeUnit>>{};
    for (final u in units) {
      if (u.grade != grade) continue;
      m.putIfAbsent(u.domain, () => []).add(u);
    }
    return m;
  }
}

enum MatchLevel {
  exactCode('精确编码'),
  exactName('精确考点名'),
  fuzzyName('模糊考点名'),
  unitOnly('仅单元'),
  none('未命中');

  const MatchLevel(this.label);
  final String label;
}

class MatchResult {
  final KnowledgePoint? point;
  final MatchLevel level;

  const MatchResult(this.point, this.level);

  bool get hit => point != null;

  /// 是否需要家长复核：模糊及以下都该提示一下。
  bool get needsReview =>
      level == MatchLevel.fuzzyName || level == MatchLevel.unitOnly || level == MatchLevel.none;
}
