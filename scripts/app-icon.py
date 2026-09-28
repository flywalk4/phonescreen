#!/usr/bin/env python3
# Draws the app icons (iPhone: full-bleed 1024; Mac: Big Sur plate, all sizes) with Pillow.
#   python3 scripts/app-icon.py <out-dir>   — then copy into iOS/Assets.xcassets and Mac/Assets.xcassets
from PIL import Image, ImageDraw, ImageFilter
import math, sys
S = 2048  # draw big, downscale for smooth edges

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def gradient(size, c1, c2):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x * 0.35 + y * 0.65) / size
            px[x, y] = lerp(c1, c2, min(1, max(0, t)))
    return img

def rr(draw, box, r, **kw): draw.rounded_rectangle(box, radius=r, **kw)

def artwork(size):
    """The picture itself (square, full bleed)."""
    k = size / 1024
    bg = gradient(size, (58, 38, 170), (150, 60, 220)).convert("RGBA")
    # soft glow
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse([int(560*k), int(120*k), int(1100*k), int(660*k)], fill=(255, 150, 255, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(120 * k))
    bg = Image.alpha_composite(bg, glow)

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # phone body (shadow first)
    px0, py0, px1, py1 = 360*k, 170*k, 760*k, 880*k
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([px0+10*k, py0+30*k, px1+10*k, py1+30*k], radius=90*k, fill=(10, 0, 40, 150))
    sh = sh.filter(ImageFilter.GaussianBlur(40 * k))
    layer = Image.alpha_composite(layer, sh); d = ImageDraw.Draw(layer)
    rr(d, [px0, py0, px1, py1], 90*k, fill=(18, 16, 30, 255))
    rr(d, [px0+22*k, py0+22*k, px1-22*k, py1-22*k], 70*k, fill=(28, 26, 44, 255))
    # island
    rr(d, [510*k, 205*k, 610*k, 240*k], 18*k, fill=(0, 0, 0, 255))
    # widget tiles 2x2 + wide
    tiles = [
        ([402*k, 268*k, 552*k, 418*k], (255, 159, 67)),
        ([568*k, 268*k, 718*k, 418*k], (72, 219, 164)),
        ([402*k, 434*k, 552*k, 584*k], (77, 166, 255)),
        ([568*k, 434*k, 718*k, 584*k], (255, 94, 150)),
        ([402*k, 600*k, 718*k, 838*k], (170, 140, 255)),
    ]
    for box, col in tiles:
        rr(d, box, 30*k, fill=col + (255,))
    # tiny content hints
    d.ellipse([430*k, 296*k, 524*k, 390*k], outline=(255, 255, 255, 230), width=int(14*k))
    for i, h in enumerate([40, 70, 55, 95, 80]):
        x = 430*k + i*24*k
        rr(d, [x, 810*k - h*k, x+16*k, 810*k], 6*k, fill=(255, 255, 255, 220))
    bg = Image.alpha_composite(bg, layer)

    # Mac pointer arriving from the left
    cur = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    c = ImageDraw.Draw(cur)
    ox, oy, sc = 190*k, 470*k, 1.9*k
    pts = [(0, 0), (0, 150), (38, 114), (64, 172), (92, 160), (66, 104), (118, 104)]
    poly = [(ox + x*sc, oy + y*sc) for x, y in pts]
    shc = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shc).polygon([(x+8*k, y+14*k) for x, y in poly], fill=(0, 0, 0, 140))
    shc = shc.filter(ImageFilter.GaussianBlur(14*k))
    cur = Image.alpha_composite(cur, shc); c = ImageDraw.Draw(cur)
    c.polygon(poly, fill=(20, 20, 24, 255))
    inner = [(ox + x*sc, oy + y*sc) for x, y in [(12, 26), (12, 124), (40, 98), (68, 152), (80, 146), (52, 92), (92, 92)]]
    c.polygon(inner, fill=(255, 255, 255, 255))
    return Image.alpha_composite(bg, cur)

art = artwork(S).resize((1024, 1024), Image.LANCZOS)
out = sys.argv[1]
art.convert("RGB").save(f"{out}/ios-1024.png")

# macOS: squircle plate 824 on a 1024 canvas with a drop shadow (Big Sur grid).
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
plate = int(S * 824 / 1024); off = (S - plate) // 2
mask = Image.new("L", (plate, plate), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, plate - 1, plate - 1], radius=int(plate * 0.225), fill=255)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([off, off + int(20*S/1024), off + plate, off + plate + int(20*S/1024)], radius=int(plate*0.225), fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(28 * S / 1024))
canvas = Image.alpha_composite(canvas, shadow)
inner = artwork(plate)
canvas.paste(inner, (off, off), mask)
mac = canvas.resize((1024, 1024), Image.LANCZOS)
mac.save(f"{out}/mac-1024.png")
for px in [16, 32, 64, 128, 256, 512, 1024]:
    mac.resize((px, px), Image.LANCZOS).save(f"{out}/mac-{px}.png")
print("ok")
