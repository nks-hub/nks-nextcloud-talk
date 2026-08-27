"""Generates the NKS Talk app icon and every launcher size from it.

The mark is a cloud whose bottom-left corner is pulled into a speech bubble
tail - the two things the app is about in one shape. Drawn from primitives
rather than shipped as a binary so a colour or proportion change is a one-line
edit, and so the source of every pixel is reviewable.

Nothing here reuses Nextcloud's own mark; the app talks to Nextcloud servers
but is not published by them.

Run from apps/mobile/:  python tools/generate_app_icon.py
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "assets" / "brand"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
APPICONSET = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
MACOS_APPICONSET = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
WINDOWS_ICON = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"

# Seed colour of the app theme (lib/core/app_theme.dart) and a darker tone for
# the corner-to-corner gradient, so the icon still reads on a white launcher.
BLUE_LIGHT = (0x1B, 0x8A, 0xC4)
BLUE_DARK = (0x00, 0x52, 0x80)
WHITE = (0xFF, 0xFF, 0xFF)

# Everything is drawn at 4x and downsampled - PIL has no antialiasing of its
# own, so this is what keeps the curves clean.
SUPERSAMPLE = 4
SIZE = 1024

# Android masks the adaptive foreground down to the middle 72 of 108 dp. Keep
# the mark below that outer safe-zone boundary so it has the same calmer scale
# as the legacy launcher and Apple icons.
ADAPTIVE_SHARE = 0.55

# Android 12 expands splash foregrounds to 150% of the icon bounds. A 4/9 mark
# therefore renders at 2/3 of the final mask instead of a clipped 99%.
SPLASH_MARK_SHARE = 4 / 9

# The internal source scale remains 66% so regenerating the separately tuned
# Android splash asset stays byte-for-byte stable.
MARK_SHARE = 0.66

# The previous 66% launcher mark read too large. 55% keeps the same shape at
# 83.3% of its former scale and leaves a platform-safe visual margin.
LAUNCHER_MARK_SHARE = 0.55

# Desktop platforms do not apply the same mandatory mask as iOS and Android.
# Put the branded tile inside a transparent safe zone so Finder, the Dock,
# Explorer, the title bar and the taskbar do not render a corner-to-corner box.
DESKTOP_TILE_SHARE = 0.84
DESKTOP_CORNER_RADIUS_SHARE = 0.22

LAUNCHER_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def gradient(size: int) -> Image.Image:
    """Diagonal two-stop gradient, top-left light to bottom-right dark."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            # Diagonal position, 0 at top-left corner and 1 at bottom-right.
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(
                round(BLUE_LIGHT[i] + (BLUE_DARK[i] - BLUE_LIGHT[i]) * t)
                for i in range(3)
            )
    return img


def cloud_mask(size: int) -> Image.Image:
    """The white mark: a cloud with a speech-bubble tail, as an alpha mask."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    u = size / 100.0  # work in percent of the canvas, so proportions survive resizing

    def ellipse(cx, cy, rx, ry):
        d.ellipse(
            [(cx - rx) * u, (cy - ry) * u, (cx + rx) * u, (cy + ry) * u], fill=255
        )

    # Three overlapping lobes plus a slab underneath give the classic cloud
    # silhouette without any single circle reading as a separate dot.
    ellipse(38, 46, 16, 16)
    ellipse(58, 40, 20, 20)
    ellipse(72, 52, 14, 14)
    d.rounded_rectangle(
        [22 * u, 46 * u, 86 * u, 68 * u],
        radius=11 * u,
        fill=255,
    )

    # The tail. Anchored inside the cloud body so the two shapes read as one
    # outline, not a cloud with a triangle stuck to it. Kept short - a long thin
    # tail is the first thing to disappear at 48 px.
    d.polygon(
        [(36 * u, 63 * u), (36 * u, 78 * u), (52 * u, 66 * u)],
        fill=255,
    )

    # Three dots punched back out of the cloud. Without them the mark is one
    # large white blob that reads as "cloud" and nothing else; with them it says
    # "someone is typing" at any size. Cut rather than drawn, so the adaptive
    # foreground shows the launcher background through them.
    for cx in (44, 55, 66):
        d.ellipse(
            [(cx - 4.4) * u, (50 - 4.4) * u, (cx + 4.4) * u, (50 + 4.4) * u],
            fill=0,
        )

    return mask


def centred(mask: Image.Image, share: float) -> Image.Image:
    """Trims the mark to its own bounds and re-centres it at `share` of the canvas.

    Drawing coordinates are a poor way to centre a shape built from overlapping
    lobes - the visual centre is not the arithmetic one, and every proportion
    tweak shifts it again. Measuring the drawn result instead keeps the margin
    honest whatever the shape does.
    """
    size = mask.size[0]
    bounds = mask.getbbox()
    if bounds is None:
        return mask

    trimmed = mask.crop(bounds)
    edge = round(size * share)
    scale = min(edge / trimmed.width, edge / trimmed.height)
    scaled = trimmed.resize(
        (max(1, round(trimmed.width * scale)), max(1, round(trimmed.height * scale))),
        Image.LANCZOS,
    )

    canvas = Image.new("L", (size, size), 0)
    canvas.paste(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2))

    return canvas


def build_mark(
    size: int,
    background: Image.Image | None,
    mark_share: float = MARK_SHARE,
) -> Image.Image:
    """Renders the icon at `size`, optionally over a background."""
    big = size * SUPERSAMPLE
    mask = centred(cloud_mask(big), mark_share)

    if background is None:
        canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    else:
        canvas = background.resize((big, big), Image.LANCZOS).convert("RGBA")

    white = Image.new("RGBA", (big, big), WHITE + (255,))
    canvas.paste(white, (0, 0), mask)

    return canvas.resize((size, size), Image.LANCZOS)


def adaptive_foreground(size: int, mark_share: float = ADAPTIVE_SHARE) -> Image.Image:
    """Transparent foreground with the mark shrunk to survive the round mask."""
    inner = round(size * mark_share / MARK_SHARE)
    mark = build_mark(inner, None)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = (size - inner) // 2
    canvas.paste(mark, (offset, offset), mark)

    return canvas


def desktop_icon(size: int) -> Image.Image:
    """Renders the mark on a rounded branded tile with a transparent margin."""
    tile_size = round(size * DESKTOP_TILE_SHARE)
    tile = build_mark(tile_size, gradient(tile_size), LAUNCHER_MARK_SHARE)

    tile_mask = Image.new("L", (tile_size, tile_size), 0)
    ImageDraw.Draw(tile_mask).rounded_rectangle(
        (0, 0, tile_size - 1, tile_size - 1),
        radius=round(tile_size * DESKTOP_CORNER_RADIUS_SHARE),
        fill=255,
    )
    tile.putalpha(tile_mask)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = (size - tile_size) // 2
    canvas.alpha_composite(tile, (offset, offset))
    return canvas


def write_catalog(icon: Image.Image, appiconset: Path, platform: str) -> list[str]:
    """Writes every raster requested by an Apple asset catalogue."""
    catalogue = json.loads((appiconset / "Contents.json").read_text(encoding="utf-8"))
    written = []
    for image in catalogue["images"]:
        filename = image.get("filename")
        if not filename:
            continue
        base = float(image["size"].split("x")[0])
        scale = float(image["scale"].rstrip("x"))
        px = round(base * scale)
        icon.resize((px, px), Image.LANCZOS).save(appiconset / filename)
        written.append(f"{platform}/{filename}")
    return written


def main() -> None:
    BRAND.mkdir(parents=True, exist_ok=True)
    bg = gradient(SIZE)

    icon = build_mark(SIZE, bg, LAUNCHER_MARK_SHARE)
    icon.save(BRAND / "app-icon.png")

    # Play Store listing wants exactly 512x512, 32-bit PNG.
    icon.resize((512, 512), Image.LANCZOS).save(BRAND / "play-store-icon.png")

    foreground = adaptive_foreground(SIZE)
    foreground.save(BRAND / "app-icon-foreground.png")

    splash_target = RES / "drawable-nodpi"
    splash_target.mkdir(parents=True, exist_ok=True)
    adaptive_foreground(SIZE, SPLASH_MARK_SHARE).save(
        splash_target / "splash_icon_foreground.png"
    )

    written = []
    for folder, px in LAUNCHER_SIZES.items():
        target = RES / folder
        target.mkdir(parents=True, exist_ok=True)

        icon.resize((px, px), Image.LANCZOS).save(target / "ic_launcher.png")
        adaptive_foreground(px).save(target / "ic_launcher_foreground.png")
        written.append(f"{folder}/{px}px")

    # iOS ships the same mark at the sizes its own Contents.json asks for, so
    # the catalogue stays the source of truth for which files exist and this
    # only fills them in. Written flattened onto the gradient rather than with
    # an alpha channel, which the App Store rejects.
    opaque = icon.convert("RGB")
    written.extend(write_catalog(opaque, APPICONSET, "ios"))

    # macOS and Windows ship the same motif on a rounded tile. The transparent
    # margin is part of the asset because neither platform supplies the mobile
    # launcher mask. Generate every catalogued macOS size and every useful ICO
    # frame from the same 1024 px source.
    desktop = desktop_icon(SIZE)
    written.extend(write_catalog(desktop, MACOS_APPICONSET, "macos"))
    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)
    desktop.resize((256, 256), Image.LANCZOS).save(
        WINDOWS_ICON,
        format="ICO",
        sizes=[
            (16, 16),
            (20, 20),
            (24, 24),
            (32, 32),
            (40, 40),
            (48, 48),
            (64, 64),
            (128, 128),
            (256, 256),
        ],
    )
    written.append("windows/app_icon.ico")

    # Adaptive icon: solid background colour, our mark as the foreground layer.
    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        f'    <color name="ic_launcher_background">#{BLUE_DARK[0]:02X}'
        f"{BLUE_DARK[1]:02X}{BLUE_DARK[2]:02X}</color>\n"
        "</resources>\n",
        encoding="utf-8",
    )

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    (anydpi / "ic_launcher.xml").write_text(adaptive, encoding="utf-8")
    (anydpi / "ic_launcher_round.xml").write_text(adaptive, encoding="utf-8")

    print(
        json.dumps(
            {
                "zdroj": str(BRAND),
                "splash": "drawable-nodpi/1024px",
                "launcher": written,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
