# 小数辅导 App（Flutter / Android）

一个给家长用的小学数学辅导工具：**出题 → 作答 → 本地批改 → 错题归档 → 间隔复习 → 导出可打印的练习卷**。

全部逻辑（题目生成、答案计算、几何坐标求解、判分、复习调度）都在 `../lib` 的纯 Dart 内核里，
这个 App 只是它的一层 UI。

📖 **逐页说明文档见 [`../docs/app/`](../docs/app/README.md)**（总览 + 四个页面 + 渲染 + 数据模型，共 7 篇）。

---

## 为什么不是用 `flutter build apk` 打的

这台机器的 Dart VM **不能以管道模式 spawn 子进程**：

```
CreateFile failed 231 (所有的管道范例都在使用中)
  at ../../runtime/bin/process_win.cc:744
```

而 `flutter_tools` 内部到处是 `Process.run`，Gradle 又要回头调用 `flutter assemble`
—— 整条官方构建链在这里是断的。

好在限制只作用于 **Dart 起子进程**。`aapt2` / `d8` / `apksigner` / `javac` / `gen_snapshot`
这些命令本身能被正常起起来，所以由 Python 依次调用它们，手工走完同一条流水线：

| 步骤 | 工具 | 产物 |
|---|---|---|
| Dart → kernel | `frontend_server_aot.dart.snapshot`（须用 `dartaotruntime` 跑） | `app.dill` |
| kernel → 原生 | `gen_snapshot`（engine 自带，按架构分包） | `libapp.so` |
| Java → dex | `javac` + `d8` | `classes.dex` |
| 资源与 Manifest | `aapt2 compile` + `aapt2 link` | APK 骨架 |
| 对齐 + 签名 | `zipalign` + `apksigner` | 可安装 APK |

## 构建

```bash
python tool/build_apk.py                  # arm64-v8a，给真机
python tool/build_apk.py --abi x86_64     # x86_64，给 x86 模拟器做验收
python tool/build_apk.py --verbose        # 打印每步完整日志
```

产物：`build/math-coach-<abi>.apk`

### 依赖

**不要手写依赖清单。** `tool/fetch_androidx.py` 会抓 POM 递归展开整棵依赖树，
版本以 Flutter SDK 自带 `examples/platform_view/android/project-app.lockfile`
（Gradle 真实解析出的结果）为准，构件缓存在 `tool/androidx/`，清单落在 `deps.json`。

```bash
python tool/fetch_androidx.py            # 解析（缓存命中就秒回）
python tool/fetch_androidx.py --refresh  # 忽略缓存重来
```

### 验证

```bash
python tool/check_dex.py                 # dex 体检：列出引用了却没定义的类
bash   tool/verify_emulator.sh           # 模拟器冷启动 + 抓崩溃栈
bash   tool/verify_tap.sh                # 交互冒烟：点出题、切页，确认有响应
```

`check_dex.py` 是这套手工流水线里最重要的一个检查：**d8 不会因为"引用的类不存在"报错**，
缺哪个包都能编出一个能安装、能签名通过的 APK，直到设备上那条代码路径被走到才炸。

## 安装

```bash
# 手机开 USB 调试，连上电脑
adb install -r build/math-coach-arm64-v8a.apk
adb shell am start -n com.mathcoach.app/.MainActivity
```

---

## 踩过的坑（每条都真踩过，别再踩一遍）

1. **build-tools 34.0.0 的 d8 会和 Flutter 引擎打架**
   处理 `flutter.jar` 里的 `io/flutter/FlutterInjector$Builder$NamedThreadFactory.class` 时，
   自带的 R8 8.2.2 直接抛 `NullPointerException`。换 build-tools **36.1.0** 解决。
   （不是代码问题，所以报错信息里完全看不出关系。）

2. **androidx 的 KMP artifact 必须取 `-jvm` 变体**
   `lifecycle-common-2.8.7.jar` 只有 8KB，里面是 Kotlin metadata 而不是 class；
   真正能用（含 `LifecycleOwner`）的是 `lifecycle-common-jvm-2.8.7.jar`。
   症状是 "找不到 androidx.lifecycle.LifecycleOwner"，而 jar 明明在 classpath 上。

3. **`-bootclasspath` 会把 JDK 自己的 rt.jar 顶掉**
   于是 `java.lang.invoke.LambdaMetafactory` 消失、lambda 编译不过。
   android.jar 必须放 `-classpath`。

4. **d8 不接受目录作为输入**，必须先把 class 打成 jar，否则报
   `Unsupported source file type`。

5. **`FlutterActivity` 依赖 `LifecycleOwner` 和 `WindowMetricsCalculator`**
   少了前者编译不过；少了后者能编译、能安装，但**启动时才炸**。
   所以 `androidx.window` 是硬依赖，不是可有可无的优化。

6. **libflutter.so 要 STORED 进 APK**（不能用 DEFLATED）
   原生库压缩率低，压缩反而让它不能被 mmap 直接加载。

7. **APK 路径必须是 ASCII**
   `aapt` 打不开中文路径的 APK（`Illegal byte sequence`）。中文文件名是给用户的最后一步，
   校验时要用 ASCII 路径。

8. **依赖清单手写必翻车 —— 这是首版 APK 真机闪退的根因**
   第一版我按"看起来相关"挑了 9 个 androidx 包，漏了整套
   `androidx.core`（`ViewCompat` / `WindowInsetsCompat` / `ContextCompat`）、
   `activity`、`fragment`、`tracing`，以及**根本不在 androidx 名下**的
   `com.getkeepsafe.relinker`（Flutter 3.47 的 `FlutterLoader` 用它加载 `libflutter.so`）。

   症状极具迷惑性：**能编译、能安装、一启动就崩**，而且崩溃栈落在
   `FlutterLoader.ensureInitializationComplete` 里，从栈里完全看不出缺的是哪个库。

   所以改成 POM 递归解析（`fetch_androidx.py`），并且每次构建后跑 `check_dex.py`。
   第一次跑模拟器验证时，就是它把 `relinker` 这条漏网之鱼点出来的。

9. **KMP 变体名同时出现在 URL 路径和文件名上**
   只改文件名不改路径，拼出来的是
   `lifecycle-common/lifecycle-common-jvm-2.8.7.jar`，必然 404 ——
   于是 lifecycle 本体静默缺失。变体名要在两段都替换。

10. **同一个资源包会被多个 AAR 贡献（`core` 与 `core-ktx` 都是 `androidx.core`）**
    分目录编译会让后写的覆盖前者，`values-v21` 引用的 color 在 base `values` 里就找不到了，
    直接 `failed linking references`。必须**按包名合并、低版本先写高版本后写覆盖**。

11. **R 类是链接期产物，jar 里没有**
    `androidx.core.R$id` 这类类由 `aapt2 link --extra-packages` 生成，
    只把 `classes.jar` 打进 dex 会留下空洞，运行时碰到 R 常量就是 `NoClassDefFoundError`。
    所以依赖 AAR 的 `res/` 要一起 `aapt2 compile`，生成的 `R.java` 也要一起 `javac`。

12. **MaterialIcons 字体要自己打包**
    `flutter_tools` 平时自动做这件事，手工链路不做的话，
    UI 里所有 `Icons.xxx` 会渲染成 □ 方块。
    字体在 Flutter SDK 的 `bin/cache/artifacts/material_fonts/`（注意文件名是小写的
    `materialicons-regular.otf`），同时要写进 `FontManifest.json`。

13. **构建脚本里别用 `rmtree` / `os.remove` 清中间产物**
    外部的安全删除守卫会拦下批量删除要求确认，删大文件时甚至能把构建挂死。
    改成"把旧产物挪到 `build/old/`"（`retire()`），效果一样且不触发守卫。

---

## 崩溃自报

真机闪退时手边没有 logcat，所以把最后一道防线做进了 App 自己
（`MainApplication.java`）：

1. 装 `UncaughtExceptionHandler`，把设备信息 + 完整堆栈写进
   `<App 外部目录>/math_coach/crash.txt`
2. 顺手塞进**剪贴板** —— 不需要 root、不需要连电脑，长按粘贴就能把堆栈发出去
3. 下次启动 Toast 提示"上次崩溃已记录"，并把堆栈再复制一次

崩溃发生在主线程时 Toast 往往来不及渲染，所以 3 是主要出口。

---

## 权限

这个 APK **一个权限都没申请**（用 `aapt dump badging` 可以看到 `uses-permission` 一行都没有）。
题目本地生成、答案本地验算、几何坐标本地求解 —— 不联网是设计约束，不是实现细节。
