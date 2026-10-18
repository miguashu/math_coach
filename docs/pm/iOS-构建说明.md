# iOS 版构建说明

## 一、先说结论

**iOS 安装包必须在一台 Mac 上构建。** Windows 和 Linux 都不行 —— 这不是"环境没装全"，
装什么都补不上：

| 你手里有什么 | 能不能出 iOS 的 .ipa |
|---|---|
| Windows（本项目当前环境） | ❌ 装什么都没用 |
| Linux | ❌ 同上 |
| macOS + Xcode | ✅ |

原因有三条，每一条都是死结：

1. **编译器只有 Mac 版**。iOS 的二进制要由 Xcode 里的 Apple 工具链（clang + ld + actool）
   产出，没有跨平台的替代品。
2. **iOS SDK 与模拟器只有 Mac 版**。
3. **签名必须用 Apple 的工具**。哪怕你绕开前两条编出了二进制，装到 iPhone 上
   仍要 `codesign` 且需要 Apple 签发的证书 —— 这些工具同样只在 Xcode 里。

网上能搜到"在 Linux 上交叉编译 iOS"的方案，它们依赖**破解出来的 Xcode SDK**，
既违反 Apple 的许可协议，又必须配合一台越狱设备才能装上，不适合家用场景。
所以这里不走那条路。

> 一句话：**这一步不是技术门槛，是 Apple 的商业授权边界。**

---

## 二、不想买 Mac 怎么办：三条路

### 路径 A：iPhone 现在就能用（不需要 Mac）— 推荐先试这条

Web 版和 App 版**共用同一份 Dart 内核**（出题、判分、几何求解、竖式排版、PDF 全在
`lib/` 里），所以手机上看到的东西是一样的，只是外壳从"App"变成"网页 + 主屏图标"。

1. 在**电脑**上双击 `start-lan.bat`（会把局域网地址打出来，形如 `http://192.168.1.17:8787`）
2. **iPhone** 用 **Safari** 打开那个地址
3. 点底部中间的「分享」按钮 → 往下划，选「**添加到主屏幕**」→ 点「添加」
4. 回到桌面，会看到一个蓝色 ∑ 图标。点开是**全屏、无浏览器工具栏**的界面，
   和 App 的手感基本一致

装好之后：

- **能离线用**：题目、判分、错题本、复习、PDF 全部由**电脑上**的服务算，
  手机本身不需要联网（同一 WiFi 就行）
- **数据在电脑上**：不上传任何地方
- **前提**：电脑上的服务得开着；手机和电脑在同一个 WiFi

这条路**今天就能用上**，也是目前唯一不需要 Mac 的方案。

### 路径 B：借 / 租一台 Mac（能出真正的 .ipa）

只要有一台能装 Xcode 的 Mac（哪怕是借来用一个下午），流程已经铺好了：

```bash
cd app
bash tool/build_ios.sh
```

脚本会依次做：`flutter pub get` → `pod install` → `flutter build ios --release --no-codesign`，
跑完会打印装机的详细步骤。

或者手动来：

```bash
cd app
flutter pub get
open ios/Runner.xcworkspace      # 一定要开 .xcworkspace，不是 .xcodeproj
```

然后在 Xcode 里：

1. 左侧选中 **Runner** → **Signing & Capabilities**
2. **Team** 选自己的 Apple ID（免费账号也行）
3. **Bundle Identifier** 改成全世界唯一的名字，例如 `com.你的名字.mathcoach`
   （现在预置的是 `com.mathcoach.app`，和你别人撞名就装不上）
4. iPhone 用数据线插上，顶部设备选择里选它，按 ▶️

**免费 Apple ID 的两个限制**（必须提前知道）：

- 签出来的 App **有效期 7 天**，过期后要重新连电脑装一次
- 最多同时装 3 个自签 App

要长期用、或想发给别的家长装，需要 99 美元/年的 Apple 开发者账号。

没有 Mac 也可以考虑**云 Mac 租用**（搜索"云 Mac"、"MacinCloud"这类关键词）——
按小时或按月计费，能远程操作 Xcode。注意云主机需要能连上你的 iPhone 才能装，
通常的做法是先在云上出 ipa，再用自己电脑上的 AltStore 之类工具侧载。

### 路径 C：等以后有 Mac 再说

工程骨架、Swift 平台通道、图标、Podfile 都已经生成好放在 `app/ios/` 里了
（见下一节），不会因为放着而失效 —— 只是需要跟 Flutter 版本对齐时重跑一次生成脚本。

---

## 三、已经替你准备好的东西

| 内容 | 位置 | 状态 |
|---|---|---|
| iOS 工程骨架（40 个文件） | `app/ios/` | ✅ 从同版本 Flutter SDK 模板渲染 |
| Swift 平台通道（拍照/分享/导入备份） | `app/ios/Runner/AppDelegate.swift` | ⚠️ 未在 Mac 上编译验证 |
| 应用图标（15 张，含 1024×1024） | `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/` | ✅ 品牌蓝 + 白色 ∑ |
| 启动图（3 张） | `.../LaunchImage.imageset/` | ✅ |
| Podfile（platform :ios, '15.0'） | `app/ios/Podfile` | ✅ 与 Flutter 要求的最低版本一致 |
| 一键构建脚本 | `app/tool/build_ios.sh` | ✅ |
| 工程生成脚本 | `app/tool/gen_ios_project.py` | ✅ 可重跑 |

工程骨架不是手写的，而是从 **`flutter_tools/templates/app/ios.tmpl`**（和你用的这套
Flutter SDK 同版本）渲染出来的，所以工程文件与引擎版本天然配套。生成命令：

```bash
python app/tool/gen_ios_project.py
```

### 已经做过的定制

- **只允许竖屏** —— 竖式排版和几何图在横屏下会被压扁（与安卓版一致）
- **显示名「小数辅导」**、界面语言中文优先
- **强制浅色外观** —— 界面是浅色设计，深色模式下启动屏会闪白
- **拍照/相册权限说明文案**（iOS 上不给说明会被系统直接拒）
- **`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`** ——
  导出的练习卷 PDF 能在系统「文件」App 里直接看到

---

## 四、诚实标注：哪些没验证过

本机是 Windows，装不了 Xcode，所以下面这些**只做过人工比对，没有编译验证**：

1. **`AppDelegate.swift` 里的 Swift 平台通道** —— 按安卓侧 `MainActivity.java`
   的接口逐条平移（`filesDir` / `share` / `takePhoto` / `pickImage` / `pickDocument`），
   用到的都是 UIKit 里的常规 API，但没有真正编译过。

   **万一报错的兜底**：把 `AppDelegate.swift` 里这一行注释掉：

   ```swift
   MathCoachChannel.register(with: engineBridge.pluginRegistry)
   ```

   App 仍然能正常启动、出题、判分、复习（这些全在 Dart 内核里），
   只是拍照 / 导出分享 / 备份导入这三样用不了。Dart 侧对这些方法缺失是容错的
   （`app/lib/state.dart` 里对 `MissingPluginException` 做了处理）。

2. **工程能否编译通过** —— 骨架来自官方模板，风险低，但同样没验证过。
3. **在真机 iPhone 上的观感** —— 需要真机才能看。

也就是说：**iOS 版是「准备好了」，不是「确定能用」。** 第一次在 Mac 上构建时，
上面这几处是排查重点。构建成功后，请把结果反馈给我，我再把不确定的地方收紧。

---

## 五、可能在 Mac 上踩的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `pod install` 报找不到 `Generated.xcconfig` | 还没跑 `flutter pub get` | 先 `flutter pub get` 再 `pod install` |
| Xcode 打开 `Runner.xcodeproj` 后看不到 Flutter framework | 开错文件了 | 必须开 **`Runner.xcworkspace`** |
| 编译报 Swift 语法错，指向 `MathCoachChannel` | 通道代码没验证过 | 注释掉注册那一行，先让 App 跑起来 |
| 装到手机后「不受信任的开发者」 | 免费签名需要手动信任 | iPhone：设置 → 通用 → VPN与设备管理 → 信任 |
| 装完 7 天后打不开 | 免费 Apple ID 的签名过期 | 重新连电脑装一次，或买开发者账号 |
| Bundle Identifier 冲突装不上 | 用了预置的 `com.mathcoach.app` | 改成 `com.你的名字.mathcoach` |

---

## 六、和安卓版的关系

两边是**同一个 App**：`lib/` 内核完全共享，差异只在壳子那一层。

| | 安卓 | iOS |
|---|---|---|
| 内核 | `lib/` 纯 Dart | 同一份 |
| 壳 | Kotlin/Java（`app/android/`） | Swift（`app/ios/`） |
| 平台通道 | `MainActivity.java`：`mathcoach/storage` | `AppDelegate.swift`：同名同接口 |
| 出包 | 手工 Python 编排（`app/tool/build_apk.py`） | `flutter build ios`（必须在 Mac） |
| 权限 | 只有 INTERNET | 相机 + 相册（仅拍照识题时用） |
| 数据目录 | App 外部专属目录 | Documents（可在「文件」App 里看到） |

接口定义（两边必须一致，改一处就要改另一处）：

| 方法 | 入参 | 返回 |
|---|---|---|
| `filesDir` | 无 | 数据目录绝对路径 |
| `share` | `path`, `mime` | 是否成功唤起分享面板 |
| `takePhoto` | 无 | 拍到的照片路径 / null |
| `pickImage` | 无 | 相册选中并拷进 App 的路径 |
| `pickDocument` | 无 | 备份文件拷进 App 后的路径 |
