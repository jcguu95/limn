"""v0.38 dogfood — shared image/structure helpers. Session-scoped."""
from PIL import Image
import hashlib, sys, json, os


def mean_brightness(path, box=None):
    im = Image.open(path).convert("L")
    if box:
        im = im.crop(box)
    px = list(im.getdata())
    return sum(px) / len(px)


def pixel_at(path, x, y):
    return Image.open(path).convert("RGB").getpixel((x, y))


def hash_region(path, box):
    im = Image.open(path).crop(box)
    return hashlib.sha256(im.tobytes()).hexdigest()[:16]


def color_count(path, target_rgb, tolerance=20, box=None):
    """Count pixels close to target_rgb within tolerance (per-channel)."""
    im = Image.open(path).convert("RGB")
    if box:
        im = im.crop(box)
    tr, tg, tb = target_rgb
    n = 0
    for r, g, b in im.getdata():
        if abs(r - tr) <= tolerance and abs(g - tg) <= tolerance and abs(b - tb) <= tolerance:
            n += 1
    return n


def variance(path, box=None):
    im = Image.open(path).convert("L")
    if box:
        im = im.crop(box)
    px = list(im.getdata())
    mu = sum(px) / len(px)
    return sum((p - mu) ** 2 for p in px) / len(px)


def image_size(path):
    return Image.open(path).size


if __name__ == "__main__":
    # CLI usage: python3 lib.py <fn> <path> [args...]
    fn = sys.argv[1]
    args = sys.argv[2:]
    # crude arg coercion
    coerced = []
    for a in args:
        try:
            coerced.append(int(a))
        except ValueError:
            try:
                coerced.append(float(a))
            except ValueError:
                coerced.append(a)
    print(globals()[fn](*coerced))
