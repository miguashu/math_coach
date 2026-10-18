#!/usr/bin/env bash
# 新功能的端到端冒烟：变体闯关 + 备份导出/导入 + 设置页。
#
# 为什么要先灌一份种子数据：模拟器是全新安装，错题本是空的，
# 「变体闯关」的入口压根不会出现 —— 那就等于没验。
# 这里用内核自己的格式写一份 wrongbook.json 推进去，
# 让"错题本里有题"这个前提成立。
#
# 前置：模拟器已在线（先跑 bash app/tool/emu_hold.sh）。
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/workbuddy/android-sdk}}
SDK="$(cygpath -u "$SDK" 2>/dev/null || echo "$SDK")"
ADB="$SDK/platform-tools/adb.exe"
SHOTS="$ROOT/app/build/shots"
SHOTS_WIN="$(cygpath -w "$SHOTS" 2>/dev/null || echo "$SHOTS")"
mkdir -p "$SHOTS"

PKG=com.mathcoach.app
# App 数据目录：external files 下，和 MainActivity.dataDir() 对应
DATA=/sdcard/Android/data/$PKG/files/math_coach

shot() { # shot <名字>
  MSYS_NO_PATHCONV=1 "$ADB" shell screencap -p /sdcard/s.png >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$ADB" pull /sdcard/s.png "$SHOTS_WIN/$1.png" >/dev/null 2>&1
  echo "  截图 $1: $(stat -c%s "$SHOTS/$1.png" 2>/dev/null || echo 0) bytes"
}

echo "=== 0) 种子数据 ==="
cat > "$SHOTS/wrongbook.json" <<'JSON'
{
  "version": 1,
  "savedAt": "2026-10-16T12:00:00.000000",
  "records": [
    {"id":"seed-add-1","kind":"add","stem":"用竖式算一算：668 + 376 =","grade":3,"kpPath":"数与代数 / 万以内加减法","kpCode":"MA-G3-S1-NA-02-01","difficulty":2,"answer":"1044","steps":["个位 8+6=14，写 4 进 1","十位 6+7+1=14，写 4 进 1","百位 6+3+1=10"],"verticalKind":"add","verticalArgs":[668,376],"fsrs":{"stability":1,"difficulty":5,"due":1760000000000,"reps":1,"lapses":1},"importance":3,"streak":0,"wrongCount":2,"rightCount":0,"createdAt":1760000000000,"lastSeen":1760000000000},
    {"id":"seed-rect-1","kind":"rect","stem":"一个长方形，长 9 厘米，宽 6 厘米，它的面积是多少平方厘米？","grade":3,"kpPath":"图形与几何 / 长方形面积","kpCode":"MA-G3-S2-GS-02-02","difficulty":2,"answer":"54","steps":["面积 = 长 × 宽","9 × 6 = 54"],"fsrs":{"stability":1,"difficulty":5,"due":1760000000000,"reps":1,"lapses":1},"importance":2,"streak":0,"wrongCount":1,"rightCount":0,"createdAt":1760000000000,"lastSeen":1760000000000},
    {"id":"seed-div-1","kind":"divRem","stem":"用竖式算一算：58 ÷ 7 =","grade":2,"kpPath":"数与代数 / 有余数的除法","kpCode":"MA-G2-S2-NA-03-01","difficulty":3,"answer":"8……2","steps":["想：7 乘几最接近 58 又不超过它？7 × 8 = 56","58 减 56 得 2","余数 2 比除数 7 小，说明试对了"],"verticalKind":"div","verticalArgs":[58,7],"fsrs":{"stability":1,"difficulty":5,"due":1760000000000,"reps":1,"lapses":2},"importance":4,"streak":0,"wrongCount":3,"rightCount":0,"createdAt":1760000000000,"lastSeen":1760000000000}
  ]
}
JSON
"$ADB" shell mkdir -p "$DATA" >/dev/null 2>&1
MSYS_NO_PATHCONV=1 "$ADB" push "$SHOTS_WIN/wrongbook.json" "$DATA/wrongbook.json" 2>&1 | tail -1

echo "=== 1) 安装并冷启动 ==="
"$ADB" install -r -t "$ROOT/app/build/math-coach-x86_64.apk" 2>&1 | tail -1
"$ADB" shell am force-stop $PKG
MSYS_NO_PATHCONV=1 "$ADB" logcat -c >/dev/null 2>&1
"$ADB" shell am start -n $PKG/.MainActivity >/dev/null 2>&1
sleep 12
shot 10-home

echo "=== 2) 切到错题本 ==="
# 底部导航第 4 项（拍照/练习/复习/错题本/导出），y 在导航栏高度上
"$ADB" shell input tap 756 1850
sleep 4
shot 11-book

echo "=== 3) 点「变体闯关」 ==="
"$ADB" shell input tap 900 1850 >/dev/null 2>&1   # 先确保停在错题本页
sleep 1
"$ADB" shell input tap 756 1850
sleep 3
# 「变体闯关」在错题本页右上角
"$ADB" shell input tap 880 170
sleep 5
shot 12-challenge

echo "=== 4) 在闯关页作答并提交 ==="
# 第一题输入框（题卡中部）
"$ADB" shell input tap 540 560
sleep 2
"$ADB" shell input text "123"
sleep 1
"$ADB" shell input tap 540 1000
sleep 3
shot 13-submitted

echo "=== 5) 设置页 → 导出备份 ==="
"$ADB" shell input tap 972 1850
sleep 4
shot 14-settings
# 向下滚到「数据」分区
"$ADB" shell input swipe 540 1400 540 400 400
sleep 3
shot 15-settings-data

echo "=== 6) 崩溃检查 ==="
MSYS_NO_PATHCONV=1 "$ADB" logcat -d 2>/dev/null \
  | grep -Ei "FATAL|AndroidRuntime.*mathcoach|NoClassDef|Dart Error|Unhandled Exception" | head -8
"$ADB" shell ps -A 2>/dev/null | grep -c mathcoach | sed 's/^/  mathcoach 进程数: /'
echo "=== 完成（截图在 app/build/shots/）==="
