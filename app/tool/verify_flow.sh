#!/usr/bin/env bash
# 在模拟器上把核心流程点一遍：冷启动 → 点「出一套题」→ dump 界面确认出了题。
#
# 为什么不只看截图：出题、判分跑在 AOT 编译的 Dart 机器码里，
# 只有真的点一遍才知道内核在 release 下工作正常。
# 和 verify_emulator.sh 同样的约束：必须一次跑完，分段执行 adb 会断。
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # .../math_coach

export JAVA_HOME='D:\ruanjian\jdk17'
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/workbuddy/android-sdk}}
SDK="$(cygpath -u "$SDK" 2>/dev/null || echo "$SDK")"
ADB="$SDK/platform-tools/adb.exe"
APK="$ROOT/app/build/math-coach-x86_64.apk"
SHOTS_WIN="$(cygpath -w "$ROOT/app/build/shots" 2>/dev/null || echo "$ROOT/app/build/shots")"

echo "=== 启动模拟器（如已在跑则复用） ==="
DEVS=$("$ADB" devices | grep -c "emulator-")
if [ "$DEVS" -eq 0 ]; then
  "$SDK/emulator/emulator.exe" -avd mc34 \
    -no-audio -no-boot-anim -no-snapshot-save \
    -gpu swiftshader_indirect -memory 2048 > "$SHOTS_WIN/emulator.log" 2>&1 &
  "$ADB" start-server >/dev/null 2>&1
  BOOT=""
  for i in $(seq 1 180); do
    BOOT=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [ "$BOOT" = "1" ] && break
    sleep 2
  done
  [ "$BOOT" = "1" ] || { echo "[FAIL] 模拟器没起来"; exit 1; }
fi
"$ADB" shell svc power stayon true >/dev/null 2>&1
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

echo "=== 安装 + 冷启动 ==="
"$ADB" install -r -t "$APK" 2>&1 | tail -2
MSYS_NO_PATHCONV=1 "$ADB" logcat -c >/dev/null 2>&1
"$ADB" shell am force-stop com.mathcoach.app
"$ADB" shell am start -n com.mathcoach.app/.MainActivity >/dev/null 2>&1
sleep 10

dump_ui() {
  MSYS_NO_PATHCONV=1 "$ADB" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/ui.xml "$SHOTS_WIN/ui.xml" >/dev/null 2>&1
}

echo "=== 首页文本节点 ==="
dump_ui
python - "$SHOTS_WIN/ui.xml" <<'EOF'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
nodes = re.findall(r'text="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
for t, x1, y1, x2, y2 in nodes:
    if t.strip():
        print(f'  {t.strip()[:24]:<26} center=({(int(x1)+int(x2))//2},{(int(y1)+int(y2))//2})')
EOF

echo "=== 点「出一套题」 ==="
TAP=$(python - "$SHOTS_WIN/ui.xml" <<'EOF'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for m in re.finditer(r'text="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    if '出一套题' in m.group(1):
        print((int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
        break
EOF
)
if [ -z "$TAP" ]; then
  echo "[FAIL] 没找到「出一套题」按钮"
  exit 1
fi
read X Y <<< "$TAP"
echo "tap $X $Y"
"$ADB" shell input tap "$X" "$Y"
sleep 6

echo "=== 出题后的界面文本 ==="
dump_ui
python - "$SHOTS_WIN/ui.xml" <<'EOF'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
texts = [t.strip() for t in re.findall(r'text="([^"]+)"', xml) if t.strip()]
for t in texts[:30]:
    print('  ', t[:60])
hint_input = sum(1 for t in texts if t and t not in ('练习','复习','错题本','导出','出一套题'))
print(f'\n非导航文本节点数: {hint_input}（>3 说明题目真的渲染出来了）')
EOF

echo "=== 崩溃检查 ==="
MSYS_NO_PATHCONV=1 "$ADB" logcat -d 2>/dev/null \
  | grep -Ei "FATAL|AndroidRuntime.*mathcoach|NoClassDef" | head -5
"$ADB" shell ps -A 2>/dev/null | grep mathcoach | head -1
echo "=== 完成 ==="
