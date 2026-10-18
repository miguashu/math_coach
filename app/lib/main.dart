import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'floatpad/float_pad.dart';
import 'state.dart';
import 'pages/camera_page.dart';
import 'pages/practice_page.dart';
import 'pages/review_page.dart';
import 'pages/book_page.dart';
import 'pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 竖式/几何题横屏会被压扁，锁竖屏
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final state = AppState();
  await state.init();
  runApp(MathCoachApp(state: state));
}

class MathCoachApp extends StatelessWidget {
  final AppState state;
  const MathCoachApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小数辅导',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2563EB),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
        ),
      ),
      // 浮窗演算板挂在 Navigator 之上：五个 tab 和 push 进来的页面
      // （闯关、练习）都能随时点开验算，不影响页面自身状态。
      builder: (context, child) => Stack(
        children: [
          child!,
          const Positioned.fill(child: FloatPadHost()),
        ],
      ),
      home: _Shell(state: state),
    );
  }
}

class _Shell extends StatefulWidget {
  final AppState state;
  const _Shell({required this.state});

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  /// 五个页面**只建一次**。
  ///
  /// 2026-10-17 家长反馈两条，根因是同一个：
  /// ① "切换 tab 页后拍照页面数据没了" —— 原来每次 build 都 new 一遍
  ///    `CameraPage(...)`，widget 实例变了，State 连带重建，认出来的题全丢；
  /// ② "练习页面切回来后，选择的五年级变成了三年级" —— 同理，
  ///    `grade` 是 PracticePage 的局部字段，重建就回默认值 3。
  ///
  /// 但光"建一次"不够：直接 `pages[_index]` 会在切走时把上一个页面
  /// 从树上摘掉，State 照样被 dispose。所以用 [IndexedStack] ——
  /// 五个页面常驻树上，只显示当前那个。
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    final s = widget.state;
    _pages = [
      CameraPage(state: s),
      PracticePage(state: s),
      ReviewPage(state: s),
      BookPage(state: s),
      SettingsPage(state: s),
    ];
  }

  static const _items = [
    (icon: Icons.photo_camera_outlined, active: Icons.photo_camera, label: '拍照'),
    (icon: Icons.edit_outlined, active: Icons.edit, label: '练习'),
    (icon: Icons.history_edu_outlined, active: Icons.history_edu, label: '复习'),
    (icon: Icons.error_outline, active: Icons.error, label: '错题本'),
    (icon: Icons.picture_as_pdf_outlined, active: Icons.picture_as_pdf, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        // 复习 tab 显示到期角标 —— 不点进去也知道有东西要做
        final dueCount = s.dueQueue().length;
        return Scaffold(
          body: SafeArea(
            child: IndexedStack(index: _index, children: _pages),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              for (var i = 0; i < _items.length; i++)
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: i == 2 && dueCount > 0,
                    label: Text('$dueCount'),
                    child: Icon(_items[i].icon),
                  ),
                  selectedIcon: Icon(_items[i].active),
                  label: _items[i].label,
                ),
            ],
          ),
        );
      },
    );
  }
}
