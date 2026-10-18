package io.flutter.plugins;

/**
 * 空的插件注册器。
 *
 * FlutterActivity 启动时会自动找 io.flutter.plugins.GeneratedPluginRegistrant
 * 并调用 registerWith —— 这个类平时由 flutter_tools 根据插件清单生成。
 * 本 App 刻意零插件（题目、判分、PDF 全在本地），但类不存在的话
 * logcat 每次启动都会刷一遍 ClassNotFoundException，看着像出了问题。
 * 给它一个空实现，语义与事实一致：没有插件可注册。
 */
public class GeneratedPluginRegistrant {
    public static void registerWith(io.flutter.embedding.engine.FlutterEngine engine) {
        // 零插件：这里刻意什么都不做
    }
}
