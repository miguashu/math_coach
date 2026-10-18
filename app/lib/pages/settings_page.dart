import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:math_coach/store/backup.dart';
import 'package:math_coach/store/repository.dart';

import '../state.dart';
import '../widgets/ai_settings.dart';
import '../widgets/export_sheet.dart';
import 'admin_page.dart';

/// 导出/设置：一键把错题本变成可以打印的练习卷。
///
/// 试卷里的图是**重新求解渲染的矢量图**，不是把屏幕截图塞进去 ——
/// 这是这个工具从一开始就没打算妥协的一点：打印出来必须和屏幕上一样清楚。
class SettingsPage extends StatefulWidget {
  final AppState state;
  const SettingsPage({super.key, required this.state});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ByteData? _font;
  String? _fontError;
  bool _busy = false;
  String? _lastPath;

  @override
  void initState() {
    super.initState();
    _loadFont();
  }

  Future<void> _loadFont() async {
    final d = await loadChineseFont();
    if (!mounted) return;
    setState(() => _font = d);
    if (d == null) {
      // 字体缺失会让导出的 PDF 出现空白汉字，所以要禁用导出按钮。
      // 但光禁用不够 —— 用户会看到一个点不动的灰色按钮，不知道是没做完还是坏了。
      // 所以这里把原因显示出来，见 build() 底部的提示区。
      setState(() => _fontError = '中文字体加载失败，暂时无法导出 PDF');
    }
  }

  Future<void> _export({required String title, required List<ReviewRecord> records}) async {
    if (_font == null) {
      _toast('缺少中文字体资源，无法导出');
      return;
    }
    if (records.isEmpty) {
      _toast('没有可以导出的题目');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      final f = await widget.state.exportPaper(
        title: title,
        records: records,
        fontData: _font,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastPath = f.path;
      });
      await showExportSheet(
        context,
        file: f,
        title: title,
        count: records.length,
        state: widget.state,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导出失败：$e');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 导出备份：写到 App 目录后直接唤起系统分享面板。
  ///
  /// 光"写到目录里"不够 —— 那个目录卸载时就一起没了，
  /// 等于没备份。必须让用户把它送到微信/邮件/网盘去。
  Future<void> _exportBackup() async {
    if (widget.state.totalCount == 0) {
      _toast('还没有任何记录，没什么可备份的');
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await widget.state.exportBackup();
      if (!mounted) return;
      setState(() => _busy = false);
      // octet-stream 而不是 application/json：微信/邮件对"任意文件"的
      // 接收注册更宽，json 会被一部分 ROM 的分享面板直接过滤掉
      await widget.state.shareFile(f, mime: 'application/octet-stream');
      _toast('已生成备份（${widget.state.totalCount} 条），请选择微信/邮件/网盘存好');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('备份失败：$e');
    }
  }

  Future<void> _importBackup() async {
    setState(() => _busy = true);
    try {
      final p = await widget.state.pickBackup();
      if (!mounted) return;
      if (p == null) {
        setState(() => _busy = false);
        _toast('没有选择文件。找不到？在系统选择器里切到「文件管理」再试。');
        return;
      }
      final r = await widget.state.importBackupFromFile(File(p));
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('恢复完成：${r.added} 条新增，${r.merged} 条与现有记录合并');
    } on BackupError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('恢复失败：$e');
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部学习记录？'),
        content: const Text(
          '错题本、重要度、复习进度都会被删除，\n删了就找不回来了。\n\n建议先导出一份练习卷留底。',
          style: TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.state.clearAll();
      _toast('已清空');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final book = s.book;
    final due = s.dueQueue();

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: [
        const _SectionTitle('AI（拍照识题 / 分步讲解）'),
        const SizedBox(height: 8),
        AiSettings(state: s),
        const SizedBox(height: 10),
        _ExportTile(
          icon: Icons.analytics_outlined,
          title: '运行记录（管理员）',
          subtitle: '看识别/讲解/出题的成功率、耗时与失败原因',
          enabled: true,
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => AdminPage(state: s))),
        ),

        const SizedBox(height: 22),
        const _SectionTitle('导出练习卷'),
        const SizedBox(height: 8),
        _ExportTile(
          icon: Icons.menu_book_outlined,
          title: '错题练习卷',
          subtitle: '按重要度排前面、答错多的优先（共 ${book.length} 题）',
          enabled: book.isNotEmpty && !_busy && _font != null,
          onTap: () => _export(title: '错题练习卷', records: book),
        ),
        const SizedBox(height: 10),
        _ExportTile(
          icon: Icons.today_outlined,
          title: '今日复习卷',
          subtitle: '只出到期的题（现在 ${due.length} 道）',
          enabled: due.isNotEmpty && !_busy && _font != null,
          onTap: () => _export(title: '今日复习卷', records: due),
        ),
        const SizedBox(height: 10),
        if (_lastPath != null)
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 17, color: Color(0xFF16A34A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '上次导出：$_lastPath',
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF166534)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 22),
        const _SectionTitle('数据'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.folder_outlined, size: 20, color: Color(0xFF64748B)),
                title: const Text('数据位置', style: TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  s.filesDir ?? '（未就绪）',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
                dense: true,
              ),
              ListTile(
                leading: const Icon(Icons.backup_outlined, size: 20, color: Color(0xFF64748B)),
                title: const Text('导出备份（JSON）', style: TextStyle(fontSize: 13.5)),
                subtitle: const Text(
                  '含复习进度与重要度 · 卸载 App 前务必导一份',
                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
                dense: true,
                enabled: !_busy && s.totalCount > 0,
                onTap: _exportBackup,
              ),
              ListTile(
                leading: const Icon(Icons.restore_outlined, size: 20, color: Color(0xFF64748B)),
                title: const Text('从备份恢复', style: TextStyle(fontSize: 13.5)),
                subtitle: const Text(
                  '选一份之前导出的 JSON · 与现有记录合并，不会覆盖',
                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
                dense: true,
                enabled: !_busy,
                onTap: _importBackup,
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined,
                    size: 20, color: Color(0xFFDC2626)),
                title: const Text('清空学习记录',
                    style: TextStyle(fontSize: 13.5, color: Color(0xFFDC2626))),
                dense: true,
                onTap: _confirmClear,
              ),
            ],
          ),
        ),

        const SizedBox(height: 22),
        const _SectionTitle('关于'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Point(
                icon: Icons.wifi_off,
                text: '题目在本机随机生成，答案在本机精确计算，\n全程不需要联网。',
              ),
              SizedBox(height: 10),
              _Point(
                icon: Icons.calculate_outlined,
                text: '几何图形的坐标由本地求解器算出，\n不是模型画的坐标 —— 所以换数字也依然是对的。',
              ),
              SizedBox(height: 10),
              _Point(
                icon: Icons.print_outlined,
                text: '导出的 PDF 是真矢量图，A4 打印不会糊。',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_fontError != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFECACA)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _fontError!,
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFFB91C1C), height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        if (widget.state.error != null)
          Text(
            '注意：${widget.state.error}',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626)),
          ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFF64748B),
        letterSpacing: 0.4,
      ),
    );
  }
}

class _ExportTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const _ExportTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: enabled ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: enabled ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: enabled ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: enabled ? const Color(0xFF94A3B8) : const Color(0xFFE2E8F0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: const Color(0xFF2563EB)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569), height: 1.6),
          ),
        ),
      ],
    );
  }
}

