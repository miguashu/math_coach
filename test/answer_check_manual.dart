// 判分规则的回归验证（可直接运行，不依赖 package:test）。
//
// 为什么不用 package:test：本机 Dart 无法通过管道启动子进程
// （Windows CreateFile failed 231），`dart test` 会在预编译阶段就失败。
// 所以这里写成纯 Dart 脚本：
//
//     dart run test/answer_check_manual.dart
//
// 全部 PASS 时输出「全部通过」，否则以退出码 1 结束。
library;

import 'package:math_coach/quiz/question.dart';

int _failed = 0;
int _passed = 0;

void expectTrue(String desc, bool actual) {
  if (actual) {
    _passed++;
    print('  PASS  $desc');
  } else {
    _failed++;
    print('  FAIL  $desc  （得到 false，期望 true）');
  }
}

void expectFalse(String desc, bool actual) {
  if (!actual) {
    _passed++;
    print('  PASS  $desc');
  } else {
    _failed++;
    print('  FAIL  $desc  （得到 true，期望 false）');
  }
}

void main() {
  print('数值答案的宽容判分');
  final a = QuizAnswer(display: '36', value: 36.0, unit: '平方厘米');
  expectTrue('整数写法 36', a.check('36'));
  expectTrue('小数写法 36.0', a.check('36.0'));
  expectTrue('带单位 36平方厘米', a.check('36平方厘米'));
  expectTrue('全角数字 ３６', a.check('３６'));
  expectTrue('前后空格 "  36  "', a.check('  36  '));
  expectFalse('错误答案 35', a.check('35'));
  expectFalse('空答案', a.check(''));
  expectFalse('只有空格', a.check('   '));

  print('\n有余数的除法：余数必须写出来');
  final d = QuizAnswer(
    display: '8 …… 2',
    value: 8.0,
    unit: '余 2',
    tolerance: 0.0,
    accepts: ['8…2', '8…2 余', '8余2', '8…2（余2）'],
  );
  expectTrue('标准写法 8 …… 2', d.check('8 …… 2'));
  expectTrue('省略号连写 8……2', d.check('8……2'));
  expectTrue('汉字余 8余2', d.check('8余2'));
  expectTrue('带空格 "8 …… 2 "', d.check('8 …… 2 '));
  expectFalse('只写商不写余数 8', d.check('8'));
  expectFalse('商错 9 …… 1', d.check('9 …… 1'));

  print('\n单位剥离后比对');
  final q = QuizAnswer(display: '24', value: 24.0, unit: '厘米');
  expectTrue('写了单位 24厘米', q.check('24厘米'));
  expectTrue('没写单位 24', q.check('24'));

  print('\n通过 $_passed 条，失败 $_failed 条');
  if (_failed > 0) {
    throw StateError('判分规则回归失败');
  }
  print('全部通过');
}
