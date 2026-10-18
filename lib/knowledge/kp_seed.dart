import 'kp.dart';

/// 知识点种子数据（人教版小学数学 1–6 年级）。
///
/// 说明一处必须交代的补全：原始《小学数学1-6年级知识点分类表》只给了
/// 「领域 + 单元/知识点 + 细粒度考点标签」，**没有学期字段**，
/// 但知识编码 MA-G3-S1-NA-03-02 里需要 S1/S2。
/// 这里按人教版教材目录补齐了学期与单元顺序；家长可在设置页手动增删纠正。
///
/// 编码规则：单元号在「年级 + 学期 + 领域」内按教材顺序编号，考点号在单元内编号。
class _SeedUnit {
  final int g;
  final int s;
  final String dom;
  final String unit;
  final List<String> tags;

  const _SeedUnit(this.g, this.s, this.dom, this.unit, this.tags);
}

const _seed = <_SeedUnit>[
  // ─────────────── 一年级 ───────────────
  _SeedUnit(1, 1, 'NA', '1–10 的认识与加减', ['数数', '比多少', '加减法含义', '0 的认识']),
  _SeedUnit(1, 1, 'NA', '11–20 各数的认识', ['数位（十位个位）', '数的组成', '20 以内不进位加']),
  _SeedUnit(1, 1, 'NA', '20 以内进位加法', ['凑十法', '加法交换']),
  _SeedUnit(1, 1, 'GS', '认识图形', ['长方形', '正方形', '三角形', '圆']),
  _SeedUnit(1, 2, 'NA', '20 以内退位减法', ['破十法', '想加算减']),
  _SeedUnit(1, 2, 'NA', '100 以内数的认识', ['数位顺序', '整十数加减', '比大小']),
  _SeedUnit(1, 2, 'NA', '100 以内加减法', ['不进位加', '进位加', '不退位减', '退位减', '连加连减']),
  _SeedUnit(1, 2, 'NA', '认识人民币', ['元角分', '换算', '简单购物']),
  _SeedUnit(1, 2, 'NA', '找规律', ['图形规律', '数字规律']),
  _SeedUnit(1, 2, 'GS', '分类与整理', ['按特征分类', '简单统计']),
  _SeedUnit(1, 2, 'IP', '摆一摆、想一想', ['数与图形操作']),

  // ─────────────── 二年级 ───────────────
  _SeedUnit(2, 1, 'GS', '长度单位', ['厘米', '米', '测量与估算']),
  _SeedUnit(2, 1, 'NA', '100 以内加减法（二）', ['笔算加', '笔算减', '混合运算']),
  _SeedUnit(2, 1, 'GS', '角的初步认识', ['直角', '锐角', '钝角']),
  _SeedUnit(2, 1, 'NA', '表内乘法', ['乘法口诀', '乘加乘减']),
  _SeedUnit(2, 1, 'GS', '观察物体', ['从不同方向观察']),
  _SeedUnit(2, 1, 'ET', '搭配（一）', ['简单排列与组合']),
  _SeedUnit(2, 2, 'SP', '数据收集整理', ['统计表', '简单投票统计']),
  _SeedUnit(2, 2, 'NA', '表内除法', ['平均分', '用口诀求商']),
  _SeedUnit(2, 2, 'GS', '图形的运动', ['轴对称', '平移', '旋转']),
  _SeedUnit(2, 2, 'NA', '混合运算', ['同级运算', '两级运算', '小括号']),
  _SeedUnit(2, 2, 'NA', '有余数的除法', ['余数比除数小', '解决周期问题']),
  _SeedUnit(2, 2, 'NA', '万以内数的认识', ['千以内数', '万以内数', '近似数']),

  // ─────────────── 三年级 ───────────────
  _SeedUnit(3, 1, 'NA', '时分秒', ['时间单位换算', '经过时间计算']),
  _SeedUnit(3, 1, 'NA', '万以内的加法和减法', ['笔算', '验算', '估算']),
  _SeedUnit(3, 1, 'NA', '测量', ['毫米分米千米', '吨千克克']),
  _SeedUnit(3, 1, 'NA', '多位数乘一位数', ['口算', '笔算（含进位）', '0 的乘法', '估算']),
  _SeedUnit(3, 1, 'GS', '长方形和正方形', ['周长的概念与计算']),
  _SeedUnit(3, 1, 'NA', '分数的初步认识', ['几分之一', '几分之几', '同分母加减']),
  _SeedUnit(3, 2, 'GS', '位置与方向', ['东南西北', '描述路线']),
  _SeedUnit(3, 2, 'NA', '除数是一位数的除法', ['口算', '笔算', '商中间末尾有 0', '验算']),
  _SeedUnit(3, 2, 'SP', '复式统计表', ['数据合并与比较']),
  _SeedUnit(3, 2, 'NA', '两位数乘两位数', ['口算', '笔算', '连乘解决问题']),
  _SeedUnit(3, 2, 'GS', '面积', ['面积单位', '长方形面积', '正方形面积']),
  _SeedUnit(3, 2, 'NA', '年月日', ['大月小月', '平年闰年', '24 时计时法']),
  _SeedUnit(3, 2, 'NA', '小数的初步认识', ['小数的意义', '一位小数加减']),
  _SeedUnit(3, 2, 'ET', '集合、搭配（二）', ['重叠问题', '排列组合']),

  // ─────────────── 四年级 ───────────────
  _SeedUnit(4, 1, 'NA', '大数的认识', ['亿以内数', '亿以上数', '读写', '改写', '近似数']),
  _SeedUnit(4, 1, 'NA', '公顷和平方千米', ['面积单位换算']),
  _SeedUnit(4, 1, 'GS', '角的度量', ['角的认识', '量角画角', '分类']),
  _SeedUnit(4, 1, 'NA', '三位数乘两位数', ['口算', '笔算', '积的变化规律']),
  _SeedUnit(4, 1, 'GS', '平行四边形和梯形', ['平行与垂直', '画高', '四边形关系']),
  _SeedUnit(4, 1, 'NA', '除数是两位数的除法', ['试商', '调商', '商的变化规律']),
  _SeedUnit(4, 2, 'NA', '四则运算', ['运算顺序', '0 的运算特性']),
  _SeedUnit(4, 2, 'GS', '观察物体（二）', ['从不同位置观察组合体']),
  _SeedUnit(4, 2, 'NA', '运算定律', ['加法交换结合律', '乘法交换结合律', '分配律', '简便计算']),
  _SeedUnit(4, 2, 'NA', '小数的意义和性质', ['小数意义', '小数点移动', '单位换算', '求近似数']),
  _SeedUnit(4, 2, 'GS', '三角形', ['特性', '分类', '内角和', '三边关系']),
  _SeedUnit(4, 2, 'NA', '小数的加法和减法', ['笔算', '混合运算']),
  _SeedUnit(4, 2, 'GS', '图形的运动（二）', ['轴对称', '平移']),
  _SeedUnit(4, 2, 'NA', '平均数与条形统计图', ['平均数意义与计算']),
  _SeedUnit(4, 2, 'ET', '优化、鸡兔同笼', ['沏茶问题', '烙饼问题', '假设法']),

  // ─────────────── 五年级 ───────────────
  _SeedUnit(5, 1, 'NA', '小数乘法', ['小数乘整数', '小数乘小数', '积的近似数', '运算定律']),
  _SeedUnit(5, 1, 'GS', '位置', ['用数对表示位置']),
  _SeedUnit(5, 1, 'NA', '小数除法', ['除数是整数', '除数是小数', '循环小数', '商的近似数']),
  _SeedUnit(5, 1, 'SP', '可能性', ['可能性大小', '随机现象']),
  _SeedUnit(5, 1, 'NA', '简易方程', ['用字母表示数', '等式的性质', '解方程', '列方程解应用题']),
  _SeedUnit(5, 1, 'GS', '多边形的面积', ['平行四边形面积', '三角形面积', '梯形面积', '组合图形面积']),
  _SeedUnit(5, 1, 'ET', '植树问题', ['间隔问题']),
  _SeedUnit(5, 2, 'GS', '观察物体（三）', ['三视图与拼搭']),
  _SeedUnit(5, 2, 'NA', '因数与倍数', ['因数倍数', '2/3/5 的倍数特征', '质数合数']),
  _SeedUnit(5, 2, 'GS', '长方体和正方体', ['正方体的认识', '表面积', '体积', '容积单位', '展开图']),
  _SeedUnit(5, 2, 'NA', '分数的意义和性质', ['分数意义', '真假分数', '约分通分', '分数与小数互化']),
  _SeedUnit(5, 2, 'GS', '图形的运动（三）', ['旋转']),
  _SeedUnit(5, 2, 'NA', '分数的加法和减法', ['同分母加减', '异分母加减', '分数加减混合']),
  _SeedUnit(5, 2, 'SP', '折线统计图', ['绘制与读图', '趋势判断']),
  _SeedUnit(5, 2, 'ET', '找次品', ['最优策略']),

  // ─────────────── 六年级 ───────────────
  _SeedUnit(6, 1, 'NA', '分数乘法', ['分数乘整数', '分数乘分数', '求一个数的几分之几']),
  _SeedUnit(6, 1, 'GS', '位置与方向（二）', ['角度与距离描述位置']),
  _SeedUnit(6, 1, 'NA', '分数除法', ['分数除法', '解决问题', '工程问题']),
  _SeedUnit(6, 1, 'NA', '比', ['比的意义', '化简比', '按比例分配']),
  _SeedUnit(6, 1, 'GS', '圆', ['圆的周长', '圆的面积', '圆环', '扇形']),
  _SeedUnit(6, 1, 'NA', '百分数', ['百分数意义', '与分数小数互化', '求百分率']),
  _SeedUnit(6, 1, 'SP', '扇形统计图', ['读图', '各部分占比']),
  _SeedUnit(6, 1, 'ET', '数与形', ['数与形规律']),
  _SeedUnit(6, 2, 'NA', '负数', ['正负数意义', '数轴上的表示']),
  _SeedUnit(6, 2, 'GS', '圆柱与圆锥', ['表面积', '体积', '等底等高关系']),
  _SeedUnit(6, 2, 'NA', '比例', ['比例的意义', '正反比例', '比例尺']),
  _SeedUnit(6, 2, 'ET', '鸽巢问题', ['抽屉原理']),
];

String _two(int v) => v.toString().padLeft(2, '0');

/// 生成全部叶子考点（带知识编码）。
List<KnowledgePoint> buildSeedKnowledgePoints() {
  final out = <KnowledgePoint>[];
  final unitCounter = <String, int>{};

  for (final u in _seed) {
    final key = '${u.g}|${u.s}|${u.dom}';
    final unitNo = (unitCounter[key] ?? 0) + 1;
    unitCounter[key] = unitNo;

    for (var i = 0; i < u.tags.length; i++) {
      final code = 'MA-G${u.g}-S${u.s}-${u.dom}-${_two(unitNo)}-${_two(i + 1)}';
      out.add(KnowledgePoint(
        code: code,
        grade: u.g,
        semester: u.s,
        domain: DomainCode.fromCode(u.dom) ?? DomainCode.na,
        unit: u.unit,
        name: u.tags[i],
      ));
    }
  }
  return out;
}

/// 生成单元层（用于 UI 折叠与组卷筛选）。
List<KnowledgeUnit> buildSeedUnits() {
  final out = <KnowledgeUnit>[];
  final unitCounter = <String, int>{};

  for (final u in _seed) {
    final key = '${u.g}|${u.s}|${u.dom}';
    final unitNo = (unitCounter[key] ?? 0) + 1;
    unitCounter[key] = unitNo;

    final pts = <KnowledgePoint>[];
    for (var i = 0; i < u.tags.length; i++) {
      pts.add(KnowledgePoint(
        code: 'MA-G${u.g}-S${u.s}-${u.dom}-${_two(unitNo)}-${_two(i + 1)}',
        grade: u.g,
        semester: u.s,
        domain: DomainCode.fromCode(u.dom) ?? DomainCode.na,
        unit: u.unit,
        name: u.tags[i],
      ));
    }
    out.add(KnowledgeUnit(
      grade: u.g,
      semester: u.s,
      domain: DomainCode.fromCode(u.dom) ?? DomainCode.na,
      unitNo: unitNo,
      name: u.unit,
      points: pts,
    ));
  }
  return out;
}
