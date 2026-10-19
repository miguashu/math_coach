# 小学数学辅导（math_coach）

一个**纯本地运行**的家长辅导工具：出题、判分、错题归档、间隔复习、
导出打印卷 —— 全部在本机完成，数据不出门，模型不参与给任何一个数字。

## 第一次跑起来

```bat
copy .env.example .env
```

把 `.env` 里的 `MATH_COACH_API_KEY` 换成你自己的 key，然后双击 `start.bat`。

> **为什么这步不能省**：本仓库是公开的，**源码里任何地方都不放明文 API key**。
> key 是通过编译期注入進来的（Dart 的 `String.fromEnvironment`）：
>
> | 场景 | 怎么注入 |
> |---|---|
> | 本地服务（`start.bat` / `start-lan.bat`） | 脚本自动从 `.env` 读，转成 `-D` 传给 Dart VM |
> | 打包 APK（`app/tool/build_apk.py`） | 同上，手印发进 kernel 编译那一步 |
>
> 有 `test/ai_manual.dart` 盯着这件事（"源码不含明文 key"是一条断言），
> 谁手滑把 key 写死回去都会被测试逮住。
>
> 不配 key 也能用：出题、判分、错题本、复习、导出这些**离线能力全部照常**，
> 只有"拍照识题 / AI 分步讲解"需要联网 —— 那部分可以在 App 设置页手动填 key。

## 成品怎么用

双击 `start.bat`（它会启动本地服务并自动打开浏览器），然后：

1. **练习**：选年级（1–6）和知识点 → 出一套题 → 孩子作答 → 提交批改。
   答错自动给出**像老师说话的分步讲解**，并进入错题本。
2. **错题本**：按"重要度"排序——错得多、最近又没答对的排前面。
   答对会衰减，连续答对 3 次归零（拒绝"错一次+1"的单调累加）。
3. **复习**：间隔按 **FSRS-6** 调度，答对往后推、答错立刻回到队首；
   答对的题可以自评「有点难 / 会了 / 很简单」，直接决定下次什么时候再见。
4. **导出 PDF**：错题练习卷 / 答案页 / 今日复习卷，矢量图形 + 内嵌中文字体，
   直接打印。

判分很宽容：`9……2`、`9余2`、全角数字、带单位、一位小数的四舍五入都能判对。

服务只监听 `127.0.0.1`，数据存在 `~/.math_coach/wrongbook.json`。

## 技术形态与原因

**Dart 内核 + 本地 HTTP 服务 + 浏览器 UI**（`bin/serve.dart` + `web/`）。

** APK 也已经有了**（见下面 §Android App），两套形态共用同一份内核。

当初先做 Web 而不是 APK 的原因：本机 Dart 无法以管道模式 spawn 子进程
（`CreateFile failed 231`），而 flutter_tools 内部全是 `Process.run`、
Gradle 还要回头调 `flutter assemble`，官方链路断在这里。
后来用手编流程绕开了它 —— 但正因为卡过，App 的全部核心（出题、判分、调度、组卷）
本来就在这个纯 Dart 内核里，Web 只是它的一层皮，
所以 Flutter 那一层是**直接消费同一份 `lib/`**，一个数字都不重算。

架构分层（同方案文档）：

```
语义 DSL（FigureSpec）─┬─→ FigureSolver 本地求解 ─→ FigureScene
                       │                              ├─→ PDF 矢量（打印）
VerticalTypeset（竖式）─┤                              ├─→ SVG（屏幕）
                       └─→ 答案本地算（Rational 精确有理数）└─→ 未来 Flutter Canvas
```

- 模型只负责"讲人话"的分步讲解文案；**数字全部本地随机、答案全部本地算**
- 几何题过正确性闸门：鞋带公式 + Pick 定理交叉验证、展开图折叠 BFS 校验、
  不出负数/无限小数/自交多边形
- 错题记录存的是**题目参数**（FigureSpec JSON / 竖式 kind+args），导出时按
  PDF 精度重新求解重画，而不是把屏幕截图塞进试卷

## 验证（全绿）

| 检查 | 数量 | 命令 |
|---|---|---|
| 几何引擎单测 | 26 | `dart test/geometry_solver_test.dart` |
| 内核单测（有理数/竖式/闸门/FSRS） | 32 | `dart test/core_test.dart` |
| 出题器自检（6 个年级 × 40 题 + 判分宽容度） | 240 | `dart tool/gen_check.dart` |
| 端到端（出卷→判分→归档→衰减→调度→持久化→PDF） | — | `dart tool/e2e_check.dart` |
| 浏览器 UI 全流程（出题→作答→批改→错题本→复习） | — | `node tool/e2e_ui.cjs`（需服务在跑） |

## 目录

```
bin/serve.dart          本地服务 + API（出题/批改/错题本/复习/导出）
web/                    前端（index.html + app.css + app.js，无框架）
lib/core/               Pt / Rational（精确有理数）
lib/knowledge/          1–6 年级知识点树（人教版学期/单元）+ 四层匹配索引
lib/geometry/           语义 DSL + 求解器 + 双渲染器（PDF 矢量 / SVG）
lib/typeset/            竖式网格模型 + PDF 渲染
lib/render/             竖式 SVG 渲染
lib/quiz/               出题器（22 个题型）+ 判分规范化
lib/review/fsrs.dart    FSRS-6 间隔调度 + 四级评分 + 重要度衰减
lib/export/             组卷 + PDF 导出
lib/store/              错题本仓库（JSON 持久化）
tool/                   自检脚本（gen_check / e2e_check / make_sample_pdf）
```

## 还没做的（诚实清单）

> 这份清单会过时，所以每条都写清「卡在哪 / 为什么不急」。
> 划掉的几条是**曾经写在这里、后来做完了**的 —— 留着是为了让进度可审计，
> 也提醒自己：改完代码要回头改文档，否则公开仓库里会写着与实现相反的话。

**仍未做（2 条）**

- **SQLite —— 现在每次作答都全量重写 `wrongbook.json`**。
  几百条没问题，上千条会卡。但不急：**没人真能攒到上千条错题**（一学期也就几百道）。
  真到那天再换不迟 —— `ReviewRecord` 的 `toMap` / `fromMap` 已经是齐的，换存储不动上层。
- **拍照识题的本地（离线）模型 —— 现在必须联网**。
  走的是云端视觉模型（`lib/ai/ocr.dart`，一图多题 ≤8 道，主模型挂了自动降级一次备胎）。
  离线方案调研过：`Pix2Text` 这类公式 OCR 是 PyTorch/ONNX，
  会把 26.5 MB 的 APK 撑到几百 MB，和瘦身目标正面冲突 —— **不采纳**，宁可要联网。

**已经做完（原本写在这份清单里）**

| 原条目 | 现在的状态 |
|---|---|
| Flutter 屏幕端 / APK「被本机构建环境阻塞」 | ✅ 手编流程绕开了阻塞：`python app/tool/build_apk.py --abi arm64-v8a`，**26 MB**，每次构建后 `check_dex.py` 报「缺失（会崩）= 0」。做法见下面 §构建 |
| 讲解接大模型「目前是模板化的」 | ✅ **两条路径，缺一不可**：拍照识题来的题走大模型（`lib/ai/solver.dart`，≥2 步闸门、答案本地复算验算）；本地题库那 22 个题型**仍用模板** —— 这是刻意的，理由见下 |
| 识题解析 JSON 规范解析器 | ✅ `PhotoReader._parse()`，一张图返回 `{"items":[{stem,notes}]}`，兼容旧的单题格式 |

**为什么本地题库的讲解故意留着模板**：模型给的讲解没法本地校验对错，
而模板讲解和答案是**同一份代码从同一组数字算出来的**，两者必然一致。
对小学生来说「讲解和答案对不上」是最致命的 —— 那不是讲得差，是讲错了。
拍照来的题没有本地模板可用，才走模型，且必须过验算那道闸。

## 已踩过的坑

1. `pw.CustomPaint` 的 PdfGraphics 是 **y 向上**（左下原点），别翻转。
2. pdf 包的 `drawLine()` 只记录路径**不描边**，必须手动 `strokePath()`。
3. 图形渲染 padding 必须用 pt 固定值，按数学单位算会把小图形压成一团。
4. 正交多边形边界与网格线重合，必须粗线+阴影才可辨。
5. MultiPage 会拆 Column，每题要用不可拆分的 Row 包裹。
6. Dart Record 不能直接 `jsonEncode`，先摊平成 Map。
7. **改完代码要回头改文档**。上面「诚实清单」里有两条（"APK 被本机构建环境阻塞"、
   "讲解目前是模板化的"）在功能做完之后很久还保持着原样 —— 公开仓库里写着
   和实现相反的话，比不写更糟。所以现在清单里**保留已完成的条目并标注现状**，
   让进度可审计，也让下一次改代码的人想起来这里有东西要同步。

---

## Android App（`app/`）

除了本地服务版，现在还有一个**真正能装到手机上的 Android App**（Flutter 写的）：

```
python app/tool/build_apk.py                 # arm64-v8a，给真机
python app/tool/build_apk.py --abi x86_64    # x86_64，给模拟器验收
adb install -r app/build/math-coach-arm64-v8a.apk
```

内核还是同一份 `lib/`，App 只是 UI —— **不多产生一个数字**（题目、答案、图形全是本地算的）。
权限清单里**只有一条 `INTERNET`**，而且只有「拍照识题 / AI 分步讲解 / AI 出题」这三项才用得到它；
不填 key 的话，出题、判分、归档、复习、导出 PDF 全套离线可用。
拍照不申请 `CAMERA` —— 走系统相册选图（`ACTION_GET_CONTENT`），由相册 App 拿图回传路径。

**这不是用 `flutter build apk` 打的。** 这台机器的 Dart VM 不能以管道模式
spawn 子进程（`CreateFile failed 231`），而 flutter_tools 内部全是 `Process.run`、
Gradle 还要回头调 `flutter assemble`，官方链路断在这里。所以由 Python 手工编排：

`frontend_server → app.dill` → `gen_snapshot → libapp.so` → `javac + d8 → classes.dex`
→ `aapt2 link` → 打包 `libflutter.so`/`flutter_assets` → `zipalign + apksigner`。

完整的踩坑记录（build-tools 版本冲突、androidx 的 `-jvm` 变体陷阱、
`-bootclasspath` 顶掉 JDK 的 Lambda 元工厂……）写在 `app/README.md`，
别归结为"环境问题"就略过 —— 那几条都是花了时间才看穿的。
