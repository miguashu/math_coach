#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 FSRS-6 的对照测试。

为什么要有这个脚本：`lib/review/fsrs.dart` 里 21 个参数、十几个 exp/pow，
手抄错一个系数照样"跑得通"，但间隔就全歪了 —— 而"间隔歪了"在孩子身上的
表现是"该复习的没复习"，家长根本看不出来。所以那些期望值**一个都不许手算**，
全部由官方实现 `py-fsrs` 算出来再写进测试。

用法：
    pip install fsrs
    python tool/gen_fsrs_refs.py

产物：
    app/build/fsrs_refs.json    参考值（供人看 / 排查用）
    test/fsrs6_test.dart        数值段（本脚本生成）+ 行为段（tool/fsrs_test_tail.dart.txt）

改了 `lib/review/fsrs.dart` 里的公式后**必须重跑一次**：
脚本会覆盖 test/fsrs6_test.dart 的数值段，行为段原样保留。
"""

import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_JSON = os.path.join(ROOT, 'app', 'build', 'fsrs_refs.json')
OUT_DART = os.path.join(ROOT, 'test', 'fsrs6_test.dart')
TAIL = os.path.join(ROOT, 'tool', 'fsrs_test_tail.dart.txt')

# 对照用的 (难度 D, 稳定性 S, 留存率 R) 组合。
# 刻意覆盖四个角：常规(5,3,.9)、快忘了(5,3,.5)、又难又新(8,1,.9)、
# 又简单又老(1,100,.9)、几乎所有都忘光(5,3,.1)、最难(10,...)、最易(2,...)。
CASES = [
    (5.0, 3.0, 0.9),
    (5.0, 3.0, 0.5),
    (8.0, 1.0, 0.9),
    (2.0, 20.0, 0.95),
    (1.0, 100.0, 0.9),
    (10.0, 0.5, 0.8),
    (5.0, 3.0, 0.1),
    (6.5, 45.0, 0.85),
]

INTERVAL_INPUTS = [0.5, 1.0, 3.0, 10.0, 30.0, 100.0, 365.0]


def num(v):
    """写进 Dart 的字面量：必须完整精度。

    曾经用 round(v, 6) 省字符，结果参考值和实现差 3e-7，
    比 1e-9 的容差还大，4 条断言凭空变红。别再省这几个字符。
    """
    return repr(float(v))


def main():
    try:
        from fsrs import Scheduler, Rating
    except ImportError:
        sys.exit('缺 py-fsrs：pip install fsrs')

    f = Scheduler()
    ratings = [Rating.Again, Rating.Hard, Rating.Good, Rating.Easy]

    refs = {
        'params': list(f.parameters),
        'decay': -f.parameters[20],
        'initialStability': [f._initial_stability(rating=r) for r in ratings],
        'initialDifficulty': [f._initial_difficulty(rating=r, clamp=True) for r in ratings],
        'stability': [],
        'difficulty': [],
        'interval': [],
    }
    # factor = 0.9^(1/decay) - 1，官方没直接暴露，按定义算
    refs['factor'] = pow(0.9, 1.0 / refs['decay']) - 1.0

    for d, s, r in CASES:
        refs['stability'].append({
            'd': d, 's': s, 'r': r,
            'out': [f._next_stability(difficulty=d, stability=s,
                                      retrievability=r, rating=g)
                    for g in ratings],
        })
        refs['difficulty'].append({
            'd': d,
            'out': [f._next_difficulty(difficulty=d, rating=g) for g in ratings],
        })

    for s in INTERVAL_INPUTS:
        refs['interval'].append({'s': s, 'out': f._next_interval(stability=s)})

    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    with io.open(OUT_JSON, 'w', encoding='utf-8') as fp:
        json.dump(refs, fp, ensure_ascii=False, indent=2)

    head = []
    a = head.append
    a("import 'package:test/test.dart';")
    a("import 'package:math_coach/review/fsrs.dart';")
    a('')
    a('/// FSRS-6 数值对照测试。**本文件的数值段由 tool/gen_fsrs_refs.py 生成，别手改**。')
    a('///')
    a('/// 这里每一个期望值都不是手算的，而是**官方实现算出来的**：')
    a('/// `pip install fsrs` 装 py-fsrs，直接调它的 `_next_difficulty` /')
    a('/// `_next_stability` / `_initial_stability` / `_initial_difficulty` /')
    a('/// `_next_interval` 导出参考值，再逐条断言我们的 Dart 实现。')
    a('///')
    a('/// 为什么要这么较真：公式里 21 个参数、十几个 exp/pow，')
    a("/// 手抄错一个系数照样\"跑得通\"，但间隔就全歪了 ——")
    a('/// 而"间隔歪了"在孩子身上的表现是"该复习的没复习"，家长根本看不出来。')
    a('/// 重新生成：`python tool/gen_fsrs_refs.py`（见 docs/app/02-复习页.md）。')
    a('void main() {')
    a('  final fsrs = Fsrs6();')
    a('')
    a("  group('FSRS-6 与官方实现逐条对照', () {")
    a("    test('初始稳定性 S0 与初始难度 D0', () {")
    for i, v in enumerate(refs['initialStability']):
        a('      expect(fsrs.initialStability(Rating.values[%d]), closeTo(%s, 1e-12));'
          % (i, num(v)))
    a('')
    for i, v in enumerate(refs['initialDifficulty']):
        a('      expect(fsrs.initialDifficulty(Rating.values[%d]), closeTo(%s, 1e-12));'
          % (i, num(v)))
    a('    });')
    a('')
    a("    test('decay 与 factor 与官方一致', () {")
    a('      expect(fsrs.decay, closeTo(%s, 1e-12));' % num(refs['decay']))
    a('      expect(fsrs.factor, closeTo(%s, 1e-12));' % num(refs['factor']))
    a('    });')
    a('')
    a("    test('稳定性更新：4 种评分 x %d 组 (D, S, R)', () {" % len(CASES))
    for c in refs['stability']:
        for i, v in enumerate(c['out']):
            a('      expect(')
            a('        fsrs.nextStability(difficulty: %s, stability: %s,'
              % (num(c['d']), num(c['s'])))
            a('            retrievability: %s, rating: Rating.values[%d]),'
              % (num(c['r']), i))
            a('        closeTo(%s, 1e-9),' % num(v))
            a('      );')
    a('    });')
    a('')
    a("    test('难度更新：4 种评分 x %d 组 (D, S, R)', () {" % len(CASES))
    for c in refs['difficulty']:
        for i, v in enumerate(c['out']):
            a('      expect(fsrs.nextDifficulty(%s, Rating.values[%d]), closeTo(%s, 1e-12));'
              % (num(c['d']), i, num(v)))
    a('    });')
    a('')
    a("    test('稳定性 -> 间隔（天）', () {")
    for c in refs['interval']:
        a('      expect(fsrs.nextInterval(%s), %d);' % (num(c['s']), c['out']))
    a('    });')
    a('  });')
    a('')

    with io.open(TAIL, encoding='utf-8') as fp:
        tail = fp.read().rstrip('\n')

    text = '\n'.join(head) + '\n' + tail + '\n'
    with io.open(OUT_DART, 'w', encoding='utf-8', newline='\n') as fp:
        fp.write(text)

    print('[ok] %s' % OUT_JSON)
    print('[ok] %s（数值段 %d 行 + 行为段 %d 行）'
          % (OUT_DART, len(head), tail.count('\n') + 1))


if __name__ == '__main__':
    main()
