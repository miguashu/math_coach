"""诊断用：把 KidSolver 的真实 prompt 原样打一次，看模型第一次到底返回什么。

之所以要查：实测里三道题**全都尝试了 2 次**，说明第一次都被判定"不完整/验算不一致"，
耗时直接翻倍（5 s → 10 s）。必须看清模型第一次交上来的 JSON 长什么样。
"""
import json
import os
import sys
import urllib.request

# key 从仓库根 .env 读（源码内不含明文；与 Dart 侧 --dart-define-file 同源）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from local_key import require_key  # noqa: E402

BASE = "https://api.agicto.cn/v1"
KEY = require_key()

# 与 lib/ai/solver.dart 里 KidSolver._system 保持一致
SYSTEM = """你是一位优秀的小学数学老师，讲解对象是 6~12 岁的小学生。

硬性要求：
1. 必须分步骤讲：第一步干什么、第二步干什么……每一步写清「做什么、为什么这么做、算式是什么」。
   至少要有 2 步；一步到位的讲解不合格。
2. 语言简单明了，像老师嘴边的话，不用孩子没学过的术语。
3. 每一步尽量不超过两句话。能配一句生活化的比喻就配。
4. 最后一步必须明确说出最终答案和单位。

只输出 JSON，不要输出任何其他文字，格式：
{
  "steps": [
    {"title": "第一步：…", "detail": "…", "math": "算式或空字符串"},
    …
  ],
  "answer": "最终答案（数字）",
  "unit": "单位，如 米/平方厘米/个，没有就空字符串",
  "equation": "从原题条件直接到最终答案的一条完整四则算式，用于验算；确实写不成一条算式就填空字符串"
}"""


def ask(stem, grade=3, model="deepseek-v4-flash"):
    body = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": 1800,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"（这是 {grade} 年级学生的题）\n{stem}"},
        ],
    }
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        j = json.loads(r.read().decode("utf-8", "replace"))
    return j["choices"][0]["message"]["content"]


if __name__ == "__main__":
    stem = sys.argv[1] if len(sys.argv) > 1 else "237 + 158 = ?"
    grade = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    print("── 第一次原始返回 ──")
    print(ask(stem, grade))
