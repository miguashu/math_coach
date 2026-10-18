"""把 FigureSvgRenderer 产出的 SVG 复绘成 PNG，用于肉眼核对图形结构。

本机没有 SVG 转换器（无 cairosvg / ImageMagick），而这个渲染器产出的
SVG 结构极简（line / path / ellipse / circle / text），自己解析比装依赖快。

用法: python tool/svg_preview.py <目录或 svg 文件> [缩放倍数]
"""
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "C:/Windows/Fonts/Deng.ttf"


def load_font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except Exception:
        return ImageFont.load_default()


TAG_RE = re.compile(r"<(\w+)([^>]*?)/?>")


def attr(s, key, default=None):
    m = re.search(r'\b%s="([^"]*)"' % key, s)
    return m.group(1) if m else default


def parse_size(svg):
    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg)
    return float(m.group(1)), float(m.group(2))


def parse_path_d(d):
    toks = re.findall(r"[MLZ]|[-\d.]+", d)
    pts, i, closed = [], 0, False
    while i < len(toks):
        t = toks[i]
        if t == "M":
            i += 1
            while i + 1 < len(toks) and re.match(r"^[-\d.]+$", toks[i]):
                pts.append((float(toks[i]), float(toks[i + 1])))
                i += 2
        elif t == "L":
            i += 1
            while i + 1 < len(toks) and re.match(r"^[-\d.]+$", toks[i]):
                pts.append((float(toks[i]), float(toks[i + 1])))
                i += 2
        elif t == "Z":
            closed = True
            i += 1
        else:
            i += 1
    return pts, closed


def render(svg, scale=3):
    w, h = parse_size(svg)
    im = Image.new("RGB", (int(w * scale) + 40, int(h * scale) + 40), (255, 255, 255))
    dr = ImageDraw.Draw(im)
    off = 20

    def P(x, y):
        return (x * scale + off, y * scale + off)

    for tag, attrs in TAG_RE.findall(svg):
        color = attr(attrs, "stroke") or "#1e293b"
        if attr(attrs, "fill") == "url(#f-hatch)":
            color = "#94a3b8"
        fill = color
        lw = max(1, int(float(attr(attrs, "stroke-width", "1.6") or 1.6) * scale * 0.8))
        dash = "stroke-dasharray" in attrs

        def seg(a, b):
            if not dash:
                dr.line([P(*a), P(*b)], fill=fill, width=lw)
            else:
                (x1, y1), (x2, y2) = P(*a), P(*b)
                n = max(1, int(((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5 / (5 * scale * 0.8)))
                for k in range(n):
                    if k % 2 == 0:
                        t0, t1 = k / n, min((k + 0.6) / n, 1.0)
                        dr.line(
                            [(x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0),
                             (x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1)],
                            fill=fill, width=lw)

        if tag == "line":
            seg((float(attr(attrs, "x1")), float(attr(attrs, "y1"))),
                (float(attr(attrs, "x2")), float(attr(attrs, "y2"))))
        elif tag == "path":
            pts, closed = parse_path_d(attr(attrs, "d", ""))
            for k in range(len(pts) - 1):
                seg(pts[k], pts[k + 1])
            if closed and len(pts) > 2:
                seg(pts[-1], pts[0])
        elif tag == "ellipse":
            cx, cy = float(attr(attrs, "cx")), float(attr(attrs, "cy"))
            rx, ry = float(attr(attrs, "rx")) * scale, float(attr(attrs, "ry")) * scale
            box = [cx * scale + off - rx, cy * scale + off - ry,
                   cx * scale + off + rx, cy * scale + off + ry]
            if dash:
                dr.ellipse(box, outline=fill, width=lw)
                dr.ellipse(box, outline=(255, 255, 255), width=lw)  # 简易虚线：留白后再描
            dr.ellipse(box, outline=fill, width=lw)
        elif tag == "circle":
            cx, cy = float(attr(attrs, "cx")), float(attr(attrs, "cy"))
            r = float(attr(attrs, "r")) * scale
            dr.ellipse([cx * scale + off - r, cy * scale + off - r,
                        cx * scale + off + r, cy * scale + off + r],
                       fill=fill if attr(attrs, "fill", "none") != "none" else None,
                       outline=fill, width=lw)
        elif tag == "text":
            m = re.search(r"<text[^>]*>(.*?)</text>", svg, re.S)
            # 逐个处理：这里靠外层循环拿不到文本，单独再扫一遍
            continue
    # 文本单独扫（正则拿标签内容）
    for m in re.finditer(r'<text x="([-\d.]+)" y="([-\d.]+)"[^>]*font-size="([\d.]+)"'
                         r'[^>]*fill="([^"]*)"[^>]*>(.*?)</text>', svg, re.S):
        x, y, fs, col, txt = float(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4), m.group(5)
        f = load_font(int(fs * scale * 0.9))
        px, py = P(x, y)
        bbox = dr.textbbox((0, 0), txt, font=f)
        dr.text((px - (bbox[2] - bbox[0]) / 2, py - (bbox[3] - bbox[1]) / 2), txt, font=f, fill=col)
    return im


def main():
    src = sys.argv[1]
    scale = float(sys.argv[2]) if len(sys.argv) > 2 else 3
    files = [src] if src.endswith(".svg") else [
        os.path.join(src, f) for f in sorted(os.listdir(src)) if f.endswith(".svg")]
    for f in files:
        svg = open(f, encoding="utf-8").read()
        im = render(svg, scale)
        out = f[:-4] + ".png"
        im.save(out)
        print(out, im.size)


if __name__ == "__main__":
    main()
