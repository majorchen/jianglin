"""火焰条处理：去 magenta → 4 等分取 bbox → 统一 32x48 → 拼 128x48 横条"""
from PIL import Image

SRC = r"E:\claude-workspace\jianglin\assets_hd2d\raw\v3\campfire_flame_strip.png"
DST = r"E:\claude-workspace\jianglin\assets_hd2d\props\flame.png"
CELL_W, CELL_H = 32, 48

img = Image.open(SRC).convert("RGBA")
px = img.load()
for y in range(img.height):
    for x in range(img.width):
        r, g, b, a = px[x, y]
        # magenta 及其边缘 fringe
        if r > 160 and b > 160 and g < 130:
            px[x, y] = (0, 0, 0, 0)

w4 = img.width // 4
frames = []
for i in range(4):
    cell = img.crop((i * w4, 0, (i + 1) * w4, img.height))
    bbox = cell.getbbox()
    if bbox is None:
        frames.append(Image.new("RGBA", (CELL_W, CELL_H)))
        continue
    cell = cell.crop(bbox)
    scale = min(CELL_W / cell.width, CELL_H / cell.height)
    nw, nh = max(1, int(cell.width * scale)), max(1, int(cell.height * scale))
    cell = cell.resize((nw, nh), Image.NEAREST)
    canvas = Image.new("RGBA", (CELL_W, CELL_H))
    canvas.paste(cell, ((CELL_W - nw) // 2, CELL_H - nh))  # 底部对齐
    frames.append(canvas)

sheet = Image.new("RGBA", (CELL_W * 4, CELL_H))
for i, f in enumerate(frames):
    sheet.paste(f, (i * CELL_W, 0))
sheet.save(DST)
print("OK", DST, sheet.size)
