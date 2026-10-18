"""从仓库根的 `.env` 读本地 API key。

为什么要这层：
    PowerShell/源码里不许出现明文 key —— 本仓库是公开的，key 写死等于
    把额度挂在路灯上。Dart 侧走 `--dart-define-file=.env`（编译期常量），
    Python 探针到这里读同一个文件，**两边共用一份来源不会漂移**。

`.env` 已在 .gitignore 里；对外只给 `.env.example`（空的，拷过去自己填）。

用法：
    from local_key import read_key
    KEY = read_key()          # 拿不到返回空串
    if not KEY:
        sys.exit("需要 key：把 .env.example 复制成 .env 并填上 MATH_COACH_API_KEY")
"""
import pathlib
import sys

KEY_NAME = "MATH_COACH_API_KEY"


def repo_root() -> pathlib.Path:
    # tool/local_key.py -> 上溯两级即仓库根
    return pathlib.Path(__file__).resolve().parent.parent


def read_key() -> str:
    """读 key。优先读 .env，读不到再看真环境变量（CI / 命令行注入场景）。"""
    env_file = repo_root() / ".env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k.strip() == KEY_NAME:
                return v.strip()
    import os

    return os.environ.get(KEY_NAME, "").strip()


def require_key() -> str:
    """拿不到就报错退出 —— 探针脚本不配 key 跑不出任何东西。"""
    k = read_key()
    if not k:
        sys.exit(
            f"没读到 {KEY_NAME}。\n"
            f"做法：把仓库根的 .env.example 复制成 .env，填上自己的 key。\n"
            f"（.env 已被 gitignore，不会误提交）"
        )
    return k


if __name__ == "__main__":
    v = read_key()
    print("<EMPTY>" if not v else v[:6] + "…" + f"(len={len(v)})")
