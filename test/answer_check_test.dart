import 'package:test/test.dart';

import 'package:math_coach/quiz/question.dart';

/// 判分规则的回归测试。
///
/// 判分是这个 App 里最不能出错的地方：判错了对的会打击孩子，
/// 判对了错的会让"错题本"整个失去意义。所以每条容忍规则都要有测试锁住。
void main() {
  group('数值答案的宽容判分', () {
    final a = QuizAnswer(display: '36', value: 36.0, unit: '平方厘米');

    test('整数写法', () => expect(a.check('36'), isTrue));
    test('小数写法', () => expect(a.check('36.0'), isTrue));
    test('带单位', () => expect(a.check('36平方厘米'), isTrue));
    test('全角数字', () => expect(a.check('３６'), isTrue));
    test('前后空格', () => expect(a.check('  36  '), isTrue));
    test('错误答案', () => expect(a.check('35'), isFalse));
    test('空答案', () => expect(a.check(''), isFalse));
    test('只有空格', () => expect(a.check('   '), isFalse));
  });

  group('有余数的除法：余数必须写出来', () {
    // 与 FCalc.divRem 生成的答案结构一致
    final d = QuizAnswer(
      display: '8 …… 2',
      value: 8.0,
      unit: '余 2',
      tolerance: 0.0,
      accepts: ['8…2', '8…2 余', '8余2', '8…2（余2）'],
    );

    test('标准写法', () => expect(d.check('8 …… 2'), isTrue));
    test('省略号连写', () => expect(d.check('8……2'), isTrue));
    test('汉字「余」', () => expect(d.check('8余2'), isTrue));
    test('带空格', () => expect(d.check('8 …… 2 '), isTrue));

    test('只写商不写余数 → 判错', () {
      // 这里的陷阱：value = 8.0 且 tolerance = 0，
      // 若数值比较不做「答案含余数则输入必须含余数」的判断，
      // |8 − 8| = 0 ≤ 0 会把漏写余数判成对。
      expect(d.check('8'), isFalse);
    });

    test('商错', () => expect(d.check('9 …… 1'), isFalse));
  });

  group('单位剥离后比对', () {
    final q = QuizAnswer(display: '24', value: 24.0, unit: '厘米');
    test('写了单位', () => expect(q.check('24厘米'), isTrue));
    test('没写单位', () => expect(q.check('24'), isTrue));
  });
}
