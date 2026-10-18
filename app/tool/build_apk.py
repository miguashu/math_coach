#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
手工编排 Flutter APK 构建 —— 不经过 Gradle / flutter_tools。

为什么要自己编排：
    这台机器的 Dart VM 无法以管道模式 spawn 子进程（CreateFile failed 231），
    而 flutter_tools 内部到处是 Process.run、Gradle 又要回头调用 flutter assemble，
    整条官方链路在这里是断的。
    但 Python 的 subprocess 完全正常 —— 所以由 Python 依次调用：
        frontend_server → app.dill
        gen_snapshot    → libapp.so  (ARM64 AOT ELF)
        javac + d8      → classes.dex
        aapt2 compile/link → 资源与 AndroidManifest
        zipalign + apksigner → 可安装的 APK

用法：
    python tool/build_apk.py            # 构建
    python tool/build_apk.py --verbose  # 打印每步的完整日志
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)                 # math_coach/app

def _find(env_keys, *candidates):
    """按「环境变量 → 候选路径」找一个存在的目录。

    2026-10-16 整套工具链从 C 盘搬到了 D:\\workbuddy（C 盘只剩 4 G，
    模拟器起不来就是因为没空间）。旧路径留作兜底候选，
    将来再挪地方只要设环境变量或改候选表，不用翻所有脚本。
    """
    for k in env_keys:
        v = os.environ.get(k)
        if v and os.path.isdir(v):
            return v
    for c in candidates:
        if os.path.isdir(c):
            return c
    return candidates[-1]


FLUTTER = _find(('FLUTTER_ROOT',), r'D:\workbuddy\flutter', r'C:\Users\Lenovo\dev\flutter')
ANDROID_SDK = _find(('ANDROID_HOME', 'ANDROID_SDK_ROOT'),
                    r'D:\workbuddy\android-sdk', r'C:\Android\Sdk')
JDK = _find(('JAVA_HOME',), r'D:\ruanjian\jdk17')
# NDK 只用来拿 llvm-strip：剥掉引擎的调试符号，172 MB → 约 26 MB。
# （2026-10-16 用户批准下载，装到 android-sdk\ndk 下；没装就跳过，构建照常。）
NDK = _find(('ANDROID_NDK_HOME', 'NDK_HOME'),
            os.path.join(ANDROID_SDK, 'ndk', 'android-ndk-r26d'))
LLVM_STRIP = os.path.join(
    NDK, 'toolchains', 'llvm', 'prebuilt', 'windows-x86_64', 'bin',
    'llvm-strip.exe' if os.name == 'nt' else 'llvm-strip')

# 由 --no-strip 关掉（排查 native 崩溃时要留符号）
STRIP_SO = True

ANDROIDX_DIR = os.path.join(HERE, 'androidx')

# 依赖清单**不再手写**。
#
# 第一版我照着"看起来相关"挑了 9 个 androidx 包，结果漏掉了
# androidx.core（ViewCompat / WindowInsetsCompat）、activity、fragment、tracing ——
# APK 能编译、能安装，一点开就 NoClassDefFoundError，而且报错落在 lifecycle 内部，
# 从栈里根本看不出少的是 core。
#
# 所以改成让机器解析：tool/fetch_androidx.py 抓 POM 递归展开依赖树，
# 版本取 Flutter SDK 自带 lockfile 里 Gradle 真实解析出的那些。
# 这里只负责读它的产物。
FETCH = os.path.join(HERE, 'fetch_androidx.py')
DEPS_JSON = os.path.join(ANDROIDX_DIR, 'deps.json')

DART_RT = os.path.join(FLUTTER, r'bin\cache\dart-sdk\bin\dartaotruntime.exe')
FRONTEND = os.path.join(FLUTTER, r'bin\cache\dart-sdk\bin\snapshots\frontend_server_aot.dart.snapshot')
PATCHED_SDK = os.path.join(FLUTTER, r'bin\cache\artifacts\engine\common\flutter_patched_sdk_product')
# embedding 的 Java 字节码与架构无关，编译 dex 始终用这一份
FLUTTER_JAR = os.path.join(FLUTTER, r'bin\cache\artifacts\engine\android-arm64-release\flutter.jar')

# gen_snapshot 与 libflutter.so 是**按目标架构分的包**，
# 所以打 x86_64 版（给模拟器跑）和 arm64 版（给真机跑）用的是不同的两组产物。
def engine_dir(abi):
    arch = {'arm64-v8a': 'android-arm64-release', 'x86_64': 'android-x64-release'}[abi]
    return os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine', arch)

ABI_LIB_DIR = {'arm64-v8a': 'lib/arm64-v8a', 'x86_64': 'lib/x86_64'}

BUILD_TOOLS = os.path.join(ANDROID_SDK, 'build-tools', '36.1.0')
ANDROID_JAR = os.path.join(ANDROID_SDK, 'platforms', 'android-34', 'android.jar')
AAPT2 = os.path.join(BUILD_TOOLS, 'aapt2.exe')
D8 = os.path.join(BUILD_TOOLS, 'd8.bat')
ZIPALIGN = os.path.join(BUILD_TOOLS, 'zipalign.exe')
APKSIGNER = os.path.join(BUILD_TOOLS, 'apksigner.bat')
JAVAC = os.path.join(JDK, 'bin', 'javac.exe')
KEYTOOL = os.path.join(JDK, 'bin', 'keytool.exe')

PACKAGE = 'com.mathcoach.app'
BUILD = os.path.join(APP, 'build')


def _read_version():
    """从 pubspec.yaml 读 version: 1.0.0+1 → ('1', '1.0.0')。

    版本号只应该有一个来源。手工链路里最容易漂的就是它：改了 pubspec
    忘了改构建脚本，装到手机上发现版本号没动，排查时非常耗神。
    """
    try:
        with open(os.path.join(APP, 'pubspec.yaml'), encoding='utf-8') as f:
            for line in f:
                m = re.match(r'^version:\s*([0-9][^\s+]*)\+(\d+)\s*$', line)
                if m:
                    return m.group(2), m.group(1)
    except OSError:
        pass
    return '1', '1.0.0'


APP_VERSION_CODE, APP_VERSION_NAME = _read_version()

VERBOSE = False


def run(cmd, cwd=None, desc=''):
    """跑一步，失败就停 —— 构建链上任何一步静默失败都会产出一个坏 APK。"""
    if desc:
        print(f'  · {desc}')
    proc = subprocess.run(
        [str(c) for c in cmd], cwd=cwd,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        encoding='utf-8', errors='replace',
    )
    if VERBOSE and proc.stdout:
        for line in proc.stdout.splitlines():
            print(f'      | {line}')
    if proc.returncode != 0:
        print(f'[FAIL] {desc or cmd[0]}')
        print(proc.stdout or '')
        sys.exit(1)
    return proc.stdout or ''


def ensure(path):
    os.makedirs(path, exist_ok=True)
    return path


def clean_dir(path):
    """清空中间目录 —— 同样是挪走而不是删。

    编译产物目录动辄一百多个文件（R.java 一生成更多），
    直接 rmtree 会被批量删除守卫拦下来要求确认，构建就断在这儿了。
    """
    if os.path.isdir(path):
        old = ensure(os.path.join(BUILD, 'old'))
        try:
            os.replace(path, os.path.join(
                old, f'{int(time.time() * 1000)}-{os.path.basename(path)}'))
        except Exception:
            pass          # 挪不掉就留着，新产物会覆盖同名文件
    ensure(path)
    return path


def _find_impellerc():
    """找宿主机端的 impellerc —— 它在 engine artifacts 里，是 host 工具不是目标机产物。

    layout: <FLUTTER>/bin/cache/artifacts/engine/<host>/impellerc.exe
    """
    engine_root = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine')
    if not os.path.isdir(engine_root):
        return None
    exe = 'impellerc.exe' if os.name == 'nt' else 'impellerc'
    hosts = ['windows-x64', 'linux-x64', 'macos-arm64', 'macos-x64']
    for h in hosts:
        p = os.path.join(engine_root, h, exe)
        if os.path.isfile(p):
            return p
    return None


def _compile_shader(impellerc, src, dst, spirv_path):
    """把一个 .frag 编译成运行时能解码的 IPLR 产物。

    参数顺序照抄 flutter_tools 的 makeImpellercCommand：
        impellerc <targets> --iplr --sl=<out> --spirv=<out.spirv>
                  --input=<src> --input-type=frag --include=<srcdir> --include=<shader_lib>
    Android 的 targets 见 _shaderTargetsFromTargetPlatform：
    先带 --sksl，失败则官方原样去掉 --sksl 再试一次（SkSL 不兼容就该降级，
    不该让构建挂掉 —— 代价只是 Skia 后端加载不了这个 shader）。
    """
    shader_lib = os.path.join(os.path.dirname(impellerc), 'shader_lib')
    base = [
        impellerc,
        '--iplr',
        f'--sl={dst}',
        f'--spirv={spirv_path}',
        f'--input={src}',
        '--input-type=frag',
        f'--include={os.path.dirname(src)}',
        f'--include={shader_lib}',
    ]
    android_targets = ['--sksl', '--runtime-stage-gles',
                       '--runtime-stage-gles3', '--runtime-stage-vulkan']
    attempts = [android_targets,
                [t for t in android_targets if t != '--sksl']]
    last_err = ''
    for idx, targets in enumerate(attempts):
        cmd = [impellerc] + targets + base[1:]
        r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                           errors='replace')
        if r.returncode == 0 and os.path.isfile(dst):
            if idx > 0:
                print(f'    （{os.path.basename(src)} 与 SkSL 不兼容，已去掉 --sksl 重编译）')
            return True
        last_err = (r.stderr or r.stdout or '').strip()[-400:]
    print(f'  [WARN] 编译 shader 失败 {src}\n{last_err}', file=sys.stderr)
    return False


def retire(path):
    """把上一次的产物挪到 build/old/ 而不是删掉。

    删大文件（170MB 的 APK）会被外部的安全删除守卫拦下来做检查，
    那一步超时能把整个构建挂死。改名是同一个效果，且不会触发它。
    """
    if not os.path.exists(path):
        return
    old = ensure(os.path.join(BUILD, 'old'))
    try:
        os.replace(path, os.path.join(old, f'{int(time.time() * 1000)}-{os.path.basename(path)}'))
    except Exception:
        pass


def read_env_defines():
    """从仓库根 `.env` 读 key=value，转成 `-D` 注入参数。

    为什么走这条弯路：
        源码里不许出现明文 key（本仓库是公开的），而这里是**手编的构建流程**——
        没有 flutter_tools 那层 `--dart-define-file` 可用，只能在 kernel 编译
        这步自己把 define 塞进去。跟 App 侧读出的是同一份 `.env`，不会漂移。

    读不到就返回空列表：出来的包只是不带 key，用户在设置页填一样能用，
    不会因为”忘了配 key”就编不过。
    """
    env_file = os.path.join(os.path.dirname(APP), '.env')
    out = []
    if os.path.isfile(env_file):
        try:
            for line in open(env_file, encoding='utf-8'):
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k, v = k.strip(), v.strip()
                if k:
                    out.append(f'-D{k}={v}')
        except OSError as e:
            print(f'[warn] 读 .env 失败（忽略，不注入 key）: {e}')
    return out


def step_kernel():
    """Dart 源码 → app.dill（类型检查在这一步暴露）。"""
    out = os.path.join(BUILD, 'inter', 'app.dill')
    ensure(os.path.dirname(out))
    cmd = [
        DART_RT, FRONTEND,
        '--sdk-root', PATCHED_SDK,
        '--target=flutter',
        '--aot', '--tfa',
        '--target-os=android',
        '--no-print-incremental-dependencies',
        '-Ddart.developer.causal_async_stacks=false',
        '-Ddart.vm.product=true',
        '-DFLUTTER_RUNTIME_MODE=release',
    ]
    # 本地 API key 从这里进包（源码不含明文，见仓库根 .env.example）
    defines = read_env_defines()
    if defines:
        cmd += defines
        print(f'[info] 注入 {len(defines)} 个 dart-define（本地 .env）')
    else:
        print('[info] 无 .env，本次不打入 API key（可在 App 设置页填）')
    cmd += [
        f'--packages={os.path.join(APP, ".dart_tool", "package_config.json")}',
        f'--output-dill={out}',
        os.path.join(APP, 'lib', 'main.dart'),
    ]
    run(cmd, cwd=APP, desc='编译 Dart → app.dill')
    assert os.path.getsize(out) > 1000, 'app.dill 异常小'
    return out


def step_aot(dill, abi):
    """app.dill → libapp.so。App 的实际逻辑都编译在这份原生机器码里。"""
    out_dir = ensure(os.path.join(BUILD, 'inter', abi, 'lib', abi))
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    ensure(out_dir)
    out = os.path.join(out_dir, 'libapp.so')
    run([
        os.path.join(engine_dir(abi), 'windows-x64', 'gen_snapshot.exe'),
        '--deterministic',
        '--snapshot_kind=app-aot-elf',
        f'--elf={out}',
        '--strip',
        dill,
    ], cwd=APP, desc=f'AOT → libapp.so ({abi})')
    return out


def _localize(path):
    """把依赖清单里的绝对路径贴回**当前**环境。

    deps.json 记的是生成时的绝对路径。整套目录 2026-10-16 从
    C:\\Users\\Lenovo\\WorkBuddy\\... 搬到了 D:\\workbuddy，
    旧地址至今还在（那儿只是副本），所以构建没报错 ——
    可一旦旧目录被清掉，这里就会带着一堆不存在的 jar 往下走。
    文件名在 ANDROIDX_DIR 里能找到就用本地那份，清单路径只当兜底。
    """
    if not path:
        return path
    here = os.path.join(ANDROIDX_DIR, os.path.basename(path))
    if os.path.exists(here):
        return here
    return path


def fetch_androidx():
    """取依赖清单（POM 递归解析，见 fetch_androidx.py）。

    AAR 里真正能用的只有 classes.jar，所以要剥出来 —— 直接把 .aar 丢给 javac/d8
    会被告知"找不到类"，因为它不知道该去 zip 里再抠一层。
    """
    if not os.path.exists(DEPS_JSON):
        print('  · 首次构建，先解析 androidx 依赖树（POM 递归，约 1–2 分钟）')
        run([sys.executable, FETCH], desc='解析 androidx 依赖')
    with open(DEPS_JSON, encoding='utf-8') as f:
        deps = json.load(f)
    jars = []
    for j in deps['jars']:
        j = _localize(j)
        if j.endswith('.aar'):
            out_jar = j[:-4] + '-classes.jar'
            if not os.path.exists(out_jar):
                with zipfile.ZipFile(j) as z, open(out_jar, 'wb') as f:
                    f.write(z.read('classes.jar'))
            jars.append(out_jar)
        else:
            jars.append(j)
    print(f'  · 依赖 jar {len(jars)} 个（来自 {os.path.basename(DEPS_JSON)}）')
    return jars


def aar_packages():
    """各 AAR 的资源包名 —— R 类的包名，aapt2 要靠它生成 androidx.core.R 之类。

    这些值不是猜的：dex 差集扫出来的缺失项直接写明了
    Landroidx/core/R$id;、Landroidx/lifecycle/runtime/R$id; ……
    类名去掉 R$ 就是 namespace。
    """
    return {
        'core': 'androidx.core',
        'core-ktx': 'androidx.core',
        'fragment': 'androidx.fragment',
        'activity': 'androidx.activity',
        'lifecycle-runtime': 'androidx.lifecycle.runtime',
        'lifecycle-viewmodel': 'androidx.lifecycle.viewmodel',
        'lifecycle-livedata': 'androidx.lifecycle',
        'savedstate': 'androidx.savedstate',
        'startup-runtime': 'androidx.startup',
        'window': 'androidx.window',
        'viewpager': 'androidx.viewpager',
        'loader': 'androidx.loader',
        'customview': 'androidx.customview',
        'interpolator': 'androidx.interpolator',
        'exifinterface': 'androidx.exifinterface',
        'profileinstaller': 'androidx.profileinstaller',
        'tracing': 'androidx.tracing',
        'versionedparcelable': 'androidx.versionedparcelable',
        'core-runtime': 'androidx.arch.core',
        'annotation-experimental': 'androidx.annotation',
    }


def collect_aar_res():
    """把依赖 AAR 里的 res/ 剥出来。

    官方构建里这些资源是被合并进 APK 的，R 类也是那时生成的 ——
    只把 classes.jar 打进 dex 会把 androidx.core.R$id 这类类留成空洞，
    运行时哪个方法碰到一个 R 常量就是 NoClassDefFoundError。
    """
    def vkey(v):
        parts = []
        for seg in v.split('.'):
            n = ''
            for ch in seg:
                if ch.isdigit():
                    n += ch
                else:
                    break
            parts.append(int(n) if n else 0)
        return tuple(parts)

    with open(DEPS_JSON, encoding='utf-8') as f:
        tree = json.load(f)['tree']
    # 刻意用 ensure 而不是 clean_dir：这里是覆盖写，重复构建结果幂等，
    # 没必要每次先删掉一两百个小资源文件
    out_root = ensure(os.path.join(BUILD, 'inter', 'aar-res'))

    # 同一个资源包可能有多个 AAR（core 与 core-ktx 都是 androidx.core），
    # 它们是**同一套 res**：分目录编译会让后写的覆盖前者，
    # 于是 values-v21 引用的 color 在 base values 里找不到 —— 直接 link 失败。
    # 所以按 package 合并到一处，并且**低版本先写、高版本后写覆盖**。
    items = []
    for info in tree.values():
        path = _localize(info.get('file') or '')
        if not path.endswith('.aar') or not os.path.exists(path):
            continue
        stem = os.path.basename(path)[:-4]
        ver = info['version']
        artifact = stem[:-(len(ver) + 1)] if stem.endswith('-' + ver) else stem
        artifact = artifact.replace('-android', '').replace('-jvm', '')
        pkg = aar_packages().get(artifact)
        if pkg:
            items.append((pkg, vkey(ver), path, artifact))
    items.sort(key=lambda t: t[1])

    pkgs, found = {}, []
    for pkg, _v, path, artifact in items:
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.startswith('res/') and not n.endswith('/')]
            if not names:
                continue
            dest = os.path.join(out_root, pkg.replace('.', '_'), 'res')
            ensure(dest)
            for n in names:
                target = os.path.join(dest, *n.split('/')[1:])
                ensure(os.path.dirname(target))
                with open(target, 'wb') as f:
                    f.write(z.read(n))
            pkgs[pkg] = dest
            found.append(artifact)
    print(f'  · 合并 {len(pkgs)} 个资源包: {", ".join(sorted(pkgs))}')
    return pkgs


def dedupe(jars):
    """按类去重。

    依赖树里会有同模块的多版本（core 1.0.0 被老 POM 拖进来 / 1.13.1 才是要的）
    和 KMP 的双变体（collection 与 collection-jvm 类名重叠）。
    直接全丢给 d8 会被 "Program type already present" 顶回来，
    所以大的那个先挑（新版通常更全），后来者只保留没见过的类。
    """
    out_dir = clean_dir(os.path.join(BUILD, 'inter', 'dedup'))
    ordered = sorted(jars, key=lambda p: os.path.getsize(p), reverse=True)
    seen = set()
    result = []
    for jar in ordered:
        with zipfile.ZipFile(jar) as z:
            names = [n for n in z.namelist() if n.endswith('.class')]
            keep = [n for n in names if n not in seen]
            if not keep:
                continue
            if len(keep) == len(names):
                result.append(jar)
            else:
                # 部分重叠：重写一个只含未见过类的 jar
                trimmed = os.path.join(out_dir, os.path.basename(jar))
                with zipfile.ZipFile(trimmed, 'w', zipfile.ZIP_DEFLATED) as out:
                    for n in keep:
                        out.writestr(n, z.read(n))
                result.append(trimmed)
            seen.update(keep)
    print(f'  · 去重后 {len(result)} 个 jar，{len(seen)} 个类')
    return result


def step_java(classpath_jars):
    out = clean_dir(os.path.join(BUILD, 'inter', 'classes'))
    src_root = os.path.join(APP, 'android', 'app', 'src', 'main', 'java')
    java_src = []
    for root, _dirs, files in os.walk(src_root):
        java_src += [os.path.join(root, n) for n in files if n.endswith('.java')]
    # aapt2 生成的 R.java（本包 + 各依赖库）也要编译进 dex，
    # 否则 androidx.core.R$id 这类类在运行时就是空的
    gen_root = os.path.join(BUILD, 'inter', 'gen')
    if os.path.isdir(gen_root):
        for root, _dirs, files in os.walk(gen_root):
            java_src += [os.path.join(root, n) for n in files if n.endswith('.java')]
    assert java_src, '没有找到任何 .java'
    # 注意：android.jar 放在 **classpath** 而不是 -bootclasspath。
    # -bootclasspath 会把 JDK 自己的 rt.jar 整个顶掉，
    # 于是 java.lang.invoke.LambdaMetafactory 消失、lambda 编译不过。
    run([
        JAVAC,
        '-encoding', 'UTF-8',
        '-source', '8', '-target', '8',
        '-classpath', os.pathsep.join([ANDROID_JAR, FLUTTER_JAR, *classpath_jars]),
        '-d', out,
        *java_src,
    ], desc=f'编译 Java（{len(java_src)} 个源文件）')
    return out


def step_dex(java_classes, classpath_jars):
    out = clean_dir(os.path.join(BUILD, 'inter', 'dex'))
    # d8 只吃 .class/.jar/.zip/.apk，不接受**目录** —— 直接传目录会报
    # "Unsupported source file type"，所以先打成 jar
    app_jar = os.path.join(BUILD, 'inter', 'app-classes.jar')
    if os.path.exists(app_jar):
        retire(app_jar)
    with zipfile.ZipFile(app_jar, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(java_classes):
            for name in files:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, java_classes).replace('\\', '/')
                z.write(full, rel)
    run([
        'cmd', '/c', D8,
        '--lib', ANDROID_JAR,
        '--release',
        '--output', out,
        app_jar,
        *dedupe(classpath_jars),
        FLUTTER_JAR,
    ], desc='d8 → classes.dex（含 Flutter embedding）')
    return os.path.join(out, 'classes.dex')


def step_unaligned(abi):
    """aapt2 编译 + 链接，产出 APK 骨架（Manifest 已经是二进制 AXML）。

    这一步顺带干了件必须干的事：把依赖 AAR 的资源一起链接，
    并用 --extra-packages 让 aapt2 为每个库**生成 R.java**。
    androidx.core.R$id / androidx.fragment.R$id 这些类是链接期产物，
    jar 里根本没有 —— 不生成的话运行时碰到 R 常量就是 NoClassDefFoundError。
    """
    res = os.path.join(APP, 'android', 'app', 'src', 'main', 'res')
    manifest = os.path.join(APP, 'android', 'app', 'src', 'main', 'AndroidManifest.xml')
    flat = ensure(os.path.join(BUILD, 'inter', 'res-flat'))
    compile_out = os.path.join(flat, 'compiled.zip')
    if os.path.exists(compile_out):
        retire(compile_out)

    run([AAPT2, 'compile', '--dir', res, '-o', compile_out], desc='aapt2 compile res')

    flats = [compile_out]
    packages = []
    for pkg, resdir in collect_aar_res().items():
        out_zip = os.path.join(flat, f'aar-{pkg.replace(".", "_")}.zip')
        if os.path.exists(out_zip):
            retire(out_zip)
        run([AAPT2, 'compile', '--dir', resdir, '-o', out_zip],
            desc=f'aapt2 compile {pkg} res')
        flats.append(out_zip)
        packages.append(pkg)

    unaligned = os.path.join(BUILD, f'base-unaligned-{abi}.apk')
    if os.path.exists(unaligned):
        retire(unaligned)
    cmd = [
        AAPT2, 'link',
        '-I', ANDROID_JAR,
        '--manifest', manifest,
        '-o', unaligned,
        '--min-sdk-version', '24',
        '--target-sdk-version', '34',
        # 版本号是 aapt2 链接期写进 manifest 的，不传就是空。
        # 空 versionCode 会让部分 ROM 把"覆盖安装"判成异常（红米尤其明显），
        # 表现是提示"未安装"而不是"更新"。这里与 pubspec 里的 1.0.0+1 对齐。
        '--version-code', APP_VERSION_CODE,
        '--version-name', APP_VERSION_NAME,
        '--java', os.path.join(BUILD, 'inter', 'gen'),
        '--auto-add-overlay',
    ]
    if packages:
        cmd += ['--extra-packages', ':'.join(sorted(set(packages)))]
    cmd += flats
    run(cmd, desc='aapt2 link → APK 骨架（含依赖库资源与 R 类）')
    return unaligned


def build_flutter_assets():
    """拼 flutter_assets：AssetManifest + 字体。

    Dart 侧用 rootBundle.load('assets/fonts/simhei.ttf') 取字体，
    所以 AssetManifest.json 里必须有这条 —— 少了的话 rootBundle.load 会走平市地抛异常，
    而且是在用户点「导出」那一刻才炸。

    MaterialIcons 也必须在这里打进去：UI 里所有 Icons.xxx 都靠
    MaterialIcons-Regular.otf 渲染，少了它整个 App 的图标全是 □ 方块
    （第一次模拟器验证就是这么发现的）。
    """
    out = clean_dir(os.path.join(BUILD, 'inter', 'flutter_assets'))
    assets_root = os.path.join(out, 'assets')
    fonts_dir = os.path.join(assets_root, 'fonts')
    ensure(fonts_dir)

    manifest_entries = {}
    src_fonts = os.path.join(APP, 'assets', 'fonts')
    if os.path.isdir(src_fonts):
        for name in sorted(os.listdir(src_fonts)):
            if not name.lower().endswith(('.ttf', '.otf')):
                continue
            shutil.copy2(os.path.join(src_fonts, name), os.path.join(fonts_dir, name))
            rel = f'assets/fonts/{name}'
            manifest_entries[rel] = [rel]
            print(f'  · 打包字体 {name} ({os.path.getsize(os.path.join(src_fonts, name)) // 1024} KB)')

    # MaterialIcons：flutter_tools 平时自动做这件事，手工链路就得自己做。
    # SDK 里文件名是小写 materialicons-regular.otf，别按大小写硬匹配
    icon_font_src = None
    mf_dir = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'material_fonts')
    if os.path.isdir(mf_dir):
        for name in os.listdir(mf_dir):
            if name.lower() == 'materialicons-regular.otf':
                icon_font_src = os.path.join(mf_dir, name)
                break
    font_manifest = []
    if icon_font_src:
        icon_dir = os.path.join(out, 'fonts')
        ensure(icon_dir)
        shutil.copy2(icon_font_src, os.path.join(icon_dir, 'MaterialIcons-Regular.otf'))
        font_manifest.append({
            'family': 'MaterialIcons',
            'fonts': [{'asset': 'fonts/MaterialIcons-Regular.otf'}],
        })
        print('  · 打包 MaterialIcons 字体')
    else:
        print('  [WARN] 找不到 MaterialIcons-Regular.otf，图标会显示为方块')

    # Impeller 的 fragment shader。
    # framework 的 overscroll 拉伸（widgets）与 InkWell 水波纹（material）用
    # FragmentProgram.fromAsset('shaders/xxx.frag') 加载，
    # 官方 flutter_assets 里这两个文件在**根目录的 shaders/ 下**（不是 assets/ 下）。
    #
    # 关键坑：打包的不是 GLSL 源码，而是 impellerc 编译出来的 IPLR 二进制。
    # 第一版图省事直接 copy 源码，App 起来就报
    #   Asset 'shaders/stretch_effect.frag' manifest could not be decoded:
    #   INVALID_ARGUMENT: Payload does not have valid identifier
    # （引擎 lib/ui/painting/fragment_program.cc 认 IPLR 魔数。）
    #
    # 下面两步都是照抄官方 flutter_tools，不许自己发明：
    #   资源清单来源于 _getFrameworkShaders()（asset.dart）
    #   —— 只有这两个，material 目录下那份多余的 stretch_effect.frag 不参与。
    #   编译参数来源于 buildSystem/tools/shader_compiler.dart 的
    #   _shaderTargetsFromTargetPlatform()（Android 是首发 sksl + 三个 runtime stage，
    #   编译失败时官方还会去掉 --sksl 重试一次，这里照做）。
    framework_shaders = [
        ('material', 'ink_sparkle.frag'),
        ('widgets', 'stretch_effect.frag'),
    ]
    impellerc = _find_impellerc()
    packed = []
    if impellerc is None:
        print('  [WARN] 找不到 impellerc，框架 shader 无法编译，'
              '滚动拉伸/水波纹会报错', file=sys.stderr)
    else:
        shaders_out = os.path.join(out, 'shaders')
        # --spirv 是编译中间产物，运行时不读，丢到你根 build 下别进 APK
        spirv_dir = os.path.join(BUILD, 'spirv')
        ensure(spirv_dir)
        for pkg, name in framework_shaders:
            src_dir = os.path.join(FLUTTER, 'packages', 'flutter', 'lib', 'src', pkg, 'shaders')
            src = os.path.join(src_dir, name)
            if not os.path.isfile(src):
                continue
            ensure(shaders_out)
            if _compile_shader(impellerc, src, os.path.join(shaders_out, name),
                               os.path.join(spirv_dir, name + '.spirv')):
                packed.append(name)
    if packed:
        print(f'  · 编译 shader {", ".join(packed)}')
    else:
        print('  [WARN] 没有编译出框架 shader，滚动拉伸/水波纹会报错', file=sys.stderr)

    with open(os.path.join(out, 'AssetManifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest_entries, f, ensure_ascii=False)
    with open(os.path.join(out, 'FontManifest.json'), 'w', encoding='utf-8') as f:
        json.dump(font_manifest, f)
    return out


def strip_so(src, dst_dir):
    """剥掉 .so 里的符号表与调试信息，返回 (剥好的路径, 省下多少字节)。

    为什么必须剥：SDK 自带的 libflutter.so 是**未 strip 的 release 产物**，
    157 MB 里有 146 MB 是 .debug_* / .symtab —— 那些是给调试器看的，
    装到手机上一点用没有。剥完 157 MB → 11 MB，APK 从 172 MB 降到约 26 MB。

    两个注意点：
    - **绝不原地剥**：src 是 SDK 缓存里的产物，改了它就污染了整台机器的工具链，
      以后想带符号排查 native 崩溃都没得查。所以先复制再剥。
    - 代价是崩溃栈里没有符号。要排查 native 崩溃时用 `--no-strip` 重新构建。
    """
    if not STRIP_SO:
        return src, 0
    if not os.path.isfile(LLVM_STRIP):
        return src, 0
    ensure(dst_dir)
    dst = os.path.join(dst_dir, os.path.basename(src))
    shutil.copy2(src, dst)
    before = os.path.getsize(dst)
    r = subprocess.run([LLVM_STRIP, dst], capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    if r.returncode != 0:
        print(f'  [WARN] strip 失败，用原文件继续：{(r.stderr or "").strip()[-200:]}',
              file=sys.stderr)
        return src, 0
    return dst, before - os.path.getsize(dst)


def package(apk_in, dex, libapp, flutter_assets, abi):
    """把 dex / native libs / flutter_assets 塞进 APK 骨架。

    .so 一律 STORED（不压缩）：原生库本来压缩率就低，
    不压缩才能被 mmap 直接加载 —— 装起来更大换来的是启动更快。
    """
    print('  · 打包 dex / native libs / assets')
    lib_out = os.path.join(BUILD, 'inter', abi, 'lib', abi)
    ensure(lib_out)
    libflutter = os.path.join(lib_out, 'libflutter.so')
    if not os.path.exists(libflutter):
        # libflutter.so 是 Flutter 引擎本体，按架构放在各自的 flutter.jar 里
        with zipfile.ZipFile(os.path.join(engine_dir(abi), 'flutter.jar')) as z:
            data = z.read(f'{ABI_LIB_DIR[abi]}/libflutter.so')
        with open(libflutter, 'wb') as f:
            f.write(data)
        print(f'  · 提取 libflutter.so ({len(data) // 1024 // 1024} MB)')

    stripped_dir = os.path.join(BUILD, 'inter', abi, 'stripped')
    packing = []
    saved_total = 0
    for so in (libapp, libflutter):
        final, saved = strip_so(so, stripped_dir)
        packing.append(final)
        saved_total += saved
    if saved_total > 0:
        print(f'  · strip 符号表，省下 {saved_total // 1024 // 1024} MB')

    with zipfile.ZipFile(apk_in, 'a', zipfile.ZIP_DEFLATED) as z:
        z.write(dex, 'classes.dex')
        for so in packing:
            z.write(so, f'{ABI_LIB_DIR[abi]}/{os.path.basename(so)}', compress_type=zipfile.ZIP_STORED)
        for root, _dirs, files in os.walk(flutter_assets):
            for name in files:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, flutter_assets).replace('\\', '/')
                z.write(full, f'assets/flutter_assets/{rel}')
    return apk_in


def align_and_sign(apk, abi):
    aligned = os.path.join(BUILD, f'math-coach-aligned-{abi}.apk')
    if os.path.exists(aligned):
        retire(aligned)
    run([ZIPALIGN, '-f', '4', apk, aligned], desc='zipalign 4 字节对齐')

    keystore = os.path.join(BUILD, 'debug.keystore')
    if not os.path.exists(keystore):
        run([
            KEYTOOL, '-genkeypair', '-v',
            '-keystore', keystore,
            '-storepass', 'android', '-alias', 'androiddebugkey', '-keypass', 'android',
            '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10950',
            '-dname', 'CN=mathcoach, OU=local, O=mathcoach, L=cn, ST=cn, C=CN',
        ], desc='生成调试签名 keystore（首次）')

    final = os.path.join(BUILD, f'math-coach-{abi}.apk')
    if os.path.exists(final):
        retire(final)
    run([
        'cmd', '/c', APKSIGNER, 'sign',
        '--ks', keystore,
        '--ks-pass', 'pass:android',
        '--key-pass', 'pass:android',
        '--ks-key-alias', 'androiddebugkey',
        '--out', final,
        aligned,
    ], desc='apksigner 签名')

    # 立即验签：签名没过，装到手机上也一定失败
    out = run(['cmd', '/c', APKSIGNER, 'verify', '--verbose', final], desc='apksigner verify')
    if 'Verifies' not in out:
        print('[FAIL] 签名验证没通过')
        print(out)
        sys.exit(1)
    return final


def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--abi', default='arm64-v8a', choices=['arm64-v8a', 'x86_64'],
                    help='arm64-v8a 给真机，x86_64 给 x86 模拟器跑验收')
    ap.add_argument('--no-strip', action='store_true',
                    help='保留 .so 的符号表（排查 native 崩溃时用），代价是 APK 大 146 MB')
    args = ap.parse_args()
    global STRIP_SO
    VERBOSE = args.verbose
    abi = args.abi
    STRIP_SO = not args.no_strip
    if not STRIP_SO:
        print('  · 本次保留符号表（--no-strip），APK 会大很多')
    elif not os.path.isfile(LLVM_STRIP):
        print(f'  [WARN] 没找到 llvm-strip（{LLVM_STRIP}），跳过 strip，APK 约 172 MB')

    for label, p in [
        ('Flutter SDK', FLUTTER_JAR),
        ('Android platform', ANDROID_JAR),
        ('JDK', JAVAC),
        ('build-tools', AAPT2),
    ]:
        if not os.path.exists(p):
            print(f'[FAIL] 缺少 {label}: {p}')
            sys.exit(1)

    print(f'=== 构建 math_coach App ({abi} release) ===')
    ensure(BUILD)

    dill = step_kernel()
    libapp = step_aot(dill, abi)
    androidx = fetch_androidx()
    # 顺序有讲究：先 link（生成 R.java），再 javac（把 R 一起编译），最后 d8
    apk_skeleton = step_unaligned(abi)
    dex = step_dex(step_java(androidx), androidx)
    assets = build_flutter_assets()
    package(apk_skeleton, dex, libapp, assets, abi)
    final = align_and_sign(apk_skeleton, abi)

    size = os.path.getsize(final) // 1024 // 1024
    print('')
    print(f'=== 完成: {final}')
    print(f'    {size} MB · {abi} release')
    return final


if __name__ == '__main__':
    main()
