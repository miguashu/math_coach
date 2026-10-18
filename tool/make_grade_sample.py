# 合成一张"孩子的手写答卷"：题干用黑体印（像打印的练习卷），
# 答案用 Ink Free 手写体、逐字轻微旋转抖动，模拟手写。
# 用途：grader_probe.dart 的联网端到端测试 —— 验证"拍照→认字→本地判分"整条链。
#
# 跑法：python tool/make_grade_sample.py [输出.jpg]
import math
import random
import sys

from PIL import Image, ImageDraw, ImageFont

INK = r"C:\Windows\Fonts\Inkfree.ttf"      # 手写体
HEI = r"D:\workbuddy\math_coach\assets\fonts\simhei.ttf"  # 印刷体

# (题干, 手写答案, 备注, 抖动) —— 与模拟器上当前这套卷一致（2026-10-16 验收用）
# 设计：4 题写对（含单位换算 3）、第 3 题写错（67，应为 61）、第 5 题空白
QUESTIONS = [
    ("1. 小芳一周跳绳的次数分别是 16、7、13 下，她平均每天跳多少下？", "12", "", 6),
    ("2. 用竖式算一算：33 × 21 =", "693", "", 6),
    ("3. 先想清楚运算顺序，再算：85 - 6 × 4 =", "67", "", 6),   # 故意写错（应为 61）
    ("4. 用竖式算一算：30 × 15 =", "450", "", 6),
    ("5. 填一填：30 分 = （ ）角", "", "blank", 6),            # 空着不写
    ("6. 同学们在一条小路的一边植树，每隔 6 米栽一棵，一共栽了 10 棵"
     "（两端都栽）。这条小路长多少米？", "54", "", 6),
]


def hand_text(draw, xy, text, font, ink, rng, jitter=7):
    """逐字手写：旋转 + 上下抖动 + 笔画浓度略不均。"""
    x, y = xy
    for ch in text:
        if ch == " ":
            x += font.size // 3
            continue
        tile = Image.new("L", (font.size * 2, font.size * 2), 0)
        td = ImageDraw.Draw(tile)
        td.text((font.size // 2, font.size // 2), ch, font=font, fill=255)
        angle = rng.uniform(-jitter, jitter)
        tile = tile.rotate(angle, resample=Image.BICUBIC, center=(font.size // 2, font.size // 2))
        dy = rng.uniform(-2, 2)
        img.paste(Image.new("RGB", tile.size, ink), (int(x), int(y + dy)), tile)
        x += font.getlength(ch) * 0.92


rng = random.Random(42)
W, H = 900, 1180
img = Image.new("RGB", (W, H), (253, 252, 248))  # 微黄的纸
d = ImageDraw.Draw(img)

f_head = ImageFont.truetype(HEI, 40)
f_stem = ImageFont.truetype(HEI, 30)
f_hand = ImageFont.truetype(INK, 44)

d.text((W // 2 - 130, 36), "数学练习卷", font=f_head, fill=(20, 20, 20))
d.line((60, 100, W - 60, 100), fill=(120, 120, 120), width=2)

y = 150
for stem, ans, note, jitter in QUESTIONS:
    d.text((70, y), stem, font=f_stem, fill=(25, 25, 25))
    if ans:
        # 答案写在题干右下方，像孩子伏案书写的位置
        hand_text(d, (W - 260, y + 55), ans, f_hand, (30, 40, 120), rng, jitter)
    else:
        d.text((W - 300, y + 55), "（空着）", font=ImageFont.truetype(INK, 34), fill=(150, 150, 150))
    y += 190

out = sys.argv[1] if len(sys.argv) > 1 else "tool/testdata/grade_sample.jpg"
img.save(out, quality=88)
print(f"已生成 {out}（{W}x{H}）")
print("预期判卷：第1~3题对、第4题错（写了 90，应为 100）、第5题未识别")
