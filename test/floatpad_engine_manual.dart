/// 浮窗演算板引擎的离线回归（用 dart run 跑，本机跑不了 dart test）。
///
/// 覆盖的是"家长敢不敢拿它验算作业"这一块：
/// 精确有理数、全角符号、带分数、百分号、优先级、循环小数、竖式挑选、错误提示。
/// 这些错了不会崩，只会**悄悄算错** —— 所以必须逐条断言。
library;

import 'package:math_coach/calc/expression.dart';
import 'package:math_coach/core/rational.dart';

int _pass = 0;
int _fail = 0;

void ok(String name, bool cond) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
    print('  [FAIL] $name');
  }
}

void main() {
  // ── 基本运算与精确性 ──────────────────────────────
  ok('1+2=3', evaluate('1+2').value == Rational(3));
  final floatSum = evaluate('0.1+0.2').value;
  ok('0.1+0.2 精确等于 0.3（不是 0.30000000000000004）',
      floatSum == Rational.fromBig(BigInt.parse('3'), BigInt.from(10)));
  ok('3/4+1/4=1', evaluate('3/4+1/4').value == Rational.one);
  ok('2又1/3+1/6=5/2', evaluate('2又1/3+1/6').value == Rational(5, 2));
  ok('小数显示 0.3 而非 0.3000…', decimalForm(floatSum).text == '0.3');
  ok('2.5-0.75=1.75', decimalForm(evaluate('2.5-0.75').value).text == '1.75');

  // ── 全角与异体符号 ────────────────────────────────
  ok('全角数字与＋', evaluate('３＋４').value == Rational(7));
  ok('×÷归一', evaluate('６×７÷２').value == Rational(21));
  ok('数学减号−', evaluate('１０−４').value == Rational(6));
  ok('千分位逗号忽略', evaluate('1,234+1').value == Rational(1235));

  // ── 百分号 ────────────────────────────────────────
  ok('50%×160=80', evaluate('50%×160').value == Rational(80));
  ok('25%+25%=50%', evaluate('25%+25%').value == Rational(1, 2));

  // ── 优先级 / 括号 / 幂 / 一元负号 ─────────────────
  ok('先乘除后加减：3+4×5=23', evaluate('3+4×5').value == Rational(23));
  ok('括号优先：(3+4)×5=35', evaluate('(3+4)×5').value == Rational(35));
  ok('幂右结合：2^3^2=512', evaluate('2^3^2').value == Rational(512));
  ok('负指数：2^-1=1/2', evaluate('2^-1').value == Rational(1, 2));
  ok('一元负号：-5+3=-2', evaluate('-5+3').value == Rational(-2));
  ok('嵌套括号：((2+3))×2=10', evaluate('((2+3))×2').value == Rational(10));

  // ── 循环小数 ──────────────────────────────────────
  final div7 = evaluate('58÷7');
  ok('58÷7 = 58/7', div7.value == Rational(58, 7));
  final f7 = decimalForm(div7.value);
  ok('58÷7 循环小数 8.285714…', f7.text == '8.285714…');
  ok('循环节 285714', f7.cycle == '285714');
  final f3 = decimalForm(evaluate('1÷3').value);
  ok('1÷3 = 0.33…（循环节重复两遍）', f3.text == '0.33…' && f3.cycle == '3');
  final f6 = decimalForm(evaluate('1÷6').value);
  ok('1÷6 = 0.166…（前导 1 不是循环节）', f6.text == '0.166…' && f6.cycle == '6');
  ok('整数不带小数点', decimalForm(Rational(5)).text == '5');

  // ── 分数与口语写法 ─────────────────────────────────
  ok('1/3+1/6=1/2（/ 恒为除号，分数靠除法算出来）', evaluate('1/3+1/6').value == Rational(1, 2));
  ok('2/3×3/4=1/2', evaluate('2/3×3/4').value == Rational(1, 2));
  ok('带分数单独成立：2又1/3=7/3', evaluate('2又1/3').value == Rational(7, 3));
  ok('几分之几：4分之3=3/4', evaluate('4分之3').value == Rational(3, 4));
  ok('隐式乘：2(3+4)=14', evaluate('2(3+4)').value == Rational(14));
  ok('百分号可挂在括号后：(1+2)%=3/100', evaluate('(1+2)%').value == Rational(3, 100));
  ok('尾随小数点：3. 当 3', evaluate('3.+1').value == Rational(4));
  ok('前导小数点：.5+.5=1', evaluate('.5+.5').value == Rational.one);

  // ── 竖式挑选 ──────────────────────────────────────
  final addR = evaluate('25+47');
  final vAdd = PadVertical.of(addR);
  ok('整数加法出竖式', vAdd != null && vAdd.layout != null && vAdd.layout!.kind == 'add');
  ok('加法竖式含结果 72', vAdd!.layout!.toText().contains('72'));

  final mulR = evaluate('12×13');
  final vMul = PadVertical.of(mulR);
  ok('整数乘法出竖式（含部分积）',
      vMul != null && vMul.layout!.kind == 'mul' && vMul.layout!.toText().contains('156'));

  final divR = evaluate('58÷7');
  final vDiv = PadVertical.of(divR);
  ok('带余除法出长除法', vDiv != null && vDiv.division != null);
  ok('商 8 余 2', vDiv!.division!.quotient == 8 && vDiv.division!.remainder == 2);

  final decR = evaluate('3.5+2.25');
  final vDec = PadVertical.of(decR);
  ok('小数加法出小数点对齐竖式',
      vDec != null && vDec.layout!.kind == 'decimal_+' && vDec.layout!.toText().contains('5.75'));
  final decText = vDec!.layout!.toText();
  ok('小数竖式两行都有小数点', decText.split('\n').take(2).every((l) => l.contains('.')));

  final subNeg = PadVertical.of(evaluate('3-10'));
  ok('结果为负的减法不出竖式（但结果照算）', subNeg == null && evaluate('3-10').value == Rational(-7));

  ok('小数乘法不出竖式（先挪小数点，版面易误导）', PadVertical.of(evaluate('2.5×4')) == null);
  ok('多步算式不出竖式', PadVertical.of(evaluate('3+4×5')) == null);
  ok('带括号的不出竖式', PadVertical.of(evaluate('(2+3)×4')) == null);

  // ── 错误提示（必须是人话）─────────────────────────
  void expectErr(String src, String msg) {
    try {
      evaluate(src);
      ok('「$src」应该报错', false);
    } on CalcError catch (e) {
      ok('「$src」报错：$msg', e.message == msg);
    }
  }

  expectErr('1+', '算式不完整');
  expectErr('1÷0', '除以零');
  expectErr('(1+2', '括号没有闭合');
  expectErr('@', '看不懂这个字符：@');
  expectErr('', '请输入算式');

  // ── 展示形态 ──────────────────────────────────────
  ok('分数形式 3/7', Rational(3, 7).toFractionString() == '3/7');
  ok('带分数 8又2/7', Rational(58, 7).toMixedString() == '8又2/7');
  ok('1/8 有限小数 0.125', decimalStringExact(Rational(1, 8)) == '0.125');
  ok('1/3 不是有限小数', decimalStringExact(Rational(1, 3)) == null);

  print('\n浮窗演算板引擎：$_pass 通过，$_fail 失败');
  if (_fail > 0) throw Exception('有断言失败');
}
