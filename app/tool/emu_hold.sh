#!/usr/bin/env bash
# 把模拟器拉起来并保持在线，方便手动逐项验收（截图、点按钮、看日志）。
#
# 为什么要单独一个脚本：验收脚本一结束，作为子进程起的 emulator 会被一起回收，
# 想接着手动点几下就没得点了。这里起完模拟器后原地等待，
# 你用 adb 连着操作即可；Ctrl+C 结束。
#
# 用法：  bash app/tool/emu_hold.sh            # 起模拟器并保持
#        bash app/tool/emu_hold.sh --no-boot   # 已在跑，只等待
set -u

SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/workbuddy/android-sdk}}
SDK="$(cygpath -u "$SDK" 2>/dev/null || echo "$SDK")"
ADB="$SDK/platform-tools/adb.exe"

# AVD 2026-10-16 搬到了 D:\workbuddy\avd，而这套脚本跑在 WorkBuddy 起的 bash 里，
# 未必继承得到 User 级的 ANDROID_AVD_HOME —— 不显式指过去的话
# emulator 会报 "Unknown AVD name" 直接退出。
AVD_NAME=mc34
AVD_HOME="${ANDROID_AVD_HOME:-}"
if [ -z "$AVD_HOME" ]; then
  for cand in /d/workbuddy/avd "$HOME/.android/avd"; do
    [ -d "$cand/$AVD_NAME.avd" ] && { AVD_HOME="$cand"; break; }
  done
  AVD_HOME="${AVD_HOME:-$HOME/.android/avd}"
fi
AVD_HOME_WIN="$(cygpath -w "$AVD_HOME" 2>/dev/null || echo "$AVD_HOME")"
export ANDROID_AVD_HOME="$AVD_HOME_WIN"
echo "AVD 目录: $AVD_HOME"
SHOTS_WIN="$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)/build/shots" 2>/dev/null)"
mkdir -p "$(cd "$(dirname "$0")/.." && pwd)/build/shots"

"$ADB" start-server >/dev/null 2>&1

if [ "${1:-}" != "--no-boot" ]; then
  if [ "$("$ADB" devices | grep -c 'emulator-')" -eq 0 ]; then
    echo "=== 启动模拟器 ==="
    nohup "$SDK/emulator/emulator.exe" -avd "$AVD_NAME" \
      -no-audio -no-boot-anim -no-snapshot-save \
      -gpu swiftshader_indirect -memory 2048 > "$SHOTS_WIN/emulator.log" 2>&1 &
    echo "emulator pid=$!"
  fi
fi

for i in $(seq 1 180); do
  if [ "$("$ADB" devices | grep -c 'emulator-')" -gt 0 ]; then break; fi
  sleep 2
done
for i in $(seq 1 180); do
  BOOT=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
  [ "$BOOT" = "1" ] && break
  sleep 2
done
"$ADB" shell svc power stayon true >/dev/null 2>&1
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
echo "=== 模拟器已就绪（保持在线，Ctrl+C 退出）==="
"$ADB" devices

# 原地等待：把 emulator 拉成子进程后必须让父进程活着，否则会被一起回收
sleep 3000
