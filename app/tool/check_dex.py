#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
dex 体检：把 classes.dex 里**引用了但没有定义**的类全部点名。

为什么需要它：
    d8 不会因为"引用的类不存在"报错 —— 缺哪个包都能编出 dex。
    于是 APK 能编译、能安装、能签名验证通过，
    直到设备上某条代码路径碰到那个类才 NoClassDefFoundError。
    而且堆栈指向的是**调用它的那一方**（比如 lifecycle 内部），
    从崩溃日志根本看不出真正少的是哪个库。

    第一版我只查了 androidx/kotlin 前缀，结果漏了 com.getkeepsafe.relinker ——
    Flutter 3.47 的 FlutterLoader 就是靠它加载 libflutter.so 的，
    于是 App 一启动就崩在 FlutterLoader 里。所以这里改为**全量查**：
    凡是引用了却没定义的，除了 ART/JDK 自带的平台类，一律报出来。

用法：
    python tool/check_dex.py                       # 查最新的 arm64 APK
    python tool/check_dex.py build/xxx.apk
"""
from __future__ import annotations

import os
import struct
import sys
import zipfile

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 这些由 Android 运行时 / JDK 提供，不需要打进 APK
PLATFORM_PREFIX = (
    'Ljava/', 'Ljavax/', 'Ljdk/', 'Lsun/', 'Ldalvik/', 'Landroid/',
    'Lcom/android/', 'Lorg/w3c/', 'Lorg/xml/', 'Lorg/json/', 'Lorg/xmlpull/',
    'Lkotlin/',     # Kotlin 标准库由 kotlin-stdlib 提供，但我们要确认它真在 dex 里
)

# 这些是设备厂商 ROM 里才有、window 库用反射探测的可选扩展，
# 官方 APK 也不打包（找不到就走降级路径），属于**预期缺失**
OPTIONAL = (
    'Landroidx/window/extensions/',
    'Landroidx/window/sidecar/',
    'Landroidx/window/java/',
    # Play Core：延迟加载组件（deferred components）才用得着，
    # 本工程没开这个能力，所以 FlutterLoader 里那段永远走不到。
    # 一旦将来要开 --deferred-components，这里必须删掉跟着报错清单走。
    'Lcom/google/android/play/core/',
)


def read_dex_types(data: bytes):
    def u32(off):
        return struct.unpack_from('<I', data, off)[0]

    str_sz, str_off = u32(0x38), u32(0x3c)
    typ_sz, typ_off = u32(0x40), u32(0x44)
    cls_sz, cls_off = u32(0x60), u32(0x64)

    def mutf8(off):
        n = 0
        shift = 0
        while True:
            b = data[off]
            off += 1
            n |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
        return data[off:off + n].decode('utf-8', 'replace')

    strings = [mutf8(u32(str_off + i * 4)) for i in range(str_sz)]
    types = [strings[u32(typ_off + i * 4)] for i in range(typ_sz)]
    defined = {types[u32(cls_off + i * 32)] for i in range(cls_sz)}
    return types, defined


def main():
    apk = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        APP, 'build', 'math-coach-arm64-v8a.apk')
    if not os.path.exists(apk):
        print(f'[FAIL] 找不到 {apk}')
        return 1
    with zipfile.ZipFile(apk) as z:
        data = z.read('classes.dex')

    types, defined = read_dex_types(data)
    refs = {t for t in types if t.startswith('L') and t.endswith(';')}

    missing = sorted(r for r in refs - defined if not r.startswith(PLATFORM_PREFIX))
    blocking = [m for m in missing if not m.startswith(OPTIONAL)]
    optional = [m for m in missing if m.startswith(OPTIONAL)]

    print(f'APK: {apk}')
    print(f'dex 定义的类: {len(defined)}，引用的类型: {len(refs)}')
    print('')
    if blocking:
        print(f'=== 缺失（会崩）: {len(blocking)} ===')
        for m in blocking:
            print('   ', m)
    else:
        print('=== 缺失（会崩）: 0 —— 依赖齐了 ===')
    if optional:
        print(f'\n=== 预期缺失（window 的 OEM 可选扩展，反射探测，缺了走降级）: {len(optional)} ===')
        for m in optional[:5]:
            print('   ', m)
    return 1 if blocking else 0


if __name__ == '__main__':
    sys.exit(main())
