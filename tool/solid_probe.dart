import 'dart:io';

import 'package:math_coach/geometry/dsl/figure.dart';
import 'package:math_coach/geometry/render/figure_svg.dart';
import 'package:math_coach/geometry/solver/lattice.dart' show Cell;
import 'package:math_coach/geometry/solver/solid.dart';
import 'package:math_coach/geometry/solver/solver.dart';

/// 立体图形探针：把求解出的场景按数学坐标打印出来，并导出 SVG 供肉眼核对。
/// 用法：dart run tool/solid_probe.dart
void main() {
  final out = Directory('app/build/shots/solid');
  if (!out.existsSync()) out.createSync(recursive: true);

  final cases = <Map<String, Object>>[
    {'name': 'cuboid-5-3-2', 'type': FigureType.cuboidOblique, 'p': {'w': 5, 'h': 3, 'd': 2}},
    {'name': 'cuboid-9-6-7', 'type': FigureType.cuboidOblique, 'p': {'w': 9, 'h': 6, 'd': 7}},
    {'name': 'cuboid-3-2-2', 'type': FigureType.cuboidOblique, 'p': {'w': 3, 'h': 2, 'd': 2}},
    {'name': 'net-cross', 'type': FigureType.cubeNet, 't': {'layout': 'cross'}},
    {'name': 'net-stair', 'type': FigureType.cubeNet, 't': {'layout': 'stair'}},
    {'name': 'net-zigzag', 'type': FigureType.cubeNet, 't': {'layout': 'zigzag'}},
    {'name': 'net-twin', 'type': FigureType.cubeNet, 't': {'layout': 'twin'}},
    {'name': 'net-rect23', 'type': FigureType.cubeNet,
      'p': {'edge': 4}, 't': {'layout': 'rect23'}},
    {'name': 'net-twotop', 'type': FigureType.cubeNet,
      'p': {'edge': 4}, 't': {'layout': 'twotop'}},
    {'name': 'cylinder-3-6', 'type': FigureType.cylinder, 'p': {'r': 3, 'h': 6}},
    {'name': 'cone-3-6', 'type': FigureType.cone, 'p': {'r': 3, 'h': 6}},
  ];

  for (final cs in cases) {
    final name = cs['name'] as String;
    final params = <String, num>{};
    (cs['p'] as Map<String, num>? ?? {}).forEach((k, v) => params[k] = v);
    final text = <String, String>{};
    (cs['t'] as Map<String, String>? ?? {}).forEach((k, v) => text[k] = v);
    final spec = FigureSpec(
        type: cs['type'] as FigureType, params: params, text: text, unit: 'cm', grade: 5);
    final r = FigureSolver.solve(spec);
    final svg = const FigureSvgRenderer().render(r.scene, widthPx: 240, idPrefix: name);
    File('${out.path}/$name.svg').writeAsStringSync(svg);

    print('==== $name  facts=${r.facts.toJson()}');
    print('    extent=${r.scene.extent}');
    for (final s in r.scene.shapes) {
      if (s is SLine) {
        print('    line  (${s.a.x},${s.a.y})-(${s.b.x},${s.b.y}) ${s.style}');
      } else if (s is SPolyline) {
        print('    poly  ${s.pts.map((p) => "(${p.x},${p.y})").join(' ')} closed=${s.closed}');
      } else if (s is SEllipse) {
        print('    ell   c=(${s.c.x},${s.c.y}) rx=${s.rx} ry=${s.ry} ${s.style}');
      } else {
        print('    ${s.runtimeType}');
      }
    }
    for (final l in r.scene.labels) {
      print('    label (${l.at.x},${l.at.y}) "${l.text}"');
    }
  }

  // 展开图可折叠性逐个体检
  print('==== 展开图可折叠性');
  for (final net in CubeNet.builtin) {
    print('    ${net.name}: ${CubeNetValidator.isFoldable(net) ? "可折" : "不可折"}');
  }
  final bad = CubeNet('rect23', [
    const Cell(0, 0),
    const Cell(1, 0),
    const Cell(2, 0),
    const Cell(0, 1),
    const Cell(1, 1),
    const Cell(2, 1),
  ]);
  print('    rect23(2x3): ${CubeNetValidator.isFoldable(bad) ? "可折" : "不可折"}');
  final twoTop = CubeNet('twotop', [
    const Cell(0, 0),
    const Cell(1, 0),
    const Cell(2, 0),
    const Cell(3, 0),
    const Cell(0, 1),
    const Cell(3, 1),
  ]);
  print('    twotop(一两排四+同上两片): ${CubeNetValidator.isFoldable(twoTop) ? "可折" : "不可折"}');
}
