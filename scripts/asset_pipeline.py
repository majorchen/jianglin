# -*- coding: utf-8 -*-
"""
降临 v2 资产后处理管线
raw/v2 的 AI 原图 → 去魔法粉背景 → 规范尺寸(1单位=48px) → 全局48色调色板 → staging 目录

用法:
  python scripts/asset_pipeline.py            # 处理全部
  python scripts/asset_pipeline.py --contact  # 只重新生成对照表
输出:
  assets_hd2d/v2_staging/{characters,buildings,terrain,props}/
  assets_hd2d/v2_staging/_contact_sheet.png   # 人工质检用对照表
"""
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "assets_hd2d" / "raw" / "v2"
OUT = ROOT / "assets_hd2d" / "v2_staging"

PALETTE_COLORS = 64
PPU = 48  # pixels per world unit

# 角色: 4x4 sheet, 每帧 48x72
CHAR_SHEETS = {
    "engineer_walk_sheet.png": "engineer_walk_sheet.png",
    "scientist_walk_sheet.png": "scientist_walk_sheet.png",
    "scavenger_walk_sheet.png": "scavenger_walk_sheet.png",
}
CHAR_CELL = (48, 72)

# 建筑: 文件名 -> (输出名, 目标宽px)
BUILDINGS = {
    "b0_radio.png": ("b0.png", 144),
    "b1_greenhouse.png": ("b1.png", 192),
    "b2_bunker.png": ("b2.png", 192),
    "b3_watchtower.png": ("b3.png", 144),
    "b4_kitchen.png": ("b4.png", 192),
}

# 地形: 文件名 -> (输出名, 目标边长)
TERRAIN = {
    "ground_dirt.png": ("ground_dirt.png", 384),
    "ground_rocky.png": ("ground_rocky.png", 384),
    "ground_path.png": ("ground_path.png", 192),
}

PROPS_SHEET = "props_sheet.png"
PROP_NAMES = ["barrel", "crates", "campfire", "fence", "watertank", "debris", "solar", "bench"]
PROP_CELL = 96


def chroma_key(img: Image.Image) -> Image.Image:
    """去 #ff00ff 系背景（含 AI 抗锯齿边缘的粉色 fringe）"""
    img = img.convert("RGBA")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if r - g > 70 and b - g > 70:  # 粉/紫系背景与 fringe
                px[x, y] = (0, 0, 0, 0)
    return img


def bbox_crop(img: Image.Image) -> Image.Image:
    box = img.getbbox()
    return img.crop(box) if box else img


def fit_into(img: Image.Image, cell_w: int, cell_h: int) -> Image.Image:
    """等比缩放(nearest)放进 cell，底部对齐（角色脚贴地）"""
    scale = min(cell_w / img.width, cell_h / img.height)
    nw, nh = max(1, round(img.width * scale)), max(1, round(img.height * scale))
    small = img.resize((nw, nh), Image.NEAREST)
    canvas = Image.new("RGBA", (cell_w, cell_h), (0, 0, 0, 0))
    canvas.paste(small, ((cell_w - nw) // 2, cell_h - nh))
    return canvas


def grid_cells(img: Image.Image, cols: int, rows: int):
    cw, ch = img.width // cols, img.height // rows
    for r in range(rows):
        for c in range(cols):
            yield img.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))


def process_char_sheet(path: Path) -> Image.Image:
    img = chroma_key(Image.open(path))
    cw, chh = CHAR_CELL
    sheet = Image.new("RGBA", (cw * 4, chh * 4), (0, 0, 0, 0))
    cells = list(grid_cells(img, 4, 4))
    # 用整行统一 bbox 高度做缩放基准，避免帧间忽大忽小
    for r in range(4):
        row = cells[r * 4:(r + 1) * 4]
        heights = [c.getbbox()[3] - c.getbbox()[1] for c in row if c.getbbox()]
        ref_h = max(heights) if heights else chh
        for i, cell in enumerate(row):
            content = bbox_crop(cell)
            scale = min((chh - 2) / max(ref_h, 1), (cw - 2) / max(content.width, 1))
            nw, nh = max(1, round(content.width * scale)), max(1, round(content.height * scale))
            small = content.resize((nw, nh), Image.NEAREST)
            sheet.paste(small, (r * 0 + i * cw + (cw - nw) // 2, r * chh + (chh - nh - 1)))
    return sheet


def process_building(path: Path, target_w: int) -> Image.Image:
    img = bbox_crop(chroma_key(Image.open(path)))
    scale = target_w / img.width
    return img.resize((target_w, max(1, round(img.height * scale))), Image.NEAREST)


def process_terrain(path: Path, size: int) -> Image.Image:
    img = Image.open(path).convert("RGB")
    side = min(img.size)
    img = img.crop((0, 0, side, side))
    return img.resize((size, size), Image.NEAREST)


def process_props(path: Path) -> dict:
    img = chroma_key(Image.open(path))
    out = {}
    for name, cell in zip(PROP_NAMES, grid_cells(img, 4, 2)):
        content = bbox_crop(cell)
        out[name + ".png"] = fit_into(content, PROP_CELL, PROP_CELL)
    return out


def build_master_palette(images) -> Image.Image:
    """从全部成品收集不透明像素，median-cut 出全局调色板"""
    pixels = []
    for img in images:
        rgba = img.convert("RGBA")
        data = rgba.getdata()
        pixels.extend([(r, g, b) for r, g, b, a in data if a > 8])
    if not pixels:
        raise RuntimeError("no pixels for palette")
    strip = Image.new("RGB", (len(pixels), 1))
    strip.putdata(pixels)
    return strip.quantize(colors=PALETTE_COLORS, method=Image.MEDIANCUT)


def quantize_per_image(img: Image.Image, colors: int) -> Image.Image:
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    rgb = rgba.convert("RGB").quantize(colors=colors, method=Image.MEDIANCUT, dither=Image.NONE).convert("RGB")
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def contact_sheet(items: dict) -> Image.Image:
    pad, col_w = 12, 220
    cols = 6
    rows = (len(items) + cols - 1) // cols
    row_h = 320
    board = Image.new("RGB", (cols * col_w + pad, rows * row_h + pad), (40, 36, 32))
    for i, (name, img) in enumerate(items.items()):
        x = pad + (i % cols) * col_w
        y = pad + (i // cols) * row_h
        thumb = img.copy()
        thumb.thumbnail((col_w - pad * 2, row_h - pad * 2), Image.NEAREST)
        board.paste(thumb.convert("RGB"), (x, y), thumb.convert("RGBA") if thumb.mode == "RGBA" else None)
    return board


def main():
    results = {}  # 相对输出路径 -> Image
    missing = []

    for raw_name, out_name in CHAR_SHEETS.items():
        p = RAW / raw_name
        if p.exists():
            results["characters/" + out_name] = process_char_sheet(p)
        else:
            missing.append(raw_name)

    for raw_name, (out_name, tw) in BUILDINGS.items():
        p = RAW / raw_name
        if p.exists():
            results["buildings/" + out_name] = process_building(p, tw)
        else:
            missing.append(raw_name)

    for raw_name, (out_name, size) in TERRAIN.items():
        p = RAW / raw_name
        if p.exists():
            results["terrain/" + out_name] = process_terrain(p, size)
        else:
            missing.append(raw_name)

    p = RAW / PROPS_SHEET
    if p.exists():
        for name, img in process_props(p).items():
            results["props/" + name] = img
    else:
        missing.append(PROPS_SHEET)

    if not results:
        print("nothing to process; raw/v2 empty")
        sys.exit(1)

    # 逐图量化：全局合板会让地形的海量棕色像素淹没角色/建筑的点缀色（如温室绿）
    for key in results:
        results[key] = quantize_per_image(results[key], PALETTE_COLORS)

    for key, img in results.items():
        dest = OUT / key
        dest.parent.mkdir(parents=True, exist_ok=True)
        img.save(dest)
        print(f"OK {key} {img.size}")

    cs = contact_sheet(results)
    cs.save(OUT / "_contact_sheet.png")
    print(f"contact sheet -> {OUT / '_contact_sheet.png'}")
    if missing:
        print("MISSING:", ", ".join(missing))


if __name__ == "__main__":
    main()
