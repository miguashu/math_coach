/// 运行记录（管理员视角）：每一次拍照、识别、讲解、出题、导出都记一笔。
///
/// 存在的理由：联网之后整个流程的成功率、耗时、失败原因**必须可查** ——
/// 否则"识别不出来""讲得不对"只能靠猜。记录只在手机本地，不上传。
///
/// 文件：filesDir/activity_log.jsonl（每行一条 JSON，最多保留 500 条）。
library;

import 'dart:convert';
import 'dart:io';

class ActivityEvent {
  final String type; // photo / ocr / solve / variant / export / error
  final bool ok;
  final String detail;
  final DateTime time;
  final int latencyMs;
  final String? model;
  final int? tokens;

  const ActivityEvent({
    required this.type,
    required this.ok,
    required this.detail,
    required this.time,
    this.latencyMs = 0,
    this.model,
    this.tokens,
  });

  Map<String, Object?> toJson() => {
        'type': type,
        'ok': ok,
        'detail': detail,
        't': time.toIso8601String(),
        'ms': latencyMs,
        if (model != null) 'model': model,
        if (tokens != null) 'tokens': tokens,
      };

  static ActivityEvent fromJson(Map<String, Object?> j) => ActivityEvent(
        type: (j['type'] ?? '').toString(),
        ok: j['ok'] == true,
        detail: (j['detail'] ?? '').toString(),
        time: DateTime.tryParse((j['t'] ?? '').toString()) ?? DateTime.now(),
        latencyMs: ((j['ms'] ?? 0) as num).toInt(),
        model: j['model'] as String?,
        tokens: j['tokens'] as int?,
      );
}

class ActivityLog {
  static const _max = 500;
  final File file;
  final List<ActivityEvent> _events = [];

  ActivityLog(this.file);

  List<ActivityEvent> get events => List.unmodifiable(_events.reversed.toList());

  Future<void> load() async {
    _events.clear();
    if (!await file.exists()) return;
    try {
      final lines = await file.readAsLines();
      for (final l in lines) {
        if (l.trim().isEmpty) continue;
        try {
          _events.add(ActivityEvent.fromJson(jsonDecode(l) as Map<String, Object?>));
        } catch (_) {}
      }
      if (_events.length > _max) {
        _events.removeRange(0, _events.length - _max);
      }
    } catch (_) {}
  }

  Future<void> add(ActivityEvent e) async {
    _events.add(e);
    while (_events.length > _max) {
      _events.removeAt(0);
    }
    try {
      await file.writeAsString('${jsonEncode(e.toJson())}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写不进去不影响主流程
    }
  }

  /// 便捷记录：成功/失败都能记，失败时 [error] 进 detail。
  Future<void> record(String type,
          {required String detail, bool ok = true, int latencyMs = 0, String? model, int? tokens}) =>
      add(ActivityEvent(
          type: type,
          ok: ok,
          detail: detail,
          time: DateTime.now(),
          latencyMs: latencyMs,
          model: model,
          tokens: tokens));

  ({int total, int failed, int avgMs, int byType_total}) stats() {
    final total = _events.length;
    final failed = _events.where((e) => !e.ok).length;
    var ms = 0;
    var n = 0;
    for (final e in _events) {
      if (e.latencyMs > 0) {
        ms += e.latencyMs;
        n++;
      }
    }
    return (total: total, failed: failed, avgMs: n == 0 ? 0 : ms ~/ n, byType_total: total);
  }

  Map<String, int> countByType() {
    final m = <String, int>{};
    for (final e in _events) {
      m[e.type] = (m[e.type] ?? 0) + 1;
    }
    return m;
  }

  List<ActivityEvent> ofType(String type) =>
      _events.reversed.where((e) => e.type == type).toList();

  Future<void> clear() async {
    _events.clear();
    try {
      if (await file.exists()) await file.writeAsString('', flush: true);
    } catch (_) {}
  }
}
