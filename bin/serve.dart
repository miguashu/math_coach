/// 本地服务入口。
///
/// 为什么是"本地服务 + 浏览器 UI"而不是 APK：
///   本机 Dart 无法以管道模式 spawn 子进程，Gradle / flutter build 跑不起来；
///   而所有真正重要的东西（出什么题、答案多少、什么时候复习）都在这份 Dart 内核里，
///   把它们编译到 Web 或装到手机上都不会改变核心逻辑。
///
/// 注意：服务只监听 127.0.0.1，不外发任何请求，数据落在本机用户目录下。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/quizgen.dart';
import 'package:math_coach/export/paper.dart';
import 'package:math_coach/export/paper_pdf.dart';
import 'package:math_coach/knowledge/kp_index.dart';
import 'package:math_coach/quiz/generator.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/review/fsrs.dart';
import 'package:math_coach/store/repository.dart';

late final Directory projectRoot;
late final WrongBookRepository repo;
late final KnowledgeIndex kpIndex;
late final Uint8List fontBytes;

/// 当前未批改的卷面快照（paperId → 题目），答案不下发到浏览器。
final Map<String, Map<String, QuizQuestion>> _snapshots = {};

/// 最近出过的题干（Web 端避重：不落盘，服务重启就从零开始，
/// 浏览器刷新出的题重复几道无伤大雅，App 端才需要跨会话避重）。
final List<String> _recentStems = [];

/// 本机在局域网里的地址（给用户抄到手机上用）。
Future<List<String>> _lanAddresses() async {
  final out = <String>[];
  try {
    for (final i in await NetworkInterface.list(
        includeLoopback: false, type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (a.address.startsWith('192.168.') || a.address.startsWith('10.')) {
          out.add(a.address);
        }
      }
    }
  } catch (_) {
    // 拿不到就不显示，不影响服务本身
  }
  return out;
}

Future<void> main(List<String> args) async {
  // bin/serve.dart → 项目根
  projectRoot = File(Platform.script.toFilePath()).parent.parent;
  final webDir = Directory('${projectRoot.path}/web');
  if (!webDir.existsSync()) {
    stderr.writeln('找不到 web 目录：${webDir.path}');
    exit(1);
  }

  final port = int.tryParse(args.isNotEmpty ? args[0] : '') ??
      int.tryParse(Platform.environment['MATH_COACH_PORT'] ?? '') ??
      8787;

  repo = WrongBookRepository(file: WrongBookRepository.defaultFile());
  await repo.load();
  kpIndex = KnowledgeIndex();

  fontBytes = await _loadFont();

  // 默认只听本机（数据不出这台电脑）。要拿手机看观感就加 --lan，
  // 那时才会监听 0.0.0.0 并把局域网地址打出来 ——
  // 苹果设备装不了 APK（没有 macOS 就构建不出 iOS 包），
  // 所以 iPhone 上的观感验收走的就是这条路：Safari 打开同一份内核。
  final lan = args.contains('--lan') ||
      Platform.environment['MATH_COACH_LAN'] == '1';
  final host = lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
  final server = await HttpServer.bind(host, port);
  stdout.writeln('');
  stdout.writeln('  小学数学辅导（本地版）已启动');
  stdout.writeln('  浏览器打开：http://127.0.0.1:$port');
  if (lan) {
    final ips = await _lanAddresses();
    stdout.writeln('');
    stdout.writeln('  手机（同一个 WiFi）打开下面任意一个：');
    for (final ip in ips) {
      stdout.writeln('    http://$ip:$port');
    }
    stdout.writeln('  苹果设备可直接用 Safari 打开，页面已适配窄屏');
  }
  stdout.writeln('  数据文件：${repo.file.path}');
  stdout.writeln('  错题 ${repo.count} 条');
  stdout.writeln('  退出请在这个窗口按 Ctrl+C');
  stdout.writeln('');

  await for (final req in server) {
    try {
      await handle(req, webDir);
    } catch (e, st) {
      stderr.writeln('请求处理失败: $e\n$st');
      try {
        req.response.statusCode = 500;
        req.response.write('Server error');
        await req.response.close();
      } catch (_) {}
    }
  }
}

/// 字体：PDF 必须内嵌，否则导出的试卷全是方块。
/// 依次尝试几个 Windows 自带的中文字体。
Future<Uint8List> _loadFont() async {
  const candidates = [
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\simsun.ttc',
    r'C:\Windows\Fonts\simkai.ttf',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (await f.exists()) return f.readAsBytes();
  }
  stderr.writeln('警告：没找到中文字体，导出的 PDF 会显示方块');
  return Uint8List(0);
}

Future<void> handle(HttpRequest req, Directory webDir) async {
  final path = req.uri.path;

  // ── 静态页面 ──
  if (path == '/' || path == '/index.html') return serveFile(req, '${webDir.path}/index.html');
  if (path == '/app.css') return serveFile(req, '${webDir.path}/app.css', 'text/css');
  if (path == '/app.js') return serveFile(req, '${webDir.path}/app.js', 'application/javascript');

  // ── PWA：iPhone「添加到主屏幕」要靠这两样 ──
  // manifest 决定桌面图标、名字、是否全屏；sw.js 提供离线外壳。
  // 缺了它们 Safari 只会存一个书签，点开还是带浏览器栏的网页。
  if (path == '/manifest.webmanifest') {
    return serveFile(req, '${webDir.path}/manifest.webmanifest', 'application/manifest+json');
  }
  if (path == '/sw.js') {
    return serveFile(req, '${webDir.path}/sw.js', 'application/javascript');
  }
  if (path == '/favicon.ico') {
    // 浏览器会主动来要，给真图标而不是 404（内容是 PNG，MIME 照实说）
    return serveFile(req, '${webDir.path}/icons/favicon.png', 'image/png', true);
  }
  if (path.startsWith('/icons/')) {
    // 只认单层文件名，挡掉 ../ 这类目录穿越
    final name = path.substring('/icons/'.length);
    if (name.isEmpty || name.contains('/') || name.contains(r'\') || name.contains('..')) {
      req.response.statusCode = 404;
      return req.response.close();
    }
    return serveFile(req, '${webDir.path}/icons/$name', _imageMime(name), true);
  }

  // ── API ──
  if (path.startsWith('/api/')) return handleApi(req, path);

  req.response.statusCode = 404;
  await req.response.close();
}

Future<void> handleApi(HttpRequest req, String path) async {
  if (path == '/api/topics') return apiTopics(req);
  if (path == '/api/practice') return apiPractice(req);
  if (path == '/api/check') return apiCheck(req);
  if (path == '/api/book') return apiBook(req);
  if (path == '/api/review') return apiReview(req);
  if (path == '/api/export') return apiExport(req);
  if (path == '/api/stats') return apiStats(req);
  if (path == '/api/samples') return apiSamples(req);
  if (path == '/api/sample-pdf') return apiSamplePdf(req);

  json(req, {'error': '未知接口 $path'}, status: 404);
}

// ══════════════ 接口实现 ══════════════

/// 知识点树（供下拉选择）
Future<void> apiTopics(HttpRequest req) async {
  final grade = int.tryParse(req.uri.queryParameters['grade'] ?? '') ?? 3;
  final units = KnowledgeTree.unitsOf(kpIndex, grade);
  json(req, {
    'grade': grade,
    'units': [
      for (final u in units)
        {
          'domain': u.domain.label,
          'name': u.name,
          'semester': u.semester,
          'unitNo': u.unitNo,
          'points': [
            for (final p in u.points) {'code': p.code, 'name': p.name},
          ],
        },
    ],
  });
}

/// 出卷。返回给浏览器的**不含答案**。
///
/// [level] 1=基础（纯本地模板，不联网）/ 2=提高（一半 AI）/ 3=奥数挑战（AI 为主）。
/// 本地题库没覆盖的知识点（如五年级"图形的运动（三）"）在 2/3 档整套交给 AI ——
/// 否则会静默出一道别的单元的题，家长看到的就是"五年级冒出一年级简单题"。
Future<void> apiPractice(HttpRequest req) async {
  final body = await bodyJson(req);
  final grade = (body['grade'] as num?)?.toInt() ?? 3;
  final unit = body['unit'] as String?;
  final tag = body['tag'] as String?;
  final count = (body['count'] as num?)?.toInt() ?? 5;
  final level = QuizLevel.fromValue((body['level'] as num?)?.toInt() ?? 1);

  final gen = QuizGenerator(index: kpIndex);
  final covered = gen.covers(grade: grade, unit: unit, tag: tag);
  final local = gen.generateMany(grade: grade, unit: unit, tag: tag, count: count);

  var qs = local;
  String? note;
  final wantAi = level == QuizLevel.basic
      ? 0
      : (!covered
          ? count
          : (level == QuizLevel.olympiad ? count : math_max2(1, (count / 2).round())));
  if (wantAi > 0) {
    try {
      final res = await QuizAgent(LlmClient(AiConfig.fallback)).generate(
        grade: grade,
        unit: unit,
        count: wantAi,
        level: level,
        avoid: _recentStems,
      );
      qs = mixPaper(
        local: local,
        ai: res.questions,
        count: count,
        grade: grade,
        unit: unit,
        moreLocal: (n) =>
            gen.generateMany(grade: grade, unit: unit, tag: tag, count: n),
      );
      final aiCount = qs.where((q) => q.isAi).length;
      if (res.questions.isEmpty) {
        note = res.error ?? 'AI 没出成，本套用本地题库';
      } else if (!covered) {
        note = '「$unit」本地题库没收录，本套 $aiCount 道由 AI 现场生成';
      } else {
        note = '本套含 $aiCount 道 AI 新题（答案已本地验算）';
      }
      _rememberStems(qs);
    } catch (e) {
      qs = local;
      note = 'AI 出题失败（$e），本套用本地题库';
    }
  } else if (!covered && unit != null && unit.trim().isNotEmpty) {
    note = '「$unit」本地题库还没收录；难度切到「提高」或「奥数挑战」可用 AI 现场出题';
  }
  if (qs.isEmpty) {
    return json(req, {'error': '这个知识点暂时出不出题，换一个试试'}, status: 400);
  }

  final pid = 'p${DateTime.now().microsecondsSinceEpoch}';
  _snapshots[pid] = {for (final q in qs) q.id: q};

  json(req, {
    'paperId': pid,
    if (note != null) 'note': note,
    'items': [for (final q in qs) clientQuestion(q)],
  });
}

int math_max2(int a, int b) => a > b ? a : b;

void _rememberStems(List<QuizQuestion> qs) {
  for (final q in qs) {
    _recentStems.remove(q.stem);
    _recentStems.insert(0, q.stem);
  }
  if (_recentStems.length > 40) {
    _recentStems.removeRange(40, _recentStems.length);
  }
}

/// 观感验收用的固定样例。
///
/// 为什么需要它：几何图形画得对不对、竖式数位齐不齐、打印出来糊不糊，
/// 这些只有真机屏幕能判 —— 而 iOS 在这台 Windows 上根本构建不出来。
/// 所以让安卓（Chrome）和苹果（Safari）打开同一份样例来对比，
/// 两边看到的是**同一组题、同一份内核算出来的图**。
const _geoKinds = ['triangle', 'rect', 'circleArea', 'composite', 'trapezoid'];
const _vertKinds = ['add', 'sub', 'mul', 'divRem'];

Future<void> apiSamples(HttpRequest req) async {
  final gen = QuizGenerator(index: kpIndex);
  final geo = <QuizQuestion>[];
  final vert = <QuizQuestion>[];
  final seen = <String>{};

  for (var grade = 3; grade <= 6; grade++) {
    for (final q in gen.generateMany(grade: grade, count: 40)) {
      if (!seen.add(q.id)) continue;
      // 按题型去重：验收要看的是"不同图形画得对不对"，
      // 四道全是长方形的话，三角形画错了也看不出来。
      if (geo.length < 4 &&
          _geoKinds.contains(q.kind) &&
          q.figureSvg != null &&
          !geo.any((e) => e.kind == q.kind)) {
        geo.add(q);
      }
      if (vert.length < 4 &&
          _vertKinds.contains(q.kind) &&
          q.verticalSvg != null &&
          !vert.any((e) => e.kind == q.kind)) {
        vert.add(q);
      }
      if (geo.length >= 4 && vert.length >= 4) break;
    }
    if (geo.length >= 4 && vert.length >= 4) break;
  }

  json(req, {
    'geometry': [for (final q in geo) clientQuestion(q)],
    'vertical': [for (final q in vert) clientQuestion(q)],
  });
}

/// 样例练习卷 PDF：让"打印出来糊不糊"这一项在手机上就能验（可从 Safari 直接打印）。
Future<void> apiSamplePdf(HttpRequest req) async {
  if (fontBytes.isEmpty) {
    return json(req, {'error': '本机没找到中文字体，无法导出 PDF'}, status: 500);
  }
  final gen = QuizGenerator(index: kpIndex);
  final qs = gen.generateMany(grade: 4, count: 8);
  if (qs.isEmpty) {
    return json(req, {'error': '样例生成失败'}, status: 500);
  }
  final title = '观感验收样例卷';
  final items = <PaperItem>[
    for (final q in qs)
      PaperItem(
        id: q.id,
        stem: q.stem,
        figure: VerticalReplay.figure(q.figureSpec),
        // 试卷给孩子做：竖式只印题面，结果与进位留空
        vertical: (q.verticalKind != null && q.verticalKind != 'div' && q.verticalArgs.isNotEmpty)
            ? VerticalReplay.layout(q.verticalKind!, q.verticalArgs, withAnswer: false)
            : null,
        longDivision: q.verticalKind == 'div' && q.verticalArgs.isNotEmpty
            ? VerticalReplay.longDivision(q.verticalArgs, withAnswer: false)
            : null,
        answer: q.answer.display,
        knowledgeLabel: q.kpPath,
        difficulty: q.difficulty,
        importance: 0,
      ),
  ];
  final paper = Paper(
    title: title,
    items: items,
    config: PaperConfig(
      title: title,
      itemsPerPage: 4,
      answerSpace: 70,
      answerPlacement: AnswerPlacement.end,
      showKnowledge: true,
    ),
    createdAt: DateTime.now(),
  );
  final fd = ByteData.sublistView(fontBytes);
  final bytes = await PaperPdfExporter(fontData: fd, fontBoldData: fd).export(paper);
  final name = Uri.encodeComponent('$title.pdf');
  req.response
    ..headers.contentType = ContentType('application', 'pdf')
    ..headers.set('Content-Disposition', 'inline; filename*=UTF-8\'\'$name')
    ..headers.set('Content-Length', '${bytes.length}')
    ..add(bytes);
  await req.response.close();
}

/// 把题目转成给浏览器的数据（**刻意不含 answer**）。
Map<String, Object?> clientQuestion(QuizQuestion q) => {
      'id': q.id,
      'stem': q.stem,
      'figureSvg': q.figureSvg,
      'verticalSvg': q.verticalSvg,
      'kpPath': q.kpPath,
      'difficulty': q.difficulty,
      'kind': q.kind,
      'grade': q.grade,
      'source': q.source,
    };

/// 判分 + 归档。
Future<void> apiCheck(HttpRequest req) async {
  final body = await bodyJson(req);
  final pid = body['paperId'] as String?;
  final snap = pid == null ? null : _snapshots[pid];
  if (snap == null) {
    return json(req, {
      'error': '这份练习已经过期了（服务重启或时间太久），请重新出一卷'
    }, status: 410);
  }
  final answers = (body['answers'] as List?) ?? const [];
  final results = <Map<String, Object?>>[];
  var wrong = 0;

  for (final a in answers) {
    final m = (a as Map).cast<String, Object?>();
    final id = m['id'] as String?;
    final text = '${m['answer'] ?? ''}';
    final q = snap[id];
    if (q == null) continue;

    final correct = q.answer.check(text);
    final neednyaSteps = !correct || (m['showSteps'] == true);
    if (!correct) wrong++;

    // 前端可以带 rating（1..4）= 答对后的自评档位。
    // 答错一律 again、答对默认 good，取舍全封在 ratingFor 里，这里不自己判断。
    final selfRated = m['rating'] == null
        ? null
        : Rating.fromValue((m['rating'] as num).toInt());
    final rating = ratingFor(correct: correct, selfRated: selfRated);
    final recorded = await repo.recordAttempt(
      q,
      correct: correct,
      rating: rating,
      figureSpec: _figureSpecOf(q),
      verticalKind: _verticalKindOf(q),
      verticalArgs: _verticalArgsOf(q),
    );

    results.add({
      'id': id,
      'correct': correct,
      'rating': rating.value,
      'ratingLabel': rating.label,
      'expected': q.answer.display,
      'expectedUnit': q.answer.unit,
      if (neednyaSteps) 'steps': q.solutionSteps,
      'importance': recorded.importance,
      'nextDue': recorded.fsrs.due.toIso8601String(),
    });
  }

  if (pid != null) _snapshots.remove(pid);

  final st = repo.stats(DateTime.now());
  json(req, {
    'results': results,
    'summary': {
      'total': answers.length,
      'correct': answers.length - wrong,
      'wrong': wrong,
      'due': st.due,
      'attention': st.attention,
    },
  });
}

/// 错题本
Future<void> apiBook(HttpRequest req) async {
  if (req.method == 'DELETE') {
    await repo.clear();
    return json(req, {'ok': true});
  }
  final now = DateTime.now();
  final list = repo.all;
  final st = repo.stats(now);
  json(req, {
    // Record 不能直接 JSON 编码，这里显式摊平成 Map（踩过一次）
    'stats': {
      'total': repo.count,
      'due': st.due,
      'attention': st.attention,
      'mastered': st.mastered,
    },
    'records': [
      for (final r in list)
        {
          ...r.toJson(),
          'shortSteps': r.steps.length > 2 ? r.steps.take(2).toList() : r.steps,
        },
    ],
  });
}

/// 复习队列（到期该练的）
Future<void> apiReview(HttpRequest req) async {
  final grade = int.tryParse(req.uri.queryParameters['grade'] ?? '');
  final now = DateTime.now();
  var queue = repo.dueQueue(now);
  if (grade != null) {
    queue = queue.where((r) => r.grade == grade).toList();
  }
  json(req, {
    'now': now.toIso8601String(),
    'count': queue.length,
    'records': [for (final r in queue) r.toJson()],
  });
}

/// 导出 PDF 试卷（mode=quiz 题卷 / mode=answer 答案）
Future<void> apiExport(HttpRequest req) async {
  if (fontBytes.isEmpty) {
    return json(req, {'error': '本机没找到中文字体，无法导出 PDF'}, status: 500);
  }
  final body = req.method == 'POST' ? await bodyJson(req) : <String, Object?>{};
  for (final k in req.uri.queryParameters.keys) {
    body.putIfAbsent(k, () => req.uri.queryParameters[k]);
  }

  final mode = '${body['mode'] ?? 'quiz'}';
  final title = '${body['title'] ?? '错题练习卷'}';
  final source = '${body['source'] ?? 'book'}'; // book | due
  final ids = (body['ids'] as List?)?.map((e) => '$e').toSet();

  final now = DateTime.now();
  var pool = source == 'due' ? repo.dueQueue(now) : repo.all;
  if (ids != null && ids.isNotEmpty) {
    pool = pool.where((r) => ids.contains(r.id)).toList();
  }
  if (pool.isEmpty) {
    return json(req, {'error': '还没有错题，先去做几道题吧'}, status: 400);
  }

  final items = <PaperItem>[
    for (final r in pool)
      PaperItem(
        id: r.id,
        stem: r.stem,
        figure: VerticalReplay.figure(r.figureSpec),
        vertical: VerticalReplay.layout(r.verticalKind ?? '', r.verticalArgs),
        longDivision: r.verticalKind == 'div'
            ? VerticalReplay.longDivision(r.verticalArgs)
            : null,
        answer: r.answer,
        knowledgeLabel: r.kpPath,
        difficulty: r.difficulty,
        importance: r.importance,
      ),
  ];

  final paper = Paper(
    title: title,
    items: items,
    config: PaperConfig(
      title: title,
      itemsPerPage: 4,
      answerSpace: 70,
      answerPlacement: AnswerPlacement.end,
      showKnowledge: true,
    ),
    createdAt: now,
  );

  final fd = ByteData.sublistView(fontBytes);
  final exporter = PaperPdfExporter(fontData: fd, fontBoldData: fd);
  final bytes = mode == 'answer'
      ? await exporter.exportAnswers(paper)
      : await exporter.export(paper);

  final name = Uri.encodeComponent(
      mode == 'answer' ? '$title-答案.pdf' : '$title.pdf');
  req.response
    ..statusCode = 200
    ..headers.contentType = ContentType('application', 'pdf')
    ..headers.set('Content-Disposition', "attachment; filename*=UTF-8''$name")
    ..headers.set('Content-Length', '${bytes.lengthInBytes}');
  req.response.add(bytes);
  await req.response.close();
}

Future<void> apiStats(HttpRequest req) async {
  final now = DateTime.now();
  final s = repo.stats(now);
  json(req, {
    'total': repo.count,
    'due': s.due,
    'attention': s.attention,
    'mastered': s.mastered,
  });
}

// ══════════════ 工具 ══════════════

Map<String, Object?>? _figureSpecOf(QuizQuestion q) => q.figureSpec;

String? _verticalKindOf(QuizQuestion q) => q.verticalKind;

List<int> _verticalArgsOf(QuizQuestion q) => q.verticalArgs;

/// 图标目录里的扩展名 → MIME。
String _imageMime(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.svg')) return 'image/svg+xml';
  if (n.endsWith('.ico')) return 'image/x-icon';
  if (n.endsWith('.webmanifest')) return 'application/manifest+json';
  return 'application/octet-stream';
}

Future<void> serveFile(HttpRequest req, String path,
    [String mime = 'text/html', bool binary = false]) async {
  final f = File(path);
  if (!await f.exists()) {
    req.response
      ..statusCode = 404
      ..write('Not found: $path');
    return req.response.close();
  }
  req.response
    ..statusCode = 200
    // 二进制（图标）不能挂 charset，否则某些浏览器会当成文本处理
    ..headers.contentType = ContentType.parse(binary ? mime : '$mime; charset=utf-8');
  req.response.add(await f.readAsBytes());
  await req.response.close();
}

void json(HttpRequest req, Map<String, Object?> data, {int status = 200}) {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.parse('application/json; charset=utf-8');
  req.response.write(const JsonEncoder().convert(data));
  req.response.close();
}

Future<Map<String, Object?>> bodyJson(HttpRequest req) async {
  try {
    final txt = await utf8.decoder.bind(req).join();
    if (txt.trim().isEmpty) return {};
    final m = jsonDecode(txt);
    return (m as Map).cast<String, Object?>();
  } catch (_) {
    return {};
  }
}
