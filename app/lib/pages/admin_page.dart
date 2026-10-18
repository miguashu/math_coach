/// 管理员视角：整体流程运行记录。
///
/// 看四件事：一共跑了多少次、失败多少、平均耗时、哪一步最慢/最容易失败。
/// 数据只在手机本地，不上传；可一键清空。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:math_coach/ai/log.dart';

import '../state.dart';

class AdminPage extends StatefulWidget {
  final AppState state;
  const AdminPage({super.key, required this.state});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  String _filter = 'all';

  static const _labels = <String, String>{
    'all': '全部',
    'photo': '拍照',
    'pick': '选图',
    'ocr': '识别',
    'solve': '讲解',
    'variant': '出题',
    'grade': '判卷',
    'derive': '衍生题',
    'backup': '备份',
    'restore': '恢复',
    'export': '导出',
    'error': '异常',
  };

  static const _names = <String, String>{
    'photo': '拍照',
    'pick': '相册选图',
    'ocr': '拍照识题',
    'solve': '分步讲解',
    'variant': '同类题生成',
    'grade': '拍照判卷',
    'derive': '错题衍生题',
    'backup': '导出备份',
    'restore': '恢复备份',
    'export': 'PDF 导出',
    'error': '异常',
  };

  @override
  Widget build(BuildContext context) {
    final log = widget.state.activityLog;
    final events = log == null
        ? const <ActivityEvent>[]
        : (_filter == 'all' ? log.events : log.ofType(_filter));
    final st = log?.stats();

    return Column(
      children: [
        _header(st, log),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final e in _labels.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(e.value, style: const TextStyle(fontSize: 12.5)),
                    selected: _filter == e.key,
                    onSelected: (_) => setState(() => _filter = e.key),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有记录。拍照识题、讲解、出题、导出都会记在这里。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 30),
                  itemCount: events.length,
                  itemBuilder: (ctx, i) => _row(events[i]),
                ),
        ),
      ],
    );
  }

  Widget _header(({int total, int failed, int avgMs, int byType_total})? st, ActivityLog? log) {
    final s = widget.state;
    final total = st?.total ?? 0;
    final failed = st?.failed ?? 0;
    final avg = st?.avgMs ?? 0;
    final okRate = total == 0 ? 0 : ((total - failed) * 100 ~/ total);
    // 学习侧数据：光看接口日志不算"整体运行情况"，孩子练得怎么样才是重点
    final book = s.book;
    final due = s.dueQueue().length;
    final right = book.fold<int>(0, (a, r) => a + r.rightCount);
    final wrong = book.fold<int>(0, (a, r) => a + r.wrongCount);
    final acc = (right + wrong) == 0 ? 0 : (right * 100 ~/ (right + wrong));
    return Container(
      width: double.infinity,
      color: const Color(0xFF334155),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('运行记录',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: _exportLog,
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                icon: const Icon(Icons.share_outlined, size: 16),
                label: const Text('导出', style: TextStyle(fontSize: 12.5)),
              ),
              TextButton.icon(
                onPressed: _confirmClear,
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('清空', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _stat('总调用', '$total'),
              _stat('失败', '$failed'),
              _stat('成功率', '$okRate%'),
              _stat('平均耗时', avg == 0 ? '—' : '${(avg / 1000).toStringAsFixed(1)}s'),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _stat('错题本', '${book.length}'),
              _stat('今日到期', '$due'),
              _stat('累计答对', '$right'),
              _stat('正确率', '$acc%'),
            ],
          ),
          const SizedBox(height: 8),
          Text('记录只存在手机本地，不会上传',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11)),
        ],
      ),
    );
  }

  /// 导出成 CSV 交给系统分享（管理员要看明细、要留档，不能只在 App 里看）。
  Future<void> _exportLog() async {
    final log = widget.state.activityLog;
    if (log == null || log.events.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('还没有记录'), behavior: SnackBarBehavior.floating));
      }
      return;
    }
    try {
      final buf = StringBuffer('时间,类型,结果,耗时ms,模型,tokens,说明\n');
      for (final e in log.events) {
        buf.writeln('${e.time.toIso8601String()},${e.type},${e.ok ? '成功' : '失败'},'
            '${e.latencyMs},${e.model ?? ''},${e.tokens ?? ''},"${e.detail.replaceAll('"', "'")}"');
      }
      final dir = widget.state.filesDir ?? Directory.systemTemp.path;
      final f = File('$dir${Platform.pathSeparator}运行记录.csv');
      await f.writeAsString(buf.toString(), flush: true);
      await widget.state.activityLog?.record('export', detail: '导出运行记录 CSV');
      await widget.state.shareFile(f);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('导出失败：$e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 11)),
          ],
        ),
      );

  Widget _row(ActivityEvent e) => Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: e.ok ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_names[e.type] ?? e.type} · ${e.detail}',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF1E293B))),
                  const SizedBox(height: 3),
                  Text(_meta(e), style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8))),
                ],
              ),
            ),
          ],
        ),
      );

  String _meta(ActivityEvent e) {
    final parts = <String>[_time(e.time)];
    if (e.latencyMs > 0) parts.add('${e.latencyMs} ms');
    if (e.model != null) parts.add(e.model!);
    if (e.tokens != null && e.tokens! > 0) parts.add('${e.tokens} tokens');
    return parts.join(' · ');
  }

  String _time(DateTime t) {
    final d = t.day.toString().padLeft(2, '0');
    final mo = t.month.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '$mo-$d $h:$mi';
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空运行记录'),
        content: const Text('这会删掉手机上这条记录列表（题目和错题本不受影响）。确定吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.state.activityLog?.clear();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清空'), behavior: SnackBarBehavior.floating),
    );
  }
}
