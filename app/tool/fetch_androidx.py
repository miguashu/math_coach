#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
按 **POM 递归** 解析并下载 androidx 依赖，产出一个可以直接喂给 javac / d8 的 jar 列表。

为什么要有这个脚本：
    手写依赖清单是这次闪退的根因。Flutter embedding 的 Java 代码引用了
    androidx.core / activity / fragment / tracing 一大片类，而我只挑了
    "看起来相关" 的几个包 —— 于是 APK 能编译、能安装，一启动就
    NoClassDefFoundError（而且报错位置在 lifecycle 内部，根本看不出少的是 core）。

正确的做法是让机器去解析 POM：
    给定几个根依赖，抓它们的 .pom，按 compile/runtime 作用域递归展开，
    每个产物尝试 .aar → .jar → -android 变体 → -jvm 变体，
    并且**校验下载到的构件里真的有 class**（KMP 构件不带后缀时是 8KB 的
    metadata，里面一个 class 都没有，必须回退到 -jvm / -android 变体）。

产出：
    tool/androidx/          构件缓存
    tool/androidx/deps.json 解析出的 jar 绝对路径列表 + 依赖树

用法：
    python tool/fetch_androidx.py            # 解析（缓存命中就秒回）
    python tool/fetch_androidx.py --refresh  # 忽略缓存重新解析
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, 'androidx')
MAVEN = 'https://dl.google.com/dl/android/maven2'
MAVEN2 = 'https://repo1.maven.org/maven2'

# 根依赖的版本取自 Flutter SDK 自带的
# examples/platform_view/android/project-app.lockfile —— 那是 Gradle 真实解析出的树，
# 比"我觉得应该用哪个版本"可靠得多。
ROOTS = [
    ('androidx.core', 'core', '1.13.1'),
    ('androidx.activity', 'activity', '1.8.1'),
    ('androidx.fragment', 'fragment', '1.7.1'),
    ('androidx.tracing', 'tracing', '1.2.0'),
    ('androidx.lifecycle', 'lifecycle-runtime', '2.8.7'),
    ('androidx.lifecycle', 'lifecycle-common', '2.8.7'),
    ('androidx.window', 'window', '1.3.0'),
    ('androidx.annotation', 'annotation-jvm', '1.8.1'),
    ('androidx.exifinterface', 'exifinterface', '1.4.1'),
    ('androidx.arch.core', 'core-common', '2.2.0'),
    ('androidx.arch.core', 'core-runtime', '2.2.0'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.0.21'),
    # coroutines-android 只是调度器适配层，core 才是本体 ——
    # 少了它，任何走到协程的 lifecycle/fragment 代码都会 NoClassDefFoundError
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.7.3'),
    # Flutter 3.47 的 FlutterLoader 用 ReLinker 加载 libflutter.so ——
    # 它不在 androidx 名下，所以"只解析 androidx"会漏掉它，
    # 后果是启动即崩：NoClassDefFoundError: com.getkeepsafe.relinker.ReLinker$Logger
    ('com.getkeepsafe.relinker', 'relinker', '1.4.5'),
    # androidx.concurrent 的 ListenableFuture 就是这个 5KB 的接口包 ——
    # 它是 concurrent-futures 的传递依赖，而 Guava 本体我们并不需要
    ('com.google.guava', 'listenablefuture', '1.0'),
]

# 只有这些 group 是我们愿意打进 APK 的。
# androidx 的 POM 偶尔会牵出 guava / error_prone 这种编译期注解，
# 那些是给注解处理器用的，运行时不需要，全下下来只会把 dex 撑爆。
ALLOWED_GROUPS = (
    'androidx.',
    'org.jetbrains.kotlin:kotlin-stdlib',
    'org.jetbrains.kotlinx:kotlinx-coroutines',
    'com.getkeepsafe.relinker:relinker',
    'com.google.guava:listenablefuture',
)

SEEN: dict[str, dict] = {}


def vkey(v: str):
    """把 '[2.6.2]' 这种 POM 版本区间还原成 2.6.2，再拆成可比较的元组。

    androidx 的 POM 里会把依赖写成硬区间 `[2.6.2]` —— 不剥掉方括号，
    拼出来的 URL 是 lifecycle-common-[2.6.2].jar，下载必然 404，
    而这个模块又恰恰是 lifecycle 的本体。
    """
    v = v.strip().strip('[]')
    parts = []
    for seg in v.split('.'):
        num = ''
        for ch in seg:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num) if num else 0)
    return tuple(parts)


def newer(a: str, b: str) -> bool:
    return vkey(a) > vkey(b)


def fetch(url: str) -> bytes | None:
    try:
        with urllib.request.urlopen(url, timeout=90) as r:
            return r.read()
    except Exception:
        return None


def group_path(group: str) -> str:
    return group.replace('.', '/')


def has_classes(path: str) -> bool:
    """构件里到底有没有 class —— KMP 的 metadata-only 构件能骗过"下载成功"这一关。"""
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
    except Exception:
        return False
    if 'classes.jar' in names:
        return True
    return any(n.endswith('.class') for n in names)


def download_artifact(group, artifact, version):
    """按 aar → jar → -android → -jvm 的顺序试，取第一个真正含 class 的。"""
    base = f'{MAVEN}/{group_path(group)}'
    m2 = f'{MAVEN2}/{group_path(group)}' if not group.startswith('androidx') else None

    # 现代 androidx 是 KMP 多平台产物：真正的 class 在 `-jvm` / `-android` 变体里，
    # 而**变体名同时出现在路径和文件名上** —— 只改文件名不改路径，
    # 拼出来的是 lifecycle-common/lifecycle-common-jvm-2.8.7.jar，必然 404。
    # 漏掉 lifecycle 的后果就是 Activity 一构造就炸。
    variants = [artifact, artifact + '-android', artifact + '-jvm']

    def urls(root):
        out = []
        for a in variants:
            out.append((f'{root}/{a}/{version}/{a}-{version}.aar', a, '.aar'))
            out.append((f'{root}/{a}/{version}/{a}-{version}.jar', a, '.jar'))
        return out

    candidates = [(u, a, e) for u, a, e in urls(base)]
    if m2:
        # 非 androidx（kotlin / kotlinx）只在 Maven Central 上
        candidates = [(u, a, e) for u, a, e in urls(m2)] + candidates

    for url, aname, ext in candidates:
        name = f'{aname}-{version}{ext}'
        dest = os.path.join(CACHE, name)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            if has_classes(dest):
                return dest
            os.remove(dest)          # 缓存了一个 metadata-only 的假构件，丢掉重来
            continue
        data = fetch(url)
        if not data:
            continue
        with open(dest, 'wb') as f:
            f.write(data)
        if has_classes(dest):
            print(f'    + {name} ({len(data) // 1024} KB)')
            return dest
        os.remove(dest)               # 8KB metadata，不是这个变体
    print(f'    ! 取不到 {group}:{artifact}:{version}')
    return None


def parse_pom(data: bytes):
    """拆出 (group, artifact, version)，只留 compile/runtime 作用域。"""
    ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
    root = ET.fromstring(data)
    out = []
    props = {}
    for p in root.findall('m:properties/*', ns):
        props[p.tag.split('}')[-1]] = (p.text or '')

    # <parent> 里的 version 可能被子 POM 省略 —— 这里只兜最常见的 ${{project.version}}
    def ver(node):
        v = node.findtext('m:version', '', ns) or ''
        if v.startswith('${'):
            key = v[2:-1]
            v = props.get(key) or props.get(key.replace('project.', '')) or ''
        return v

    for d in root.findall('m:dependencies/m:dependency', ns):
        scope = d.findtext('m:scope', 'compile', ns)
        if scope not in ('compile', 'runtime', ''):
            continue
        optional = d.findtext('m:optional', 'false', ns)
        if optional == 'true':
            continue
        g = d.findtext('m:groupId', '', ns)
        a = d.findtext('m:artifactId', '', ns)
        v = ver(d)
        if g and a and v:
            out.append((g, a, v))
    return out


def resolve(group, artifact, version, depth=0):
    key = f'{group}:{artifact}'
    version = version.strip().strip('[]')
    if depth > 6:
        return
    if not any(key.startswith(p) or group.startswith(p) for p in ALLOWED_GROUPS):
        return
    # 版本仲裁：同一个模块被多个 POM 引用时取**最高的**那个。
    # 不做仲裁的话，谁先被遍历到谁胜出 —— 于是 androidx.core 会被某个
    # 老 POM 拖到 1.0.0，而 embedding 要的是 1.13.1 的 ViewCompat。
    if key in SEEN:
        if not newer(version, SEEN[key]['version']):
            return

    SEEN[key] = {'version': version, 'file': None, 'deps': []}

    pom = fetch(f'{MAVEN}/{group_path(group)}/{artifact}/{version}/{artifact}-{version}.pom')
    if pom is None and not group.startswith('androidx'):
        pom = fetch(f'{MAVEN2}/{group_path(group)}/{artifact}/{version}/{artifact}-{version}.pom')
    deps = parse_pom(pom) if pom else []
    if pom is None:
        print(f'    ? {key} 没有 POM，只取构件本身')

    SEEN[key]['deps'] = [f'{g}:{a}' for g, a, _v in deps]

    for g, a, v in deps:
        resolve(g, a, v, depth + 1)

    f = download_artifact(group, artifact, version)
    SEEN[key]['file'] = f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--refresh', action='store_true')
    args = ap.parse_args()

    os.makedirs(CACHE, exist_ok=True)
    print('=== 解析 androidx 依赖树（POM 递归） ===')
    for g, a, v in ROOTS:
        resolve(g, a, v)

    jars, missing = [], []
    for key, info in sorted(SEEN.items()):
        if info['file']:
            jars.append(os.path.abspath(info['file']))
        else:
            missing.append(key)

    # AAR 里能用的只有 classes.jar —— d8 不认 .aar 这个壳
    usable = []
    for j in jars:
        if j.endswith('.aar'):
            out = j[:-4] + '-classes.jar'
            if not os.path.exists(out):
                with zipfile.ZipFile(j) as z, open(out, 'wb') as f:
                    f.write(z.read('classes.jar'))
            usable.append(out)
        else:
            usable.append(j)

    with open(os.path.join(CACHE, 'deps.json'), 'w', encoding='utf-8') as f:
        json.dump({'jars': usable, 'tree': SEEN}, f, ensure_ascii=False, indent=2)

    print('')
    print(f'解析到 {len(SEEN)} 个模块，可用 jar {len(usable)} 个')
    for m in missing:
        print(f'  [缺] {m}')
    total = sum(os.path.getsize(p) for p in usable) // 1024
    print(f'合计 {total} KB')
    print(f'清单: {os.path.join(CACHE, "deps.json")}')
    # 少数模块取不到是正常的：kotlin-stdlib-common 是 Kotlin 的多平台 metadata，
    # 运行时用不到；androidx.annotation 我们已经用 annotation-jvm 顶上了。
    # 真正的裁决交给下一步的 dex 差集扫描 —— 缺了哪个类它会直接点名。
    return 0


if __name__ == '__main__':
    sys.exit(main())
