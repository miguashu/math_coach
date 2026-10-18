#!/usr/bin/env bash
# 在 x86_64 模拟器上跑一遍 App：安装 → 启动 → 抓崩溃 → 截图。
#
# 必须**一次跑完**：adb server 会随 shell 结束被回收，每次 Bash 调用都是新 shell，
# 分段执行的话 emulator 起来了 adb 也连不上。
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # .../math_coach

export JAVA_HOME='D:\ruanjian\jdk17'
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/workbuddy/android-sdk}}
SDK="$(cygpath -u "$SDK" 2>/dev/null || echo "$SDK")"
ADB="$SDK/platform-tools/adb.exe"
# 2026-10-16 AVD 从 %HOME%\.android\avd 搬到了 D:\workbuddy\avd（C 盘没空间了）。
# 注意两点，都是这次踩出来的：
#   1) emulator 的 -avd 只认**名字**，不认路径 —— 根目录与名字得分开两个变量。
#   2) 不能只依赖 ANDROID_AVD_HOME：从 WorkBuddy 起的 bash 未必继承得到，
#      解析到旧目录就会误判成「没有 AVD」再去现建一台（几分钟前刚这样干过）。
#      所以候选目录按「是否存在该 AVD」来挑，而不是只认环境变量。
AVD_NAME=mc34
AVD_HOME="${ANDROID_AVD_HOME:-}"
if [ -z "$AVD_HOME" ]; then
  for cand in /d/workbuddy/avd "$HOME/.android/avd"; do
    if [ -d "$cand/$AVD_NAME.avd" ]; then AVD_HOME="$cand"; break; fi
  done
  AVD_HOME="${AVD_HOME:-$HOME/.android/avd}"
fi
AVD_DIR="$(cygpath -u "$AVD_HOME/$AVD_NAME.avd" 2>/dev/null || echo "$AVD_HOME/$AVD_NAME.avd")"
AVD_HOME_WIN="$(cygpath -w "$AVD_HOME" 2>/dev/null || echo "$AVD_HOME")"
export ANDROID_AVD_HOME="$AVD_HOME_WIN"
IMG="system-images;android-34;default;x86_64"
APK="$ROOT/app/build/math-coach-x86_64.apk"
APPDIR="$ROOT/app"
APPDIR_WIN="$(cygpath -w "$ROOT/app" 2>/dev/null || echo "$ROOT/app")"
SHOTS=$APPDIR/build/shots
SHOTS_WIN="$(cygpath -w "$ROOT/app/build/shots" 2>/dev/null || echo "$ROOT/app/build/shots")"
mkdir -p "$SHOTS"

echo "=== 1) AVD ==="
echo "AVD 目录: $AVD_DIR"
if [ ! -d "$AVD_DIR" ]; then
  echo "没找到 $AVD_NAME，新建一台（约需下载系统镜像 1.2G）"
  echo no | "$SDK/cmdline-tools/latest/bin/avdmanager.bat" create avd \
    -n "$AVD_NAME" -k "$IMG" -d pixel_2 --force 2>&1 | tail -5
else
  echo "AVD $AVD_NAME 已存在"
fi

echo "=== 2) 启动 emulator ==="
# 模拟器会在 %TEMP%、~/.android 里写几百 MB 的临时与缓存。
# C 盘只剩 2G 时它启动几秒就自己退出（adb devices 永远空），
# 而且不报错 —— 排查成本极高。所以在这里把这两处都指到 D 盘。
# ANDROID_AVD_HOME 已指向 D:\workbuddy\avd，这里改 ANDROID_USER_HOME 不会丢 AVD。
mkdir -p "$APPDIR/build/tmp"
TMP_WIN="$(cygpath -w "$ROOT/app/build/tmp" 2>/dev/null || echo "$ROOT/app/build/tmp")"
export TMP="$TMP_WIN" TEMP="$TMP_WIN" TMPDIR="$TMP_WIN"
export ANDROID_USER_HOME="$APPDIR_WIN/build/avd-home"
# emulator 的输出必须重定向到**文件**：
# 接进管道的话，一旦缓冲写满或读端关闭，模拟器会被直接杀掉，
# 症状是"启动过 3 秒就消失，adb devices 永远空"。
"$SDK/emulator/emulator.exe" -avd "$AVD_NAME" \
  -no-audio -no-boot-anim -no-snapshot-save \
  -gpu swiftshader_indirect -memory 2048 > "$SHOTS/emulator.log" 2>&1 &
EMU_PID=$!
echo "emulator pid=$EMU_PID (日志: $SHOTS/emulator.log)"

# adb daemon 起来后才能连
"$ADB" start-server >/dev/null 2>&1
for i in $(seq 1 60); do
  if "$ADB" devices 2>/dev/null | grep -q "emulator-\|device$" | head -1; then break; fi
  sleep 2
done

echo "=== 3) 等待系统启动完成（最多 6 分钟）==="
BOOT=""
for i in $(seq 1 180); do
  BOOT=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
  if [ "$BOOT" = "1" ]; then echo "boot_completed (${i}0s)"; break; fi
  sleep 2
done
if [ "$BOOT" != "1" ]; then
  echo "[FAIL] 模拟器没能启动完（很可能没有可用的虚拟化加速）"
  "$ADB" devices
  kill $EMU_PID 2>/dev/null
  exit 1
fi

# 常亮，避免闲置熄屏导致"看起来像崩了"的黑截图
"$ADB" shell svc power stayon true >/dev/null 2>&1
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
"$ADB" shell input keyevent 82 >/dev/null 2>&1   # 解锁（有锁屏时）

echo "=== 4) 安装 APK ==="
"$ADB" install -r "$APK" 2>&1 | tail -4
"$ADB" shell pm list packages 2>/dev/null | grep mathcoach

echo "=== 5) 清日志后冷启动 ==="
MSYS_NO_PATHCONV=1 "$ADB" logcat -c >/dev/null 2>&1
"$ADB" shell am start -n com.mathcoach.app/.MainActivity 2>&1 | tail -2
sleep 12

echo "=== 6) 截图 ==="
MSYS_NO_PATHCONV=1 "$ADB" shell screencap -p /sdcard/shot_main.png >/dev/null 2>&1
MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/shot_main.png "$SHOTS_WIN/01-main.png" 2>&1 | tail -1
SIZE=$(stat -c%s "$SHOTS/01-main.png" 2>/dev/null || echo 0)
echo "截图大小: $SIZE bytes"
if [ "$SIZE" -lt 1000 ]; then
  echo "[WARN] 截图 0 字节 —— 多半是模拟器静默挂了，不是界面空"
fi

echo "=== 7) 崩溃日志 ==="
MSYS_NO_PATHCONV=1 "$ADB" logcat -d -t 400 2>/dev/null \
  | grep -Ei "flutter|mathcoach|AndroidRuntime|FATAL|NoSuchMethod|NoClassDef|MissingPlugin|Exception" \
  | head -30

echo "=== 8) 进程状态 ==="
"$ADB" shell ps -A 2>/dev/null | grep mathcoach || echo "[FAIL] 进程里没有 mathcoach —— App 没起来"

echo "=== 完成 ==="
echo "kill=$EMU_PID（脚本退出后 emulator 仍在后台跑，方便继续手动验证）"
