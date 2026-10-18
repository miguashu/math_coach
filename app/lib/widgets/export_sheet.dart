/// 导出 PDF 的共用一块：加载中文字体 + 结果面板 + 唤起分享。
///
/// 为什么抽出来（2026-10-17 家长反馈"pdf 导出不太明显"）：
/// 原来导出只能从「设置」页进，入口埋在第四层；而且每个要导出的页面
/// 都各写了一遍"加载字体 → 生成 → 弹面板 → 分享"。
/// 抽成共享组件后，错题本页和练习页也能放一个**看得见的按钮**，
/// 行为还完全一致（同一个字体、同一句话、同一条分享路径）。
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state.dart';

/// 加载内嵌中文字体。失败返回 null —— 调用方要能提示"缺字体"，
/// 而不是导出一份汉字全空白的卷子。
Future<ByteData?> loadChineseFont() async {
  try {
    return await rootBundle.load('assets/fonts/simhei.ttf');
  } catch (_) {
    return null;
  }
}

/// 导出成功后的结果面板：说清生成了什么、文件在哪，一键分享/打印。
///
/// [file] 用 dynamic 是为了让调用方少写一个 import（File 就够）。
Future<void> showExportSheet(
  BuildContext context, {
  required dynamic file,
  required String title,
  required int count,
  required AppState state,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: false,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 22),
                const SizedBox(width: 9),
                Text('已生成 $title',
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '共 $count 题。图形是按打印精度重新求解绘制的矢量图，\n直接打印很清楚。',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.6),
            ),
            const SizedBox(height: 8),
            Text(
              '${file.path}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: FilledButton.icon(
                onPressed: () {
                  state.shareFile(file as File);
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.share, size: 17),
                label: const Text('发给微信 / 打印机',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
