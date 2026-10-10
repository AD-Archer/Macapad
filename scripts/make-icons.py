#!/usr/bin/env python3
"""Builds the app and menu bar icons from assets/. Needs Pillow (pip install pillow).

  assets/icon-source.png     -> Resources/AppIcon.icns
  assets/menubar-source.png  -> Resources/MenuBarIcon.png (+ @2x), a template image
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
OUT = ROOT / "Resources"

# Apple's macOS icon grid: 1024 canvas, 824 rounded square, ~185 corner radius.
CANVAS, BODY, RADIUS = 1024, 824, 185
MENUBAR_HEIGHT_PT = 16


def median_edge_color(im):
    """The source's background colour, taken from its border pixels."""
    w, h = im.size
    border = [im.getpixel((x, y)) for x in range(w) for y in (0, h - 1)]
    border += [im.getpixel((x, y)) for y in range(h) for x in (0, w - 1)]
    return tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3)) + (255,)


def app_icon():
    src = Image.open(ASSETS / "icon-source.png").convert("RGBA")
    bg = median_edge_color(src)
    inset = (CANVAS - BODY) // 2

    # Background colour, then the artwork scaled to fit with its edges feathered into it.
    body = Image.new("RGBA", (BODY, BODY), bg)
    scale = BODY * 0.96 / max(src.size)
    art = src.resize((round(src.width * scale), round(src.height * scale)), Image.LANCZOS)
    feather = Image.new("L", art.size, 0)
    ImageDraw.Draw(feather).rectangle((24, 24, art.width - 25, art.height - 25), fill=255)
    art.putalpha(ImageChops.multiply(art.getchannel("A"), feather.filter(ImageFilter.GaussianBlur(14))))
    body.alpha_composite(art, ((BODY - art.width) // 2, (BODY - art.height) // 2))

    mask = Image.new("L", (BODY, BODY), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, BODY - 1, BODY - 1), RADIUS, fill=255)
    body.putalpha(mask)

    # Soft drop shadow, as on system icons.
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (inset, inset + 12), mask)
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    icon.alpha_composite(body, (inset, inset))

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)


def menubar_icon():
    """Template image: only the alpha channel matters; macOS tints it for light/dark menu bars."""
    src = Image.open(ASSETS / "menubar-source.png").convert("RGBA")
    alpha = src.getchannel("A")
    alpha = alpha.crop(alpha.getbbox())
    width_pt = round(alpha.width * MENUBAR_HEIGHT_PT / alpha.height)
    for scale, suffix in ((1, ""), (2, "@2x")):
        w, h = width_pt * scale, MENUBAR_HEIGHT_PT * scale
        out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        out.putalpha(alpha.resize((w, h), Image.LANCZOS))
        out.save(OUT / f"MenuBarIcon{suffix}.png")


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    app_icon()
    menubar_icon()
    print("Wrote", ", ".join(sorted(p.name for p in OUT.iterdir())))
