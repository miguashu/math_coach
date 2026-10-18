#!/usr/bin/env bash
# 在 macOS 上构建 iOS 包。
#
# ⚠️ 这个脚本**只能**在 macOS 上跑。Windows / Linux 上一律不行 ——
#    不是工具链没装，是 Apple 的硬性限制：iOS 应用必须用 Xcode 与
#    苹果的 iOS SDK 签名，而它们只有 macOS 版本。
#    本机（Windows）因此只准备好了工程骨架，构建请在 Mac 上执行。
#    详见 docs/pm/iOS-构建说明.md。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # .../math_coach
APP="$ROOT/app"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ iOS 构建只能在 macOS 上进行（当前系统：$(uname)）。"
  echo
  echo "   替代方案："
  echo "   · iPhone 上先用「添加到主屏幕」的 Web 版（同一份 Dart 内核）"
  echo "       在电脑上跑  start-lan.bat  ，然后用 iPhone Safari 打开提示的地址"
  echo "   · 或者借 / 租一台 Mac，再回来跑这个脚本"
  echo "   详见 docs/pm/iOS-构建说明.md"
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "❌ 找不到 flutter 命令。先装 Flutter SDK 并加进 PATH。"
  exit 1
}

if ! command -v pod >/dev/null 2>&1; then
  echo "⚠️  没找到 CocoaPods —— 下一步 pod install 会失败。"
  echo "   装一下：brew install cocoapods"
fi

cd "$APP"

echo
echo "① 拉 Dart 依赖"
flutter pub get

echo
echo "② 装 iOS 原生依赖（CocoaPods）"
(cd ios && pod install)

echo
echo "③ 构建 release（先不签名，验证能编出来）"
flutter build ios --release --no-codesign

cat <<'EOF'

────────────────────────────────────────────
产物：app/build/ios/iphoneos/Runner.app

装到 iPhone 上，两条路：

A. 直接用 Xcode（适合自己用）
   1. open app/ios/Runner.xcworkspace
   2. 左侧选 Runner → Signing & Capabilities
   3. Team 选自己的 Apple ID（免费账号也行），
      Bundle Identifier 改成全世界唯一的名字（如 com.你的名字.mathcoach）
   4. iPhone 用数据线插上，顶部设备选它，按 ▶️ 运行
   5. 手机上首次运行要去「设置 → 通用 → VPN与设备管理」里信任这个开发者

   注意：免费 Apple ID 签出来的 App **有效期 7 天**，过期要重新连电脑装一次。
         想长期用需要 99 美元/年的开发者账号。

B. 出 ipa 包（方便分发给别人装）
   flutter build ipa --export-method development
   产物在 build/ios/ipa/ ，配合 Apple Configurator 或 AltStore 安装。

签名遇到问题先看：docs/pm/iOS-构建说明.md 的「可能在 Mac 上踩的坑」
────────────────────────────────────────────
EOF
