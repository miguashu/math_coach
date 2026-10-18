#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 Flutter SDK 自带模板生成 iOS 工程（app/ios/）。

## 为什么要有这个脚本

官方做法是 `flutter create --platforms=ios .`，但这台机器上跑不了：
Flutter 工具会先检查 SDK 目录是不是 git clone（本机 GitHub 不通，
SDK 是手工拷贝来的，没有 .git），检查不过直接退出：

    Error: The Flutter directory is not a clone of the GitHub project.

所以改成"手工渲染模板"。好处是模板来自**同版本 SDK**
(`templates/app/ios.tmpl`)，Xcode 工程文件与引擎版本天然配套，
比手写一份 pbxproj 可靠得多。

## 生成之后

工程骨架只能在这台机器上生成，**构建必须在 macOS 上**：
见 docs/pm/iOS-构建说明.md。

    cd app
    flutter pub get
    open ios/Runner.xcworkspace     # 用 Xcode 选好签名再跑

## 定制项（都在本脚本里，改完全局重建即可）

- 只允许竖屏：几何题和竖式在横屏下会被压扁（与安卓版一致）
- 显示名「小数辅导」
- 相机 / 相册权限说明文案（拍照识题要用）
- 强制浅色外观：界面是浅色设计的，深色模式下启动屏会闪白
- 应用图标：品牌蓝底 + 白色 ∑（本脚本用 PIL 现画）
"""

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # .../app/tool
APP = os.path.dirname(HERE)                                # .../app
OUT = os.path.join(APP, 'ios')                             # 产物


def _find(env_keys, *candidates):
    for k in env_keys:
        v = os.environ.get(k)
        if v and os.path.isdir(v):
            return v
    for c in candidates:
        if os.path.isdir(c):
            return c
    return candidates[-1]


FLUTTER = _find(('FLUTTER_ROOT',), r'D:\workbuddy\flutter',
                r'C:\Users\Lenovo\dev\flutter')
TMPL = os.path.join(FLUTTER, 'packages', 'flutter_tools',
                    'templates', 'app', 'ios.tmpl')

# ── 模板变量 ──
# 取值规则照抄 flutter_tools 的 create.dart：
#   titleCaseProjectName = snakeCaseToTitleCase(projectName)
#   iosIdentifier        = organization + '.' + camelCase(projectName)
# 这里刻意把 bundle id 定成 com.mathcoach.app，与安卓版保持一致，
# 家长在两个平台上看到的是同一个应用标识。
PROJECT_NAME = 'math_coach_app'
VARS = {
    'projectName': PROJECT_NAME,
    'titleCaseProjectName': 'Math Coach App',
    'iosIdentifier': 'com.mathcoach.app',
    'pluginProjectName': PROJECT_NAME,
    'pluginClass': 'MathCoachAppPlugin',
    'iosDevelopmentTeam': '',        # 留空，在 Xcode 里选自己的团队
}

# ── 应用图标 ──
ICON_SPECS = [
    ('Icon-App-20x20@1x.png', 20), ('Icon-App-20x20@2x.png', 40),
    ('Icon-App-20x20@3x.png', 60),
    ('Icon-App-29x29@1x.png', 29), ('Icon-App-29x29@2x.png', 58),
    ('Icon-App-29x29@3x.png', 87),
    ('Icon-App-40x40@1x.png', 40), ('Icon-App-40x40@2x.png', 80),
    ('Icon-App-40x40@3x.png', 120),
    ('Icon-App-60x60@2x.png', 120), ('Icon-App-60x60@3x.png', 180),
    ('Icon-App-76x76@1x.png', 76), ('Icon-App-76x76@2x.png', 152),
    ('Icon-App-83.5x83.5@2x.png', 167),
    ('Icon-App-1024x1024@1x.png', 1024),
]

# 启动屏中间的图（storyboard 里声明的是 168x185 的点位）
LAUNCH_SPECS = [
    ('LaunchImage.png', 168, 185),
    ('LaunchImage@2x.png', 336, 370),
    ('LaunchImage@3x.png', 504, 555),
]

BRAND = (37, 99, 235)
BRAND_LIGHT = (147, 197, 253)


def _need_pillow():
    try:
        import PIL  # noqa: F401
        return True
    except Exception:
        print('[FAIL] 需要 Pillow 来生成图标：pip install pillow', file=sys.stderr)
        return False


def _render_brand(size, with_rule=True, bg=BRAND, box=None):
    """画品牌图标：蓝底 + 白色 ∑ + 底部一条练习本横线。

    box 不为 None 时（形如 (w, h)）把内容画进更大的透明画布居中，
    给启动图用 —— 那个画布不是正方形。
    """
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new('RGB', (size, size), bg)
    d = ImageDraw.Draw(img)
    font = None
    for fp in (r'C:\Windows\Fonts\seguisym.ttf',
               r'/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
               r'C:\Windows\Fonts\arialbd.ttf'):
        if os.path.exists(fp):
            font = ImageFont.truetype(fp, int(size * 0.62))
            break
    if font is None:
        font = ImageFont.load_default()

    txt = '\u2211'          # ∑
    bb = d.textbbox((0, 0), txt, font=font)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    cy = (size - h) / 2 - bb[1] - (size * 0.045 if with_rule else 0)
    d.text(((size - w) / 2 - bb[0], cy), txt, font=font, fill=(255, 255, 255))

    if with_rule:
        y = int(size * 0.80)
        d.rectangle([int(size * 0.30), y, int(size * 0.70), y + int(size * 0.035)],
                    fill=BRAND_LIGHT)

    if box:
        canvas = Image.new('RGBA', box, (0, 0, 0, 0))
        fit = min(box[0] / size, box[1] / size)
        icon = img.resize((max(1, int(size * fit)), max(1, int(size * fit))))
        canvas.paste(icon, ((box[0] - icon.width) // 2,
                            (box[1] - icon.height) // 2))
        return canvas
    return img


def _write_icons():
    if not _need_pillow():
        return False
    from PIL import Image

    base = _render_brand(1024)
    icon_dir = os.path.join(OUT, 'Runner', 'Assets.xcassets',
                            'AppIcon.appiconset')
    os.makedirs(icon_dir, exist_ok=True)
    for name, size in ICON_SPECS:
        base.resize((size, size), Image.LANCZOS).save(
            os.path.join(icon_dir, name))
    print(f'  · 应用图标 {len(ICON_SPECS)} 张（最大 1024×1024）')

    launch_dir = os.path.join(OUT, 'Runner', 'Assets.xcassets',
                              'LaunchImage.imageset')
    os.makedirs(launch_dir, exist_ok=True)
    for name, w, h in LAUNCH_SPECS:
        _render_brand(int(min(w, h) * 1.6), with_rule=True,
                      box=(w, h)).save(os.path.join(launch_dir, name))
    print(f'  · 启动图 {len(LAUNCH_SPECS)} 张')
    return True


def _patch_info_plist(path):
    """在模板产出的 Info.plist 上做定制。

    保持成"文本替换"而不是重新生成，是为了将来 Flutter 升级模板时
    能立刻看出哪里被我们改过。
    """
    with open(path, 'r', encoding='utf-8') as f:
        s = f.read()

    # 1) 显示名 / 包名：中文名给家长看
    s = s.replace(
        '\t<key>CFBundleDisplayName</key>\n\t<string>Math Coach App</string>',
        '\t<key>CFBundleDisplayName</key>\n\t<string>小数辅导</string>')
    s = s.replace(
        '\t<key>CFBundleName</key>\n\t<string>math_coach_app</string>',
        '\t<key>CFBundleName</key>\n\t<string>小数辅导</string>')

    # 2) 只允许竖屏 —— 竖式排版和几何图在横屏下会被压扁（与安卓一致）
    s = re.sub(
        r'(<key>UISupportedInterfaceOrientations</key>\s*<array>).*?(</array>)',
        r'\1\n\t\t<string>UIInterfaceOrientationPortrait</string>\n\t\2',
        s, flags=re.S)
    s = re.sub(
        r'(<key>UISupportedInterfaceOrientations~ipad</key>\s*<array>).*?(</array>)',
        r'\1\n\t\t<string>UIInterfaceOrientationPortrait</string>\n'
        r'\t\t<string>UIInterfaceOrientationPortraitUpsideDown</string>\n\t\2',
        s, flags=re.S)

    # 3) 拍照识题要用的权限说明。iOS 上不给说明文案会被审核端直接拒，
    #    而且用户看到的是系统弹窗里的这句话，必须说人话。
    extra = '''\t<key>NSCameraUsageDescription</key>
\t<string>拍孩子的作业照片，用来识别题目并给出分步讲解。照片只在这台手机上处理。</string>
\t<key>NSPhotoLibraryUsageDescription</key>
\t<string>从相册里选一张作业照片来识别题目。</string>
\t<key>NSPhotoLibraryAddUsageDescription</key>
\t<string>把导出的练习卷 PDF 存到相册里，方便发给老师或打印。</string>
\t<key>UIUserInterfaceStyle</key>
\t<string>Light</string>
\t<key>CFBundleLocalizations</key>
\t<array>
\t\t<string>zh_CN</string>
\t\t<string>en</string>
\t</array>
'''
    s = s.replace('\t<key>UIApplicationSceneManifest</key>', extra + '\t<key>UIApplicationSceneManifest</key>')

    with open(path, 'w', encoding='utf-8') as f:
        f.write(s)


def main():
    if not os.path.isdir(TMPL):
        print(f'[FAIL] 找不到模板目录：{TMPL}', file=sys.stderr)
        return 1

    print(f'模板：{TMPL}')
    print(f'输出：{OUT}')

    if os.path.isdir(OUT):
        # 不删旧目录：保留用户的本地改动（如已经填好的签名设置）。
        # 需要干净重建时自己先删掉 app/ios。
        print('  [注意] app/ios 已存在，同名文件会被覆盖')

    copied = 0
    for root, _dirs, files in os.walk(TMPL):
        rel = os.path.relpath(root, TMPL)
        rel = '' if rel == '.' else rel
        dst_dir = os.path.join(OUT, rel) if rel else OUT
        os.makedirs(dst_dir, exist_ok=True)

        for name in files:
            src = os.path.join(root, name)

            # 图片模板：文件名去掉 .img.tmpl，内容由 PIL 现画（模板里是 0 字节占位）
            if name.endswith('.img.tmpl'):
                continue

            out_name = name
            if out_name.endswith('.tmpl'):
                out_name = out_name[:-len('.tmpl')]
            for k, v in VARS.items():
                out_name = out_name.replace('{{%s}}' % k, v)
            dst = os.path.join(dst_dir, out_name)

            if name.endswith('.tmpl'):
                with open(src, 'r', encoding='utf-8') as f:
                    body = f.read()
                for k, v in VARS.items():
                    body = body.replace('{{%s}}' % k, v)
                with open(dst, 'w', encoding='utf-8', newline='') as f:
                    f.write(body)
            else:
                shutil.copy2(src, dst)
            copied += 1
            print(f'  · {os.path.join(rel, out_name) if rel else out_name}')

    print(f'共 {copied} 个文件')

    if not _write_icons():
        return 1

    _patch_info_plist(os.path.join(OUT, 'Runner', 'Info.plist'))
    print('  · Info.plist 定制完成（竖屏 / 中文名 / 拍照权限 / 浅色外观）')

    print()
    print('完成。iOS 构建必须在 macOS 上进行：')
    print('  cd app && flutter pub get && open ios/Runner.xcworkspace')
    return 0


if __name__ == '__main__':
    sys.exit(main())
