"""视觉模型探针：拿一张题目图去问模型「图里是什么题」，判断它能不能识题。

用法： python tool/vision_probe.py <模型名> [图片路径]
本机 `dart test` 跑不了（Dart VM 无法管道 spawn 子进程），
但命令行 curl / python requests 完全正常，所以实测联网链路走这里。
"""
import base64
import json
import os
import sys
import time
import urllib.request

# key 从仓库根 .env 读（源码内不含明文；与 Dart 侧 --dart-define-file 同源）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from local_key import require_key  # noqa: E402

BASE = "https://api.agicto.cn/v1"
KEY = require_key()

PROMPT = (
    "请只做一件事：把图片里的数学题原样抄出来（OCR）。\n"
    "不要解题、不要给答案。只输出 JSON：{\"stem\": \"题干文字\"}\n"
    "如果图里没有题目，输出 {\"stem\": \"\"}"
)


def call(model, img_path, prompt=PROMPT, max_tokens=600):
    with open(img_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    body = {
        "model": model,
        "temperature": 0.1,
        "max_tokens": max_tokens,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{b64}"},
                    },
                ],
            }
        ],
    }
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {KEY}",
        },
    )
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        return {"http": e.code, "raw": raw[:600], "ms": int((time.time() - t) * 1000)}
    dt = int((time.time() - t) * 1000)
    try:
        j = json.loads(raw)
        c = j["choices"][0]["message"]["content"]
        return {"http": 200, "text": c, "usage": j.get("usage"), "ms": dt,
                "model": j.get("model")}
    except Exception:
        return {"http": 200, "raw": raw[:600], "ms": dt}


if __name__ == "__main__":
    model = sys.argv[1] if len(sys.argv) > 1 else "gpt-image-2-token"
    img = sys.argv[2] if len(sys.argv) > 2 else "/tmp/probe.png"
    r = call(model, img)
    print(f"== {model}  HTTP {r.get('http')}  {r.get('ms')}ms  real={r.get('model')}")
    if "text" in r:
        print(r["text"][:800])
    else:
        print("RAW:", r.get("raw", "")[:600])
