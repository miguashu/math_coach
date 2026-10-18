#!/usr/bin/env bash
# 交互冒烟：冷启动 → 扫点找到「出一套题」→ 确认画面真的变了 → 切到「复习」页。
#
# Flutter 的界面是自绘的，uiautomator 读不到里面的文字，
# 所以这里用「截屏像素是否变化」判断有没有响应 —— 不需要人眼看图。
# 「出一套题」按钮在顶部蓝色选区里，具体 y 随设备密度浮动，
# 于是在候选 y 上依次试，画面一变就停。
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # .../math_coach

export JAVA_HOME='D:\ruanjian\jdk17'
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/workbuddy/android-sdk}}
SDK="$(cygpath -u "$SDK" 2>/dev/null || echo "$SDK")"
ADB="$SDK/platform-tools/adb.exe"
APK="$ROOT/app/build/math-coach-x86_64.apk"
SHOTS_WIN="$(cygpath -w "$ROOT/app/build/shots" 2>/dev/null || echo "$ROOT/app/build/shots")"
mkdir -p "$SHOTS_WIN"

"$ADB" start-server >/dev/null 2>&1
if [ "$("$ADB" devices | grep -c 'emulator-')" -eq 0 ]; then
  echo "=== 启动模拟器 ==="
  "$SDK/emulator/emulator.exe" -avd mc34 \
    -no-audio -no-boot-anim -no-snapshot-save \
    -gpu swiftshader_indirect -memory 2048 > "$SHOTS_WIN/emulator.log" 2>&1 &
  BOOT=""
  for i in $(seq 1 180); do
    BOOT=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [ "$BOOT" = "1" ] && break
    sleep 2
  done
  [ "$BOOT" = "1" ] || { echo "[FAIL] 模拟器没起来"; exit 1; }
  echo "boot ok"
fi
"$ADB" shell svc power stayon true >/dev/null 2>&1
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

shot() { MSYS_NO_PATHCONV=1 "$ADB" shell screencap -p "$1" >/dev/null 2>&1; }

echo "=== 安装 ==="
"$ADB" install -r -t "$APK" 2>&1 | tail -2

echo "=== 冷启动 ==="
MSYS_NO_PATHCONV=1 "$ADB" logcat -c >/dev/null 2>&1
"$ADB" shell am force-stop com.mathcoach.app
"$ADB" shell am start -n com.mathcoach.app/.MainActivity >/dev/null 2>&1
sleep 12
shot /sdcard/base.png
MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/base.png "$SHOTS_WIN/base.png" >/dev/null 2>&1
echo "  基准截图 $(stat -c%s "$SHOTS_WIN/base.png") bytes"

echo "=== 扫描点击「出一套题」 ==="
HIT=""
for Y in 620 700 760 820 880 940 1000 1120 1300 1500 1700; do
  "$ADB" shell input tap 540 "$Y"
  sleep 3
  shot /sdcard/try.png
  MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/try.png "$SHOTS_WIN/try-$Y.png" >/dev/null 2>&1
  if ! cmp -s "$SHOTS_WIN/base.png" "$SHOTS_WIN/try-$Y.png"; then
    echo "  y=$Y 命中：画面发生变化"
    HIT=$Y
    break
  fi
  echo "  y=$Y 无变化"
done
if [ -z "$HIT" ]; then
  echo "  [WARN] 候选点都没触发变化"
else
  # 再点一次（按钮此时变成「换一套题」），确认持续可用
  "$ADB" shell input tap 540 "$HIT"
  sleep 3
  shot /sdcard/again.png
  MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/again.png "$SHOTS_WIN/again.png" >/dev/null 2>&1
  if ! cmp -s "$SHOTS_WIN/try-$HIT.png" "$SHOTS_WIN/again.png"; then
    echo "  OK: 再点一次又换了题目（出题在 AOT 下正常工作）"
  fi
  cp "$SHOTS_WIN/try-$HIT.png" "$SHOTS_WIN/02-practice.png"
fi

echo "=== 切到「复习」页 ==="
"$ADB" shell input tap 216 1850
sleep 3
shot /sdcard/review.png
MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/review.png "$SHOTS_WIN/03-review.png" >/dev/null 2>&1

echo "=== 崩溃检查 ==="
MSYS_NO_PATHCONV=1 "$ADB" logcat -d 2>/dev/null \
  | grep -Ei "FATAL|AndroidRuntime.*mathcoach|NoClassDef|Dart Error|Isolate" | head -5
"$ADB" shell ps -A 2>/dev/null | grep -c mathcoach | sed 's/^/  mathcoach 进程数: /'
echo "=== 完成 ==="
