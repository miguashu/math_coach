/// 送给模型之前的图片预处理：**缩尺寸 + 压成 JPEG**。
///
/// 为什么单独一个文件（2026-10-17 家长反馈"拍照识题速度太慢了"）：
/// 原来两处（拍照识题、拍照判卷）各自把图缩到 1024px 后编码成 **PNG**。
/// dart:ui 只能编 PNG，而 PNG 对**照片**几乎是灾难 ——
/// 实测一张 1024px 的拍照风格图（带噪点/阴影，接近真实纸张照片）：
///
/// | 格式 | 大小 |
/// |---|---|
/// | PNG | 1935 KB |
/// | JPEG q72 | 265 KB（**小 7.3 倍**） |
///
/// 顺带还修了一个隐患：`lib/ai/llm.dart` 里 data URL 写的是 `data:image/jpeg`，
/// 也就是"声明 JPEG、实际发 PNG"—— 一部分服务端会拒收或走兜底解码。
/// 所以改成真 JPEG 是**又小又更对**，不是单纯省流量。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// 和 `MainActivity` 里同名的那个频道（state.dart 里那份是私有的，这里单开一个）。
const _channel = MethodChannel('mathcoach/storage');

/// 把照片预处理成模型能吃的 base64 JPEG。
///
/// 优先走 Android 原生 `Bitmap.compress(JPEG)`；宿主不在（桌面/自测）或压坏了，
/// 退回 dart:ui 的 PNG 兜底 —— 兜底只是慢，不能让拍照整个失败。
///
/// 返回 null 表示这张图读不了（文件损坏或不是图），调用方应提示重拍。
Future<String?> encodeForModel(
  File f, {
  int maxWidth = 1024,
  int quality = 72,
}) async {
  try {
    final b64 = await _channel.invokeMethod<String>('jpegBase64', {
      'path': f.path,
      'maxWidth': maxWidth,
      'quality': quality,
    });
    if (b64 != null && b64.isNotEmpty) return b64;
  } on MissingPluginException {
    // 没有宿主（桌面/单元测试）：走下面的 PNG 兜底
  } catch (_) {
    // 宿主里压坏了（文件损坏等）：同样走兜底，别让拍照整个失败
  }
  return _pngFallback(f, maxWidth: maxWidth);
}

/// 兜底：dart:ui 只能编码 PNG，所以这里保持原来的行为。
Future<String> _pngFallback(File f, {required int maxWidth}) async {
  final bytes = await f.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: maxWidth);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  return base64Encode(png!.buffer.asUint8List());
}
