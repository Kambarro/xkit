#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sitegen.py — детерминированный генератор правдоподобных сайтов-заглушек по сиду.

Назначение: маскировочные сайты для нод (файлообменники, хостинги картинок,
видеоредакторы, облака и т.д.). Один и тот же сид -> бит-в-бит одинаковый сайт.
Разные сиды -> тысячи уникальных комбинаций (категория сервиса, бренд, домен,
палитра, шрифты, layout, тексты, датасеты, SVG-графика, CSS с рандомизированными
именами классов).

Зависимости: только стандартная библиотека Python 3.8+.

Примеры:
    python3 sitegen.py my-secret-seed-42
    python3 sitegen.py node-17 -o /var/www/decoy
    python3 sitegen.py node-17 --info
    python3 sitegen.py --batch 40 --prefix NODE --out ./farms
    python3 sitegen.py seed --stdout index.html
"""

import argparse
import hashlib
import html as _html
import json
import os
import sys
from datetime import date, timedelta

VERSION = "1.0.0"
APP = "sitegen"


# ----------------------------------------------------------------------------
# 1. Детерминированный PRNG (SplitMix64). Ни одного вызова random.* / time.*
# ----------------------------------------------------------------------------

_MASK64 = (1 << 64) - 1


class Rng(object):
    """Поток стабильных псевдослучайных чисел из строки/байтов сида."""

    def __init__(self, seed):
        if isinstance(seed, str):
            seed = seed.encode("utf-8")
        elif isinstance(seed, int):
            seed = ("%d" % seed).encode("ascii")
        self._seed = bytes(seed)
        self.state = int.from_bytes(hashlib.sha256(self._seed).digest()[:8], "big") & _MASK64

    def spawn(self, label):
        """Дочерний поток для подсистемы (brand/css/pages/...): стабилен
        относительно исходного сида и не зависит от порядка вызовов родителя."""
        if isinstance(label, str):
            label = label.encode("utf-8")
        return Rng(self._seed + b"::" + label)

    def _next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & _MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _MASK64
        return z ^ (z >> 31)

    # --- примитивы -----------------------------------------------------------
    def randbits(self, n):
        return self._next() % (1 << n) if n > 0 else 0

    def random(self):
        return (self._next() >> 11) / float(1 << 53)

    def randrange(self, a, b=None):
        if b is None:
            return self._next() % a
        if b <= a:
            return a
        return a + self._next() % (b - a)

    def randint(self, a, b):
        return a + self._next() % (b - a + 1)

    def choice(self, seq):
        return seq[self._next() % len(seq)]

    def choices(self, seq, k):
        return [seq[self._next() % len(seq)] for _ in range(k)]

    def sample(self, seq, k):
        """Выбор k элементов без повторов (порядок результата случайный)."""
        if k >= len(seq):
            pool = list(seq)
            self.shuffle(pool)
            return pool
        picked = {}
        n = len(seq)
        for i in range(k):
            j = i + self._next() % (n - i)
            picked.setdefault(i, seq[i])
            v = picked.get(j, seq[j])
            picked[i], picked[j] = v, picked[i]
        return [picked[i] for i in range(k)]

    def shuffle(self, lst):
        for i in range(len(lst) - 1, 0, -1):
            j = self._next() % (i + 1)
            lst[i], lst[j] = lst[j], lst[i]

    def weighted(self, pairs):
        total = sum(w for _, w in pairs)
        r = self._next() % total if total > 0 else 0
        for item, w in pairs:
            r -= w
            if r < 0:
                return item
        return pairs[-1][0]

    def maybe(self, p):
        return self.random() < p

    def token(self, n=5):
        """Короткий токен [a-z][a-z0-9]+ — для имён CSS-классов, slug'ов."""
        alpha = "abcdefghijklmnopqrstuvwxyz"
        alnum = alpha + "0123456789"
        return self.choice(alpha) + "".join(self.choices(alnum, n - 1))

    def date_between(self, y0, y1):
        d0 = date(y0, 1, 1).toordinal()
        d1 = date(y1, 12, 31).toordinal()
        return date.fromordinal(d0 + self._next() % (d1 - d0 + 1))


# ----------------------------------------------------------------------------
# 2. Цветовые утилиты (hex/hsl, контраст WCAG, смешивание)
# ----------------------------------------------------------------------------

def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def hex_to_rgb(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def rgb_to_hex(r, g, b):
    return "#%02x%02x%02x" % (_clamp(int(round(r)), 0, 255),
                              _clamp(int(round(g)), 0, 255),
                              _clamp(int(round(b)), 0, 255))


def rgb_to_hsl(r, g, b):
    r, g, b = r / 255.0, g / 255.0, b / 255.0
    mx, mn = max(r, g, b), min(r, g, b)
    l = (mx + mn) / 2.0
    if mx == mn:
        h = s = 0.0
    else:
        d = mx - mn
        s = d / (2 - mx - mn) if l > 0.5 else d / (mx + mn)
        if mx == r:
            h = ((g - b) / d + (6 if g < b else 0)) / 6.0
        elif mx == g:
            h = ((b - r) / d + 2) / 6.0
        else:
            h = ((r - g) / d + 4) / 6.0
    return h * 360.0, s, l


def hsl_to_hex(h, s, l):
    h = (h % 360.0) / 360.0
    s, l = _clamp(s, 0, 1), _clamp(l, 0, 1)
    if s == 0:
        v = int(round(l * 255))
        return rgb_to_hex(v, v, v)

    def hue2rgb(p, q, t):
        if t < 0:
            t += 1
        if t > 1:
            t -= 1
        if t < 1 / 6:
            return p + (q - p) * 6 * t
        if t < 1 / 2:
            return q
        if t < 2 / 3:
            return p + (q - p) * (2 / 3 - t) * 6
        return p

    q = l * (1 + s) if l < 0.5 else l + s - l * s
    p = 2 * l - q
    return rgb_to_hex(hue2rgb(p, q, h + 1 / 3) * 255,
                      hue2rgb(p, q, h) * 255,
                      hue2rgb(p, q, h - 1 / 3) * 255)


def mix(c1, c2, t):
    """Смешивание двух hex-цветов, t=0 -> c1, t=1 -> c2."""
    a, b = hex_to_rgb(c1), hex_to_rgb(c2)
    return rgb_to_hex(a[0] + (b[0] - a[0]) * t,
                      a[1] + (b[1] - a[1]) * t,
                      a[2] + (b[2] - a[2]) * t)


def lighten(c, t):
    return mix(c, "#ffffff", t)


def darken(c, t):
    return mix(c, "#000000", t)


def set_sat(c, s):
    h, _, l = rgb_to_hsl(*hex_to_rgb(c))
    return hsl_to_hex(h, s, l)


def set_lum(c, l):
    h, s, _ = rgb_to_hsl(*hex_to_rgb(c))
    return hsl_to_hex(h, s, l)


def rel_luminance(c):
    def chan(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = hex_to_rgb(c)
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)


def contrast(c1, c2):
    l1, l2 = rel_luminance(c1), rel_luminance(c2)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def best_on(bg):
    """Чёрный или белый текст — что контрастнее на фоне."""
    return "#111111" if contrast(bg, "#111111") >= contrast(bg, "#ffffff") else "#ffffff"


def ensure_contrast(fg, bg, min_ratio=4.5):
    """Сдвигает светлоту fg, пока контраст с bg не достигнет порога."""
    if contrast(fg, bg) >= min_ratio:
        return fg
    h, s, l = rgb_to_hsl(*hex_to_rgb(fg))
    dark_bg = rel_luminance(bg) < 0.35
    step = 0.04
    for i in range(1, 40):
        l2 = _clamp(l - step * i if dark_bg else l + step * i, 0.02, 0.98)
        cand = hsl_to_hex(h, s, l2)
        if contrast(cand, bg) >= min_ratio:
            return cand
    return best_on(bg)


# ----------------------------------------------------------------------------
# 3. Палитры: 36 курируемых + процедурные (гармонии), отбор с гарантией контраста
# ----------------------------------------------------------------------------

_STATUS_DARK = {"ok": "#4ade80", "warn": "#fbbf24", "bad": "#f87171"}
_STATUS_LIGHT = {"ok": "#15803d", "warn": "#b45309", "bad": "#b91c1c"}


def _P(name, mode, bg, surface, surface_alt, text, muted, border,
       accent, accent2, accent3, on_accent):
    p = {
        "name": name, "mode": mode, "bg": bg, "surface": surface,
        "surface_alt": surface_alt, "text": text, "muted": muted,
        "border": border, "accent": accent, "accent2": accent2,
        "accent3": accent3, "on_accent": on_accent,
    }
    p.update(_STATUS_DARK if mode == "dark" else _STATUS_LIGHT)
    return p


PALETTES = [
    # --- тёмные ---------------------------------------------------------------
    _P("midnight", "dark", "#0b1021", "#131a33", "#0f1529", "#e9edfb", "#97a3c7",
       "#25305a", "#6d9bff", "#9a6dff", "#35d0e0", "#ffffff"),
    _P("deepsea", "dark", "#071820", "#0d2530", "#0a1f28", "#e2f2f6", "#8fb0bb",
       "#1d3d4a", "#19c2d6", "#2f8fd6", "#6ee7b7", "#052e37"),
    _P("carbon", "dark", "#101213", "#191b1e", "#141619", "#eceef1", "#a4a9b3",
       "#2a2d33", "#c6f24e", "#7dd3fc", "#fbbf24", "#1a2200"),
    _P("terminal", "dark", "#0a0f0b", "#0f1a12", "#0c140e", "#d9f2e0", "#8fae99",
       "#1f3527", "#34d17b", "#58c9d8", "#d3e26a", "#062515"),
    _P("plum", "dark", "#150a1e", "#221031", "#1b0d29", "#f0e6fa", "#b39ecb",
       "#3a2152", "#c66bff", "#ff6bd5", "#6bd5ff", "#2a0745"),
    _P("coffee", "dark", "#17110d", "#241b14", "#1d1610", "#f4ead9", "#bda78d",
       "#3d2f22", "#e0a458", "#d97d54", "#9cc08a", "#2a1a05"),
    _P("navy", "dark", "#0a1226", "#122040", "#0e1a33", "#e6ecff", "#93a4cf",
       "#22355f", "#e3b341", "#5b8cff", "#63d3b7", "#2b1f00"),
    _P("berry", "dark", "#1b0a14", "#2a1020", "#210c18", "#fbe9f3", "#c393ab",
       "#44203a", "#f45e9d", "#b06bff", "#ffb26b", "#3a0022"),
    _P("steel", "dark", "#14171c", "#1e2229", "#191d23", "#e7ebf2", "#a0a9b8",
       "#303642", "#59a5f6", "#98d0ff", "#f2a25c", "#001e3c"),
    _P("sunset", "dark", "#1d0e14", "#2b161f", "#241018", "#fbeae4", "#c7a09a",
       "#472731", "#ff7a59", "#ff5d8f", "#ffc46b", "#33110a"),
    _P("aurora", "dark", "#081410", "#0f241e", "#0b1c17", "#e4f6ef", "#93bfae",
       "#1d3d33", "#3ddc97", "#6b8dff", "#b78bff", "#032b1f"),
    _P("olive", "dark", "#15170a", "#212410", "#1a1d0d", "#eef0dd", "#b3b78c",
       "#373b1c", "#c0d94a", "#6bc4a8", "#e0b45c", "#1f2800"),
    _P("copper", "dark", "#181412", "#252019", "#1e1a16", "#f5ece5", "#bfa99b",
       "#3e332a", "#e2763f", "#c9a24b", "#8ecbb7", "#2f1404"),
    _P("mono-dark", "dark", "#0c0c0d", "#171718", "#121213", "#f2f2f3", "#a8a8ad",
       "#2b2b2e", "#f5f5f7", "#9d9da8", "#58d68d", "#111113"),
    _P("vapor", "dark", "#150b24", "#201036", "#190c2c", "#eee4ff", "#ab9bd0",
       "#38205a", "#ff71ce", "#01cdfe", "#05ffa1", "#38002e"),
    _P("ember", "dark", "#161114", "#221a1e", "#1c1518", "#f9eaed", "#c2a3a9",
       "#402c32", "#ff5566", "#ffb86b", "#7dd6c0", "#3a000b"),
    _P("void-blue", "dark", "#05070d", "#0d1119", "#090d15", "#e4e9f4", "#8b95ab",
       "#1b2130", "#3f7bff", "#37c9a7", "#f4b63f", "#ffffff"),
    _P("hunter", "dark", "#101a13", "#18251b", "#131e16", "#e7f0e9", "#9ab3a1",
       "#24382a", "#6fce8e", "#d2b25c", "#7ab2d1", "#052613"),
    # --- светлые --------------------------------------------------------------
    _P("paper", "light", "#faf7f2", "#ffffff", "#f3efe7", "#26221c", "#6f675c",
       "#e4dcd0", "#c2410c", "#167a55", "#3853c9", "#ffffff"),
    _P("ink-blue", "light", "#f6f8fc", "#ffffff", "#eef2f9", "#1c2438", "#5d6a85",
       "#dde4ef", "#2d4fd7", "#0d9494", "#d94f70", "#ffffff"),
    _P("sky", "light", "#f0f7fd", "#ffffff", "#e3f0fa", "#17324b", "#5a7891",
       "#d3e5f2", "#0f7dc0", "#12a37f", "#dd9a2e", "#ffffff"),
    _P("mint", "light", "#f2fbf5", "#ffffff", "#e6f6ec", "#1a2e24", "#5f7d6e",
       "#d5ece0", "#109a53", "#2a6fc9", "#d97742", "#ffffff"),
    _P("coral", "light", "#fff8f5", "#ffffff", "#ffefe8", "#33221d", "#8a6b60",
       "#f3ded4", "#ff6b4a", "#2a9d8f", "#e9c46a", "#ffffff"),
    _P("sand", "light", "#faf5ea", "#ffffff", "#f4ecdd", "#2e2820", "#776c58",
       "#e8dcc7", "#b4552d", "#5b7a4f", "#2f6396", "#ffffff"),
    _P("mono-light", "light", "#ffffff", "#f5f5f5", "#efefef", "#111111", "#666666",
       "#dcdcdc", "#111111", "#444444", "#0a7d44", "#ffffff"),
    _P("rose", "light", "#fdf5f7", "#ffffff", "#fbeaef", "#2f1d26", "#7c5f6d",
       "#f0dae1", "#d6336c", "#6f48b5", "#1b7a8b", "#ffffff"),
    _P("indigo", "light", "#f5f6ff", "#ffffff", "#eceefa", "#22203e", "#62618a",
       "#dfe0f2", "#4f46e5", "#0b9f78", "#d96b48", "#ffffff"),
    _P("forest", "light", "#f4f8f2", "#ffffff", "#e9f1e5", "#1e2b1c", "#64755f",
       "#d9e5d3", "#2e7d3a", "#9a671f", "#33688e", "#ffffff"),
    _P("butter", "light", "#fdf9ec", "#ffffff", "#faf3dd", "#332a17", "#7a6c4f",
       "#efe4c3", "#d9a203", "#42694f", "#a13f2e", "#332a00"),
    _P("crimson", "light", "#fcf6f6", "#ffffff", "#f9eded", "#331f21", "#7e6064",
       "#f0dcdc", "#c12638", "#8a5905", "#145a5a", "#ffffff"),
    _P("arctic", "light", "#f4fafa", "#ffffff", "#e9f5f6", "#16302e", "#5b7a79",
       "#d7ebeb", "#0e8288", "#af4a4a", "#3568b4", "#ffffff"),
    _P("brick", "light", "#faf7f5", "#ffffff", "#f4edea", "#2f2522", "#74635e",
       "#eaddd8", "#b33f2f", "#40608b", "#6c7e3b", "#ffffff"),
    _P("lavender", "light", "#f8f6fc", "#ffffff", "#f0ecf9", "#292243", "#6d648e",
       "#e4def4", "#7c5bd6", "#2b8a6d", "#c2576c", "#ffffff"),
    _P("ocean", "light", "#f4f7fa", "#ffffff", "#e9eff5", "#14202e", "#5a6b7e",
       "#dbe4ee", "#155e9b", "#b0622b", "#22795e", "#ffffff"),
    _P("grape", "light", "#fbf5fb", "#ffffff", "#f7ebf7", "#33203a", "#7c6483",
       "#eedaee", "#9333a5", "#3a7ca5", "#b16329", "#ffffff"),
    _P("walnut", "light", "#f7f3ed", "#fffefb", "#efe8dd", "#2b2118", "#6e5f50",
       "#e0d5c4", "#7a4a21", "#446079", "#856c2f", "#ffffff"),
]


def proc_palette(rng):
    """Процедурная палитра: базовый тон + гармония акцентов, проверка контраста."""
    mode = rng.weighted([("dark", 1), ("light", 1)])
    h = rng.randrange(360)
    if mode == "dark":
        bg = hsl_to_hex(h, rng.randint(22, 45) / 100, rng.randint(5, 11) / 100)
        surface = lighten(bg, 0.06)
        surface_alt = lighten(bg, 0.03)
        text = hsl_to_hex(h, rng.randint(8, 25) / 100, rng.randint(88, 95) / 100)
        muted = hsl_to_hex(h, rng.randint(10, 25) / 100, rng.randint(60, 75) / 100)
        border = lighten(bg, 0.16)
        al = rng.randint(50, 66) / 100
    else:
        bg = hsl_to_hex(h, rng.randint(15, 45) / 100, rng.randint(95, 98) / 100)
        surface = "#ffffff"
        surface_alt = darken(bg, 0.03)
        text = hsl_to_hex(h, rng.randint(20, 45) / 100, rng.randint(10, 20) / 100)
        muted = hsl_to_hex(h, rng.randint(12, 30) / 100, rng.randint(42, 55) / 100)
        border = darken(bg, 0.10)
        al = rng.randint(36, 52) / 100
    asat = rng.randint(58, 88) / 100
    accent = hsl_to_hex(h, asat, al)
    off2 = rng.choice([35, 45, 55, 150, 180, 200, 210])
    off3 = rng.choice([30, 40, 60, 120, 160, 300])
    accent2 = hsl_to_hex(h + off2, asat, al)
    accent3 = hsl_to_hex(h - off3, rng.randint(45, 80) / 100, al)
    on_accent = best_on(accent)
    p = {
        "name": "%s-h%d" % (mode, h), "mode": mode, "bg": bg, "surface": surface,
        "surface_alt": surface_alt, "text": text, "muted": muted, "border": border,
        "accent": accent, "accent2": accent2, "accent3": accent3,
        "on_accent": on_accent,
    }
    p["text"] = ensure_contrast(p["text"], bg, 7.0)
    p["muted"] = ensure_contrast(p["muted"], bg, 4.5)
    p["on_accent"] = ensure_contrast(on_accent, accent, 4.5)
    p.update(_STATUS_DARK if mode == "dark" else _STATUS_LIGHT)
    return p


def pick_palette(rng):
    p = rng.weighted([(None, 65), ("proc", 35)])
    if p == "proc":
        return proc_palette(rng)
    return dict(rng.choice(PALETTES))


def tint(pal, color, t=0.86):
    """Мягкая «плашка» цвета на фоне палитры (бейджи, подсветка)."""
    return mix(color, pal["bg"], t)


# ----------------------------------------------------------------------------
# 4. Типографика и «дизайн-токены»
# ----------------------------------------------------------------------------

F_SYS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
F_GEO = "Georgia, 'Times New Roman', serif"
F_MONO = "ui-monospace, SFMono-Regular, 'Cascadia Mono', Menlo, Consolas, 'Liberation Mono', monospace"
F_VERD = "Verdana, Geneva, 'DejaVu Sans', sans-serif"
F_TREB = "'Trebuchet MS', 'Segoe UI', Tahoma, sans-serif"
F_PALA = "'Palatino Linotype', Palatino, Georgia, serif"
F_COUR = "'Courier New', 'Liberation Mono', monospace"
F_TAH0 = "Tahoma, Verdana, 'Segoe UI', sans-serif"

TYPE_PAIRS = [
    {"name": "system-sans",  "head": F_SYS,  "body": F_SYS,  "mono": F_MONO, "hw": [600, 700, 800]},
    {"name": "georgia-head", "head": F_GEO,  "body": F_SYS,  "mono": F_MONO, "hw": [600, 700]},
    {"name": "mono-tech",    "head": F_MONO, "body": F_SYS,  "mono": F_MONO, "hw": [500, 600, 700]},
    {"name": "editorial",    "head": F_GEO,  "body": F_GEO,  "mono": F_MONO, "hw": [400, 600, 700]},
    {"name": "trebuchet",    "head": F_TREB, "body": F_SYS,  "mono": F_MONO, "hw": [600, 700]},
    {"name": "palatino",     "head": F_PALA, "body": F_SYS,  "mono": F_MONO, "hw": [400, 600]},
    {"name": "courier-dev",  "head": F_MONO, "body": F_SYS,  "mono": F_COUR, "hw": [500, 700]},
    {"name": "verdana",      "head": F_VERD, "body": F_VERD, "mono": F_MONO, "hw": [600, 700]},
    {"name": "helvetica",    "head": F_SYS,  "body": F_SYS,  "mono": F_MONO, "hw": [500, 600]},
    {"name": "tahoma",       "head": F_TAH0, "body": F_TAH0, "mono": F_MONO, "hw": [600, 700]},
]

SHADOWS = [
    ("none", "none"),
    ("soft", "0 1px 3px rgba(10,14,25,.10), 0 4px 14px rgba(10,14,25,.08)"),
    ("medium", "0 2px 6px rgba(10,14,25,.10), 0 10px 28px rgba(10,14,25,.12)"),
    ("layered", "0 1px 2px rgba(10,14,25,.08), 0 6px 16px rgba(10,14,25,.10), 0 16px 40px rgba(10,14,25,.08)"),
    ("hard", "4px 4px 0 rgba(10,14,25,.85)"),
]

HERO_PATTERNS = ["none", "grid", "dots", "glow", "rings"]


class Design(object):
    """Набор дизайн-решений сайта, полностью выводимый из RNG."""

    def __init__(self, rng):
        self.pal = pick_palette(rng)
        p = self.pal
        self.type_pair = rng.choice(TYPE_PAIRS)
        self.head_weight = rng.choice(self.type_pair["hw"])
        self.body_size = rng.choice([15, 16, 17])
        self.radius = rng.choice([0, 2, 4, 6, 8, 10, 12, 16, 20])
        self.shadow = rng.choice(SHADOWS)
        self.btn = rng.choice(["solid", "gradient", "outline", "pill"])
        self.container = rng.choice([1000, 1080, 1120, 1200, 1280])
        self.hero_pattern = rng.weighted([(x, 1) for x in HERO_PATTERNS])
        self.nav_sticky = rng.maybe(0.6)
        self.eyebrow_caps = rng.maybe(0.7)
        self.section_pad = rng.choice([56, 64, 72, 80, 96])
        self.head_tracking = rng.choice(["0em", "-0.01em", "-0.02em", "0.01em"])
        self.link_underline = rng.maybe(0.5)
        # производные цвета
        self.accent_soft = tint(p, p["accent"], 0.86)
        self.accent2_soft = tint(p, p["accent2"], 0.86)
        self.hero_grad_a = mix(p["accent"], p["bg"], 0.35)
        self.hero_grad_b = mix(p["accent2"], p["bg"], 0.35)

    @property
    def is_dark(self):
        return self.pal["mode"] == "dark"


# ----------------------------------------------------------------------------
# 5. Нейминг: бренды, домены, люди, города, общие данные
# ----------------------------------------------------------------------------

GEN_PREFIX = [
    "Swift", "Rapid", "Nova", "Hyper", "Ultra", "Prime", "Smart", "Easy",
    "Quick", "True", "Open", "Deep", "Bright", "Clear", "Safe", "Iron",
    "Jet", "Zen", "Neo", "Flux", "Peak", "Pure", "Bold", "Vast", "Aero",
    "Astro", "Volt", "Echo", "Apex", "Core", "Frost", "Storm", "Pulse",
    "Atlas", "Orbit", "Haven", "Spark", "Lumen", "Quanta", "Helio",
]
GEN_SUFFIX = [
    "Vault", "Box", "Hub", "Store", "Bay", "Dock", "Base", "Stack", "Cloud",
    "Send", "Drop", "Beam", "Link", "Locker", "Drive", "Stash", "Cache",
    "Bucket", "Depot", "Forge", "Nest", "Port", "Wire", "Cast", "Stream",
    "Frame", "Clip", "Pix", "Shot", "Snap", "Scan", "Paste", "Sync", "Keep",
    "Host", "Space", "Zone", "Works", "Lab", "Deck", "Grid", "Node", "Edge",
    "File", "Files", "Share", "Data", "Byte",
]
COIN_START = [
    "Vol", "Zen", "Nyx", "Kla", "Dro", "Fab", "Glim", "Hal", "Ivo", "Juno",
    "Kel", "Lum", "Mir", "Nor", "Ovi", "Ply", "Quil", "Riv", "Sol", "Tov",
    "Vel", "Wyn", "Xan", "Yel", "Zor", "Ana", "Bri", "Del", "Elo", "Fro",
    "Gio", "Iri", "Jax", "Kri", "Lio", "Mov", "Nia", "Ozo", "Rune", "Tira",
    "Ulo", "Vio", "Xe", "Yara", "Zeb", "Cab", "Dua", "Era", "Fyn", "Gora",
]
COIN_END = [
    "io", "ia", "eo", "ora", "ara", "ix", "ox", "ax", "um", "on", "is",
    "us", "ys", "el", "il", "ol", "al", "en", "in", "yn", "eva", "ana",
    "ify", "ero", "aro", "iva", "ada", "eda", "ona", "una", "ith", "eth",
    "ost", "ust", "ant", "ent", "ion", "eon", "ova", "avo", "evo", "imo",
    "alo", "olo", "ara",
]
TLDS = [
    (".com", 26), (".io", 18), (".net", 10), (".app", 7), (".cloud", 6),
    (".dev", 6), (".sh", 4), (".cc", 4), (".co", 5), (".me", 4),
    (".org", 3), (".xyz", 3), (".site", 2), (".tools", 2),
]

FIRST_NAMES = [
    "Ava", "Liam", "Noah", "Emma", "Olivia", "Mia", "Lucas", "Ethan",
    "Sofia", "Aiden", "Chloe", "Leo", "Zara", "Owen", "Ivy", "Felix",
    "Nora", "Ezra", "Maya", "Hugo", "Elena", "Marcus", "Priya", "Kenji",
    "Yuki", "Amara", "Lena", "Tomas", "Ines", "Ravi", "Sana", "Victor",
    "Wendy", "Omar", "Alice", "Bruno", "Carla", "Erik", "Frida", "Gia",
    "Hana", "Iris", "Jonas", "Kira", "Lars", "Mona", "Nils", "Olga",
]
LAST_NAMES = [
    "Novak", "Weber", "Moreau", "Ricci", "Sokolov", "Larsen", "Okafor",
    "Kim", "Tanaka", "Silva", "Costa", "Fischer", "Petrov", "Nguyen",
    "Patel", "Rossi", "Vargas", "Meyer", "Dubois", "Kowalski", "Hansen",
    "Ivanov", "Santos", "Berg", "Kaur", "Cortes", "Fontaine", "Marsh",
    "Reyes", "Sato", "Vogel", "Wagner", "Zhang", "Ali", "Bauer", "Dias",
]
ROLES = [
    "product designer", "backend engineer", "devops lead", "indie developer",
    "photographer", "video editor", "student", "researcher",
    "content creator", "startup founder", "sysadmin", "copywriter",
    "data analyst", "teacher", "streamer", "marketer", "QA engineer",
    "freelance journalist",
]
CITIES = [
    "Amsterdam, Netherlands", "Berlin, Germany", "Vilnius, Lithuania",
    "Riga, Latvia", "Warsaw, Poland", "Prague, Czech Republic",
    "Tallinn, Estonia", "London, UK", "Lisbon, Portugal", "Valletta, Malta",
    "Nicosia, Cyprus", "Singapore", "Toronto, Canada", "Austin, TX, USA",
    "Zurich, Switzerland", "Vienna, Austria", "Helsinki, Finland",
    "Stockholm, Sweden", "Dublin, Ireland", "Madrid, Spain",
]
LEGAL_FORMS = ["Ltd.", "UAB", "S.à r.l.", "GmbH", "OÜ", "Inc.", "Pte. Ltd.", "BV"]
SUPPORT_HOURS = [
    "Mon–Fri, 9:00–18:00 UTC",
    "24/7 for Pro customers",
    "Mon–Fri, 8:00–20:00 CET",
    "We reply within one business day",
    "24/7 email support",
]


def make_brand(rng, pack=None):
    """Бренд вида SwiftVault / Zolvio / Dropify; слова категорий приоритетнее."""
    prefixes = list(GEN_PREFIX)
    suffixes = list(GEN_SUFFIX)
    if pack and "name_words" in pack:
        prefixes = pack["name_words"][0] + prefixes
        suffixes = pack["name_words"][1] + suffixes
    style = rng.weighted([("compound", 46), ("coined", 34), ("suffixed", 20)])
    if style == "compound":
        brand = rng.choice(prefixes) + rng.choice(suffixes)
    elif style == "suffixed":
        stem = rng.choice(prefixes + suffixes).lower()
        suf = rng.choice(["ify", "ly", "hub", "io", "up", "box", "gen"])
        brand = stem.capitalize() + suf
    else:
        for _ in range(24):
            brand = rng.choice(COIN_START) + rng.choice(COIN_END)
            if 4 <= len(brand) <= 9 and brand[1:2].lower() != brand[1:2].upper() or True:
                break
        brand = brand[0].upper() + brand[1:]
    # избегаем дублей вроде "FileFiles"
    for w in (GEN_SUFFIX + suffixes):
        if brand == w + w:
            brand = brand[:-len(w)] + "Hub"
    tld = rng.weighted(TLDS)
    return brand, tld


def make_person(rng):
    first = rng.choice(FIRST_NAMES)
    last = rng.choice(LAST_NAMES)
    return {
        "first": first,
        "last": last,
        "full": first + " " + last,
        "handle": (first + rng.choice(["", ".", "_"]) + last).lower().replace("'", ""),
        "initials": (first[0] + last[0]).upper(),
        "role": rng.choice(ROLES),
    }


def human_size(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            if unit in ("B",):
                return "%d %s" % (n, unit)
            return "%.1f %s" % (n, unit)
        n /= 1024.0


def human_count(n):
    if n >= 1000000:
        return "%.1fM" % (n / 1000000.0)
    if n >= 1000:
        return "%.1fK" % (n / 1000.0)
    return str(n)


def esc(s):
    return _html.escape(str(s), quote=True)


# ----------------------------------------------------------------------------
# 6. SVG-движок: логотипы, favicon, иконки, «фото», аватары, графики, мокапы
# ----------------------------------------------------------------------------

_ICON_PATHS = {
    "upload": "M12 16V4m0 0l-4 4m4-4l4 4M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3",
    "download": "M12 4v12m0 0l-4-4m4 4l4-4M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3",
    "cloud": "M7 18a4 4 0 010-8 5.5 5.5 0 0110.7-1.5A4.5 4.5 0 0117 18H7z",
    "link": "M10 14a5 5 0 007.07 0l2.12-2.12a5 5 0 00-7.07-7.07L10.6 6.23M14 10a5 5 0 00-7.07 0L4.8 12.12a5 5 0 007.07 7.07L13.4 17.7",
    "shield": "M12 3l7 3v5c0 4.6-3 8.4-7 10-4-1.6-7-5.4-7-10V6l7-3z",
    "lock": "M6 11h12v9H6v-9zM9 11V8a3 3 0 016 0v3",
    "zap": "M13 2L4 14h6l-1 8 9-12h-6l1-8z",
    "users": "M16 19c0-2.2-1.8-4-4-4s-4 1.8-4 4M12 11a3 3 0 100-6 3 3 0 000 6zM20 19c0-1.8-1-3.2-2.5-3.8M17 11a2.5 2.5 0 000-5",
    "globe": "M12 21a9 9 0 100-18 9 9 0 000 18zM3 12h18M12 3c2.5 2.4 3.8 5.5 3.8 9S14.5 18.6 12 21c-2.5-2.4-3.8-5.5-3.8-9S9.5 5.4 12 3z",
    "play": "M8 5l12 7-12 7V5z",
    "image": "M4 5h16v14H4V5zm0 10l4.5-4.5 3.5 3.5 3-3L20 16M9 9.5a1 1 0 100-2 1 1 0 000 2z",
    "video": "M3 6h13v12H3V6zm13 4l5-3v10l-5-3",
    "code": "M8 7l-5 5 5 5M16 7l5 5-5 5M13 4l-2 16",
    "check": "M4 12l5 5L20 6",
    "x": "M6 6l12 12M18 6L6 18",
    "chevron-r": "M9 5l7 7-7 7",
    "chevron-d": "M5 9l7 7 7-7",
    "copy": "M8 8h11v11H8V8zM5 16V5h11",
    "clock": "M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v5l3.5 2",
    "star": "M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6L12 16.8 6.6 19.6l1.1-6L3.2 9.4l6.1-.8L12 3z",
    "heart": "M12 20s-7-4.6-9.3-9A5.4 5.4 0 0112 6.2 5.4 5.4 0 0121.3 11c-2.3 4.4-9.3 9-9.3 9z",
    "mail": "M3 6h18v12H3V6zm0 0l9 7 9-7",
    "folder": "M3 6h6l2 2h10v11H3V6z",
    "file": "M6 3h9l4 4v14H6V3zm9 0v4h4",
    "trash": "M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6",
    "settings": "M12 15a3 3 0 100-6 3 3 0 000 6zM19.4 15a1.6 1.6 0 00.3 1.7l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.6 1.6 0 00-1.7-.3 1.6 1.6 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.6 1.6 0 00-1-1.5 1.6 1.6 0 00-1.7.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.6 1.6 0 00.3-1.7 1.6 1.6 0 00-1.5-1H3a2 2 0 110-4h.1a1.6 1.6 0 001.5-1 1.6 1.6 0 00-.3-1.7l-.1-.1a2 2 0 112.8-2.8l.1.1a1.6 1.6 0 001.7.3h.1a1.6 1.6 0 001-1.5V3a2 2 0 114 0v.1a1.6 1.6 0 001 1.5h.1a1.6 1.6 0 001.7-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.6 1.6 0 00-.3 1.7v.1a1.6 1.6 0 001.5 1H21a2 2 0 110 4h-.1a1.6 1.6 0 00-1.5 1z",
    "search": "M11 18a7 7 0 100-14 7 7 0 000 14zM20 20l-4-4",
    "plus": "M12 5v14M5 12h14",
    "minus": "M5 12h14",
    "film": "M3 5h18v14H3V5zM7 5v14M17 5v14M3 9h4M3 15h4M17 9h4M17 15h4",
    "scissors": "M6 6l12 12M6 18L18 6M8 6a2 2 0 100-4 2 2 0 000 4zM8 22a2 2 0 100-4 2 2 0 000 4z",
    "music": "M9 18V6l10-2v12M9 18a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0zM19 16a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0z",
    "key": "M15 9a3 3 0 100-6 3 3 0 000 6zm-2.4 1.6L4 19l1 2 2-1 1-2h2l1-2 1.6-1.6",
    "server": "M4 4h16v6H4V4zm0 10h16v6H4v-6zM8 7h.01M8 17h.01",
    "eye": "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7zm10 3a3 3 0 100-6 3 3 0 000 6z",
    "message": "M4 4h16v12H8l-4 4V4z",
    "tag": "M3 12l9-9 9 9-9 9-9-9zM8.5 8.5h.01",
    "gift": "M4 10h16v11H4V10zm-1-5h18v5H3V5zm9 0v16M12 5s-1-4-4-3.5S8.8 5 12 5zm0 0s1-4 4-3.5S15.2 5 12 5z",
    "cpu": "M8 8h8v8H8V8zM4 9V7h2M4 15v-2M20 9V7h-2M20 15v-2M9 4V2M15 4V2M9 22v-2M15 22v-2M7 4h10v16H7V4z",
    "wifi": "M5 12.5a10 10 0 0114 0M8 15.5a6 6 0 018 0M12 19h.01",
    "layers": "M12 3l9 5-9 5-9-5 9-5zm9 9l-9 5-9-5m18 4l-9 5-9-5",
    "repeat": "M4 8h13l-3-3M20 16H7l3 3",
    "external": "M14 4h6v6M20 4l-9 9M18 13v6H5V6h6",
}


def icon(name, size=20, stroke=1.8):
    d = _ICON_PATHS.get(name, _ICON_PATHS["check"])
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 24 24" '
            'fill="none" stroke="currentColor" stroke-width="%s" stroke-linecap="round" '
            'stroke-linejoin="round" aria-hidden="true">%s</svg>') % (size, size, stroke, d)


def _svg_defs_gradient(gid, c1, c2, vertical=False):
    x2, y2 = ("0" , "1") if vertical else ("1", "0")
    return ('<linearGradient id="%s" x1="0" y1="0" x2="%s" y2="%s">'
            '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/>'
            '</linearGradient>') % (gid, x2, y2, c1, c2)


def svg_logo(rng, design, brand):
    """Знак логотипа 48x48 + (опц.) монограмма. Возвращает SVG-строку."""
    p = design.pal
    c1, c2 = p["accent"], p["accent2"] if rng.maybe(0.7) else p["accent3"]
    grad = _svg_defs_gradient("lg", c1, c2)
    kind = rng.choice([
        "monogram", "bolt", "layers", "hex", "circles", "plane", "upbox",
        "play", "aperture", "cube", "cloud", "chain", "prism", "dots",
    ])
    monogram = brand[:2].upper()
    body = ""
    if kind == "monogram":
        body = ('<rect x="2" y="2" width="44" height="44" rx="%d" fill="url(#lg)"/>'
                '<text x="24" y="31" font-family="Arial, sans-serif" font-size="19" '
                'font-weight="700" fill="%s" text-anchor="middle">%s</text>'
                % (rng.choice([8, 10, 12, 22]), p["on_accent"], monogram))
    elif kind == "bolt":
        body = ('<rect x="2" y="2" width="44" height="44" rx="%d" fill="url(#lg)"/>'
                '<path d="M27 8L15 26h8l-2 14 12-18h-8l2-14z" fill="%s"/>'
                % (rng.choice([10, 12, 22]), p["on_accent"]))
    elif kind == "layers":
        body = ('<g fill="none" stroke="url(#lg)" stroke-width="4" stroke-linejoin="round">'
                '<path d="M24 6l17 9-17 9-17-9 17-9z"/>'
                '<path d="M10 26l14 8 14-8" opacity=".66"/></g>')
    elif kind == "hex":
        body = ('<path d="M24 3l18 10.5v21L24 45 6 34.5v-21L24 3z" fill="url(#lg)"/>'
                '<text x="24" y="30" font-family="Arial, sans-serif" font-size="17" '
                'font-weight="700" fill="%s" text-anchor="middle">%s</text>'
                % (p["on_accent"], brand[0].upper()))
    elif kind == "circles":
        body = ('<circle cx="17" cy="24" r="13" fill="%s" opacity=".9"/>'
                '<circle cx="31" cy="24" r="13" fill="%s" opacity=".75"/>'
                % (c1, c2))
    elif kind == "plane":
        body = ('<path d="M4 26L44 8 28 44l-6-16-18-2z" fill="url(#lg)"/>')
    elif kind == "upbox":
        body = ('<rect x="4" y="4" width="40" height="40" rx="%d" fill="none" '
                'stroke="url(#lg)" stroke-width="4"/>'
                '<path d="M24 33V17m0 0l-7 7m7-7l7 7" stroke="%s" stroke-width="4" '
                'stroke-linecap="round" stroke-linejoin="round" fill="none"/>'
                % (rng.choice([6, 10]), c1))
    elif kind == "play":
        body = ('<rect x="2" y="2" width="44" height="44" rx="%d" fill="url(#lg)"/>'
                '<path d="M20 16l13 8-13 8V16z" fill="%s"/>'
                % (rng.choice([10, 12, 22]), p["on_accent"]))
    elif kind == "aperture":
        body = ('<g fill="none" stroke="url(#lg)" stroke-width="3.6">'
                '<circle cx="24" cy="24" r="19"/>'
                '<path d="M24 5l11 19M40 14l-19 11M43 24H20M38 38L24 19M24 43L13 24M8 38l19-11"/>'
                '</g>')
    elif kind == "cube":
        body = ('<g fill="none" stroke="url(#lg)" stroke-width="3.4" stroke-linejoin="round">'
                '<path d="M24 4l18 10v20L24 44 6 34V14L24 4z"/>'
                '<path d="M6 14l18 10 18-10M24 24v20" opacity=".6"/></g>')
    elif kind == "cloud":
        body = ('<path d="M14 36a9 9 0 01-1-17.9A13 13 0 0138 21a8.5 8.5 0 01-2 15.9H14z" '
                'fill="url(#lg)"/>')
    elif kind == "chain":
        body = ('<g fill="none" stroke="url(#lg)" stroke-width="4" stroke-linecap="round">'
                '<path d="M20 28l8-8M17 31l-3 3a7 7 0 01-10-10l6-6a7 7 0 0110 0"/>'
                '<path d="M31 17l3-3a7 7 0 0110 10l-6 6a7 7 0 01-10 0"/></g>')
    elif kind == "prism":
        body = ('<path d="M24 5l18 34H6L24 5z" fill="url(#lg)" opacity=".92"/>'
                '<path d="M24 5l-6 34" stroke="%s" stroke-width="2" opacity=".5"/>'
                '<path d="M24 5l8 34" stroke="%s" stroke-width="2" opacity=".5"/>'
                % (p["on_accent"], p["on_accent"]))
    else:  # dots
        r = rng.choice([4, 5])
        body = ('<rect x="2" y="2" width="44" height="44" rx="%d" fill="url(#lg)"/>'
                '<g fill="%s"><circle cx="15" cy="24" r="%d"/><circle cx="24" cy="24" r="%d"/>'
                '<circle cx="33" cy="24" r="%d"/></g>'
                % (rng.choice([10, 21]), p["on_accent"], r, r + 1, r))
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48" '
            'role="img" aria-label="%s logo">%s%s</svg>') % (esc(brand), grad, body)


def svg_favicon(design, brand, rng):
    p = design.pal
    grad = _svg_defs_gradient("fv", p["accent"], p["accent2"])
    letter = brand[0].upper()
    shape = rng.choice(["circle", "squircle", "square"])
    if shape == "circle":
        bg = '<circle cx="32" cy="32" r="30" fill="url(#fv)"/>'
    elif shape == "squircle":
        bg = '<rect x="4" y="4" width="56" height="56" rx="18" fill="url(#fv)"/>'
    else:
        bg = '<rect x="6" y="6" width="52" height="52" rx="6" fill="url(#fv)"/>'
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
            '%s%s<text x="32" y="43" font-family="Arial, sans-serif" font-size="32" '
            'font-weight="700" fill="%s" text-anchor="middle">%s</text></svg>'
            % (grad, bg, p["on_accent"], letter))


def svg_placeholder(rng, design, w, h, label=""):
    """Абстрактная «фотография»: градиент + размытые пятна. Выглядит как
    превью контента, не тянет трафик, ноль внешних запросов."""
    p = design.pal
    hue_shift = rng.randrange(-40, 41)
    h0, s0, _ = rgb_to_hsl(*hex_to_rgb(p["accent"]))
    cA = hsl_to_hex(h0 + hue_shift, rng.randint(45, 75) / 100, rng.randint(28, 46) / 100)
    cB = hsl_to_hex(h0 + hue_shift + rng.choice([-60, -35, 35, 60, 150]),
                    rng.randint(40, 75) / 100, rng.randint(24, 44) / 100)
    parts = [_svg_defs_gradient("pg", cA, cB, rng.maybe(0.5))]
    parts.append('<rect width="%d" height="%d" fill="url(#pg)"/>' % (w, h))
    n_blobs = rng.randint(3, 6)
    blobs, filters = [], []
    for i in range(n_blobs):
        cx, cy = rng.randrange(0, w + 1), rng.randrange(0, h + 1)
        r = int(max(w, h) * rng.randint(12, 34) / 100)
        col = hsl_to_hex(h0 + hue_shift + rng.randrange(-90, 91),
                         rng.randint(35, 85) / 100, rng.randint(30, 68) / 100)
        blobs.append('<circle cx="%d" cy="%d" r="%d" fill="%s" opacity="%.2f" '
                     'filter="url(#bl%d)"/>' % (cx, cy, r, col, rng.randint(25, 60) / 100, i))
        filters.append('<filter id="bl%d" x="-40%%" y="-40%%" width="180%%" height="180%%">'
                       '<feGaussianBlur stdDeviation="%d"/></filter>' % (i, r // 3 + 1))
    parts.append("<defs>%s</defs>" % "".join(filters))
    parts.extend(blobs)
    if rng.maybe(0.55) and label:
        fs = max(11, min(16, w // 40))
        parts.append('<text x="%d" y="%d" font-family="Arial, sans-serif" font-size="%d" '
                     'fill="rgba(255,255,255,.82)" text-anchor="middle">%s</text>'
                     % (w // 2, h // 2 + fs // 3, fs, esc(label)))
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
            'viewBox="0 0 %d %d">%s</svg>') % (w, h, w, h, "".join(parts))


def svg_avatar(rng, design, initials):
    """Аватар: мягкий градиентный фон + инициалы."""
    p = design.pal
    h0 = rng.randrange(360)
    c1 = hsl_to_hex(h0, rng.randint(45, 75) / 100, rng.randint(38, 55) / 100)
    c2 = hsl_to_hex(h0 + rng.choice([-50, -30, 30, 50]), rng.randint(45, 75) / 100,
                    rng.randint(30, 48) / 100)
    fg = "#ffffff" if rel_luminance(mix(c1, c2, 0.5)) < 0.5 else "#1a1a1a"
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 72 72">'
            '%s<rect width="72" height="72" rx="36" fill="url(#av)"/>'
            '<text x="36" y="45" font-family="Arial, sans-serif" font-size="26" font-weight="600" '
            'fill="%s" text-anchor="middle">%s</text></svg>'
            % (_svg_defs_gradient("av", c1, c2), fg, esc(initials)))


def _walk(rng, n, lo=15, hi=85):
    pts, v = [], rng.randint(lo + 10, hi - 10)
    for _ in range(n):
        v = _clamp(v + rng.randint(-16, 18), lo, hi)
        pts.append(v)
    return pts


def svg_chart(rng, design, w, h, kind=None):
    """Диаграммы для лендингов/дашбордов: line/area, bars, donut."""
    p = design.pal
    if kind is None:
        kind = rng.choice(["area", "bars", "donut"])
    if kind == "donut":
        parts_total = rng.randint(3, 5)
        segs = [rng.randint(15, 45) for _ in range(parts_total)]
        total = sum(segs)
        colors = [p["accent"], p["accent2"], p["accent3"], lighten(p["accent"], 0.3),
                  lighten(p["accent2"], 0.25)]
        cx = cy = w // 2
        r = min(w, h) // 2 - 8
        sw = r * rng.randint(28, 42) // 100
        out, ang = [], -90.0
        for i, seg in enumerate(segs):
            sweep = 360.0 * seg / total
            a0, a1 = ang, ang + sweep - 2
            import math
            x0 = cx + r * math.cos(math.radians(a0))
            y0 = cy + r * math.sin(math.radians(a0))
            x1 = cx + r * math.cos(math.radians(a1))
            y1 = cy + r * math.sin(math.radians(a1))
            large = 1 if sweep > 180 else 0
            out.append('<path d="M%.1f %.1f A%d %d 0 %d 1 %.1f %.1f" fill="none" '
                       'stroke="%s" stroke-width="%d" stroke-linecap="butt"/>'
                       % (x0, y0, r, r, large, x1, y1, colors[i % len(colors)], sw))
            ang += sweep
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
                'viewBox="0 0 %d %d">%s</svg>' % (w, h, w, h, "".join(out)))
    if kind == "bars":
        n = rng.randint(7, 14)
        gap = w // (n * 4)
        bw = (w - gap * (n + 1)) // n
        vals = _walk(rng, n, 12, 92)
        out = []
        for i, v in enumerate(vals):
            bh = int(h * v / 100)
            x = gap + i * (bw + gap)
            col = p["accent"] if i != n - 1 else p["accent2"]
            r = min(4, bw // 4)
            out.append('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s"/>'
                       % (x, h - bh, bw, bh, r, col))
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
                'viewBox="0 0 %d %d">%s</svg>' % (w, h, w, h, "".join(out)))
    # area / line
    n = rng.randint(14, 26)
    vals = _walk(rng, n, 10, 90)
    step = float(w - 8) / (n - 1)
    pts = [(4 + i * step, h - 6 - (h - 16) * v / 100.0) for i, v in enumerate(vals)]
    line = " ".join("%.1f,%.1f" % pt for pt in pts)
    area = "4,%d %s %d,%d" % (h - 6, line, w - 4, h - 6)
    gid = "cg%d" % rng.randrange(9999)
    out = [
        _svg_defs_gradient(gid, p["accent"], p["bg"]),
        '<path d="M%s" fill="url(#%s)" opacity=".35"/>' % (area, gid),
        '<polyline points="%s" fill="none" stroke="%s" stroke-width="2.5" '
        'stroke-linejoin="round" stroke-linecap="round"/>' % (line, p["accent"]),
        '<circle cx="%.1f" cy="%.1f" r="4" fill="%s"/>' % (pts[-1][0], pts[-1][1], p["accent2"]),
    ]
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
            'viewBox="0 0 %d %d">%s</svg>' % (w, h, w, h, "".join(out)))


def svg_app_window(rng, design, brand, kind="generic"):
    """Мок-скриншот приложения для hero: окно с сайдбаром/панелями."""
    p = design.pal
    w, h = 920, 580
    tb = 34
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
        'role="img" aria-label="%s interface screenshot">' % (w, h, w, h, esc(brand)),
        '<rect width="%d" height="%d" rx="%d" fill="%s"/>' % (w, h, min(design.radius, 14), p["surface"]),
        '<rect width="%d" height="%d" rx="%d" fill="%s"/>' % (w, tb, min(design.radius, 14), p["surface_alt"]),
        '<rect y="%d" width="%d" height="%d" fill="%s"/>' % (tb, w, 1, p["border"]),
    ]
    for i, col in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
        out.append('<circle cx="%d" cy="%d" r="5.5" fill="%s"/>' % (18 + i * 18, tb // 2, col))
    out.append('<rect x="%d" y="9" width="220" height="16" rx="4" fill="%s"/>'
               % (w // 2 - 110, p["border"]))
    # sidebar
    sw = rng.choice([150, 170, 190])
    out.append('<rect x="0" y="%d" width="%d" height="%d" fill="%s"/>'
               % (tb + 1, sw, h - tb - 1, p["surface_alt"]))
    out.append('<rect x="0" y="%d" width="%d" height="%d" fill="%s"/>'
               % (tb + 1, sw, h - tb - 1, "none"))
    for i in range(rng.randint(6, 10)):
        y = tb + 18 + i * 30
        if y > h - 24:
            break
        active = i == rng.randint(0, 3)
        out.append('<rect x="14" y="%d" width="%d" height="18" rx="4" fill="%s"/>'
                   % (y, sw - 28, p["accent"] if active else mix(p["surface"], p["muted"], 0.35)))
    # main area content by kind
    mx, mw = sw + 24, w - sw - 48
    if kind == "gallery":
        cols = 4
        akeys = ["accent", "accent2", "accent3"]
        cw = (mw - (cols - 1) * 14) // cols
        for r in range(3):
            for c in range(cols):
                x = mx + c * (cw + 14)
                y = tb + 20 + r * (cw * 0.72 + 14)
                if y + cw * 0.72 > h - 16:
                    break
                k = (r + c) % 3
                col = mix(p[akeys[k]], p["surface"], 0.55 + 0.15 * k)
                out.append('<rect x="%d" y="%d" width="%d" height="%.0f" rx="6" fill="%s"/>'
                           % (x, y, cw, cw * 0.72, col))
    elif kind == "editor":
        # таймлайн-треки
        out.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s"/>'
                   % (mx, tb + 20, mw, h - tb - 60, p["bg"]))
        for t in range(4):
            y = tb + 34 + t * 46
            xoff = rng.randint(10, 90)
            for b in range(rng.randint(2, 4)):
                bw2 = rng.randint(60, 170)
                out.append('<rect x="%d" y="%d" width="%d" height="30" rx="4" fill="%s" opacity="%.2f"/>'
                           % (mx + 12 + xoff, y, bw2,
                              [p["accent"], p["accent2"], p["accent3"]][t % 3],
                              0.75 - 0.12 * b))
                xoff += bw2 + rng.randint(8, 30)
        # playhead
        out.append('<rect x="%d" y="%d" width="2" height="%d" fill="%s"/>'
                   % (mx + mw // 2 + rng.randint(-80, 80), tb + 28, h - tb - 70, p["muted"]))
    elif kind == "table":
        rows = 9
        rh = (h - tb - 44) // rows
        for c, cwd in enumerate([mw * 0.34, mw * 0.22, mw * 0.2, mw * 0.24]):
            out.append('<rect x="%d" y="%d" width="%d" height="24" rx="3" fill="%s"/>'
                       % (mx + sum([mw * 0.34, mw * 0.22, mw * 0.2, mw * 0.24][:c]), tb + 18,
                          cwd - 12, mix(p["surface"], p["muted"], 0.25)))
        for r in range(rows):
            y = tb + 50 + r * rh
            if y > h - 20:
                break
            for c, cwd in enumerate([mw * 0.34, mw * 0.22, mw * 0.2, mw * 0.24]):
                x = mx + sum([mw * 0.34, mw * 0.22, mw * 0.2, mw * 0.24][:c])
                out.append('<rect x="%d" y="%d" width="%d" height="%d" rx="3" fill="%s"/>'
                           % (x, y + rh // 2 - 6, cwd - 12 - rng.randint(0, 30), 12,
                              mix(p["surface"], p["muted"], 0.18)))
    else:  # generic dashboard
        out.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s"/>'
                   % (mx, tb + 18, mw, 120, mix(p["accent"], p["surface"], 0.85)))
        for i in range(3):
            x = mx + i * (mw / 3 + 6) - i * 6
            out.append('<rect x="%d" y="%d" width="%.0f" height="76" rx="8" fill="%s"/>'
                       % (mx + i * (mw - 12) / 3, tb + 152, (mw - 24) / 3, p["surface_alt"]))
        gy = tb + 246
        out.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s"/>'
                   % (mx, gy, mw, h - gy - 20, p["surface_alt"]))
        nb = 12
        bw2 = (mw - 40 - 11 * 10) // nb
        for b in range(nb):
            bh = rng.randint(20, 130)
            out.append('<rect x="%d" y="%d" width="%d" height="%d" rx="3" fill="%s" opacity=".9"/>'
                       % (mx + 20 + b * (bw2 + 10), gy + (h - gy - 40) - bh + 10, bw2, bh,
                          p["accent"] if b % 3 else p["accent2"]))
    out.append('</svg>')
    return "".join(out)


# ----------------------------------------------------------------------------
# 7. Контент-паки 12 категорий
# ----------------------------------------------------------------------------

# Тональности: меняют CTA, надзаголовки и микрокопию — ещё одно измерение вариаций.
TONES = {
    "friendly": {
        "cta": ["Get started free", "Try it now", "Start in seconds", "Give it a try"],
        "cta2": ["See how it works", "Learn more", "View demo"],
        "eyebrow": ["Why {brand}?", "Built for you", "Simple by design"],
        "footer": ["Made with care by the {brand} team", "{brand} — built by a small distributed team"],
        "about_open": ["{brand} started as an internal tool that outgrew its original purpose."],
    },
    "pro": {
        "cta": ["Request access", "Create account", "Start free trial", "Get started"],
        "cta2": ["Read the docs", "Compare plans", "Book a demo"],
        "eyebrow": ["Infrastructure-grade {label}", "For teams that ship", "Enterprise-ready"],
        "footer": ["© {brand}. All systems operational.", "{brand} — reliable infrastructure for files"],
        "about_open": ["{brand} was founded in {year} to solve a problem we kept running into: sharing large files was harder than it needed to be."],
    },
    "playful": {
        "cta": ["Throw a file at us", "Let's go", "Upload something", "Jump in"],
        "cta2": ["Peek inside", "Show me features", "Take the tour"],
        "eyebrow": ["Files, but fun", "No signup circus", "Seriously simple"],
        "footer": ["{brand} — made by four people and one very tired coffee machine.", "Hi, we're {brand}. We move bits around."],
        "about_open": ["{brand} began in a dorm room with a broken FTP server and a stubborn belief that file transfer shouldn't require a manual."],
    },
    "technical": {
        "cta": ["Deploy in 60s", "Read the API docs", "Run it yourself", "Get API keys"],
        "cta2": ["View API reference", "See benchmarks", "Read the changelog"],
        "eyebrow": ["Built on boring, proven tech", "Latency-optimized", "S3-compatible core"],
        "footer": ["{brand} — status: all systems normal.", "{brand} runs on {region} infrastructure."],
        "about_open": ["{brand} is engineered around a simple constraint: moving data should be limited only by network physics, not by product decisions."],
    },
    "bold": {
        "cta": ["Claim your space", "Start now — it's free", "Switch today", "Take control"],
        "cta2": ["Why teams switch", "See the numbers", "Compare us"],
        "eyebrow": ["The fastest {label} on the internet", "Stop wrestling with attachments", "File sharing, reinvented"],
        "footer": ["{brand} — {label} without limits.", "{brand} is on a mission to make data movement effortless."],
        "about_open": ["Every team has a moment when the tools stop keeping up. For us, it was a 40 GB dataset that refused to be emailed, zipped, or apologized for. {brand} is our answer."],
    },
}

GENERIC_FAQ = [
    ("Do you offer an API?",
     "Yes. Every paid plan includes REST API access with tokens you can scope per project. The API covers uploads, listing, sharing and account management, and there are official client libraries for Python, JavaScript and Go."),
    ("Can I get a refund?",
     "If you're within the first 14 days of a paid subscription and haven't consumed more than 5% of your plan quota, write to support and we'll refund the full amount, no questions asked."),
    ("Where is my data stored?",
     "Primary storage lives in the region you pick at signup, with encrypted replicas in a second facility at least 200 km away. You can check the exact regions on the status page at any time."),
    ("How do you handle copyright complaints?",
     "We respond to valid DMCA-style notices within 48 hours. Public links are disabled first, then reviewed; repeat infringers lose their accounts. Counter-notices are processed on the same terms."),
    ("Is there a student or non-profit discount?",
     "Yes — 50% off any annual plan with a valid student email or non-profit registration document. Contact support with proof and we'll apply it to your account."),
    ("What happens to my files if I cancel?",
     "Nothing is deleted immediately. Your account switches to read-only for 30 days so you can download everything, after which data is permanently and irrecoverably removed from all storage nodes."),
]

STAT_KINDS = {
    "files": ("files transferred", lambda r: "%s billion" % r.choice(["1.4", "2.1", "3.8", "5.2", "8.9", "11.6"])),
    "users": ("registered users", lambda r: human_count(r.randint(180000, 4200000))),
    "pb": ("data served monthly", lambda r: "%d PB" % r.randint(4, 96)),
    "uptime": ("uptime last 12 months", lambda r: "99.9%d%%" % r.randint(2, 9)),
    "countries": ("countries served", lambda r: str(r.randint(64, 190))),
    "min": ("minutes saved per upload", lambda r: str(r.randint(4, 37))),
    "links": ("links created", lambda r: "%s million" % r.choice(["9", "17", "31", "58", "120", "240"])),
    "formats": ("formats supported", lambda r: str(r.randint(148, 412))),
    "speed": ("avg. download speed", lambda r: "%d MB/s" % r.randint(18, 92)),
    "retention": ("days of version history", lambda r: str(r.choice([14, 30, 60, 90, 180]))),
}

def _feat(icon_name, title, desc):
    return {"icon": icon_name, "title": title, "desc": desc}


PACKS = {}

PACKS["fileshare"] = {
    "id": "fileshare",
    "label": "file sharing",
    "noun": "files",
    "name_words": (["Send", "Transfer", "Share", "Beam", "Swift", "Drop"],
                   ["Vault", "Drop", "Send", "Share", "Bay", "Box", "Load", "Files"]),
    "taglines": [
        "Send files of any size, without the paperwork.",
        "Big files. Short links. Zero friction.",
        "The fastest way to move files between people.",
        "File transfer that respects your time.",
        "Share like it's 2030.",
    ],
    "hero_heads": [
        "Send {maxsize} files with one link",
        "Move big files without big problems",
        "File sharing, finally done right",
        "Stop emailing attachments. Start sharing links.",
        "{brand} moves files that email can't",
        "The two-second file transfer",
    ],
    "hero_subs": [
        "No account needed to download, no ads, no speed games. Upload, share the link, done — links expire when you say so.",
        "Upload in the browser, share with a short link, and track downloads in real time. Free plans start at {freesize} per transfer.",
        "Chunked, parallel transfers mean your files move at the full speed of your connection — even on flaky hotel Wi-Fi.",
        "Drag, drop, share. Recipients get a clean download page with resume support, and you get download stats.",
    ],
    "features": [
        _feat("upload", "Drag & drop anywhere", "Drop files anywhere on the page — the uploader handles folders, multiple selections and files up to {maxsize} without breaking a sweat."),
        _feat("link", "Short share links", "Every upload gets a compact, pronounceable link like {domain}/f/{slug} that survives chat apps, emails and QR codes."),
        _feat("shield", "Password protection", "Add a password to any transfer and the download page won't even reveal the file list without it."),
        _feat("clock", "Expiring links", "Set links to self-destruct after 1 hour, 1 day or 30 days. Expired transfers are wiped from all storage nodes, not just hidden."),
        _feat("zap", "Parallel chunked uploads", "Files are split into 8 MB chunks uploaded in parallel, so a dropped connection resumes instead of restarting."),
        _feat("download", "Resume everywhere", "Downloaders get HTTP range support and a stable checksum, so interrupted downloads pick up where they stopped."),
        _feat("mail", "Email delivery", "Send links straight to recipients with a short message; you'll get a notification the moment each person downloads."),
        _feat("users", "Team dropboxes", "Create a permanent upload page where clients can send files to you — no accounts on their side, everything lands in your inbox."),
        _feat("trash", "Auto-delete rules", "Burn after reading, delete after N downloads, or wipe on a schedule — per transfer, with a log of what happened."),
        _feat("globe", "Edge-cached downloads", "Recipients download from the nearest edge node, so a transfer sent from Vilnius lands at full speed in Singapore."),
        _feat("code", "Developer API", "A tidy REST API with presigned uploads, webhooks for download events and official clients for Python and JavaScript."),
        _feat("lock", "Private by default", "Transfers are unlisted, not public: links contain 40+ bits of entropy and are never guessable or listed anywhere."),
    ],
    "steps": [
        ("Drop your files", "Drag one file or a whole folder into the upload zone. Progress shows real speed, not a fake animation."),
        ("Set the rules", "Optional password, expiry date and download limit — configured in two clicks before you hit Share."),
        ("Share the link", "Copy the short URL or send it by email directly from the page. Track views and downloads live."),
    ],
    "faq": [
        ("What is the maximum file size?",
         "Anonymous uploads are capped at {freesize}; registered accounts can send up to {maxsize}, and paid plans remove the cap entirely — we've delivered single files over 400 GB."),
        ("Do recipients need an account?",
         "Never. Downloads are open to anyone with the link (and the password, if you set one). No sign-up walls, no 'create an account to continue' dark patterns."),
        ("How long do files stay online?",
         "As long as you choose: from 1 hour to permanent on paid plans. The default is 14 days, and you can extend or destroy a transfer at any moment from the dashboard."),
        ("Can I share a folder as one download?",
         "Yes — folders upload as a single transfer and download as a ZIP built on the fly, or as individual files if the recipient prefers."),
        ("What about viruses and malware?",
         "Every file is scanned with two independent engines before the download page goes live. Flagged transfers are quarantined and the uploader is notified with details."),
        ("Are downloads really unlimited?",
         "On paid plans, yes — no bandwidth caps and no 'fair use' asterisks. Free transfers are limited to 20 downloads per link, which covers almost every real-world case."),
    ],
    "stat_set": ["files", "users", "pb", "countries", "uptime"],
    "table": {
        "title": "Recent public transfers",
        "note": "A sample of transfers shared with the public listing option enabled.",
        "cols": [("File", "filename"), ("Size", "size"), ("Downloads", "count"), ("Uploaded", "ago"), ("By", "user")],
    },
    "formats": ["zip", "rar", "7z", "tar", "gz", "mp4", "mkv", "iso", "dmg", "exe", "psd", "ai"],
}

PACKS["imagehost"] = {
    "id": "imagehost",
    "label": "image hosting",
    "noun": "images",
    "name_words": (["Pix", "Snap", "Shot", "Img", "Lens", "Frame"],
                   ["Host", "Vault", "Bay", "Dock", "Stash", "Pix", "Shots", "Nest"]),
    "taglines": [
        "Upload an image, get a link. That's it.",
        "Fast, clean image hosting with direct links.",
        "Your images, on a fast CDN, with real analytics.",
        "Image hosting without the clutter.",
    ],
    "hero_heads": [
        "Host images that load instantly",
        "Direct image links, zero hassle",
        "The image host that stays out of your way",
        "Upload once, embed anywhere",
        "Screenshots and photos, perfectly hosted",
    ],
    "hero_subs": [
        "Drag an image in, copy the direct link, embed it anywhere. WebP and AVIF served automatically, GIFs up to {maxsize} supported.",
        "Every image gets a direct CDN link, Markdown and BBCode snippets, and a clean viewer page with view counts.",
        "No compression surprises, no watermarks, no 'sign in to view'. Just fast, hotlink-friendly image hosting.",
        "Albums, tags, and a searchable library — with embed codes ready for forums, READMEs and marketplaces.",
    ],
    "features": [
        _feat("upload", "Instant drag & drop", "Drop images or paste from the clipboard (Ctrl+V). JPEG, PNG, WebP, AVIF, GIF and SVG up to {maxsize} each."),
        _feat("link", "Direct links & snippets", "Every image gets a direct URL plus ready-made Markdown, BBCode, HTML and thumbnail snippets — one click to copy."),
        _feat("image", "Modern formats, automatically", "We serve WebP or AVIF to browsers that support them, cutting file size 30-60% with no visible quality loss."),
        _feat("eye", "View analytics", "See views, referrers and countries for each image — useful whether you run a marketplace listing or a viral meme."),
        _feat("scissors", "Inline cropper", "Crop, resize and rotate right after upload; the original file is kept alongside every edit you make."),
        _feat("folder", "Albums & tags", "Group images into albums with their own share link, cover image and optional titles and captions."),
        _feat("cloud", "Global CDN", "Images are cached at 42 edge locations; first view loads from origin, the rest load from the nearest node."),
        _feat("lock", "Private albums", "Unlisted by default. Make an album private with a password, or share it with a secret link that you can rotate."),
        _feat("download", "Bulk download", "Grab an entire album as a ZIP with original files, or export with your edits applied — your choice."),
        _feat("copy", "One-click copy", "Copy the direct link, thumbnail, or embed snippet the moment an upload finishes. No digging through menus."),
        _feat("users", "Team libraries", "Shared workspaces where a whole team can browse, tag and reuse images without emailing files around."),
        _feat("code", "Developer API", "Upload programmatically, manage albums and pull analytics over a clean REST API with generous rate limits."),
    ],
    "steps": [
        ("Drop or paste", "Drag images in or paste a screenshot straight from the clipboard — no upload page dance required."),
        ("Edit if you like", "Crop, resize or rotate in the browser. The original is preserved; edits are non-destructive."),
        ("Copy and embed", "Grab the direct link or a ready snippet for Markdown, BBCode or HTML, and paste it wherever you need."),
    ],
    "faq": [
        ("Is hotlinking allowed?",
         "Yes, on all plans, including free. We ask only that you don't resell raw hosting; images that generate sustained abusive traffic get rate-limited, never deleted."),
        ("Do you compress my images?",
         "Never without asking. We may serve a WebP/AVIF variant to supporting browsers, but the original file is always available at its direct link."),
        ("What's the maximum file size?",
         "{freesize} per image on the free plan, {maxsize} on paid. Animated GIFs count by file size, not frame count."),
        ("How long do images stay up?",
         "Indefinitely, as long as an image gets at least one view every 6 months. We email a warning 30 days before any cleanup sweep."),
        ("Can I delete an image everywhere?",
         "Deleting removes the image, its thumbnails, all sized variants and cached copies are purged from edges within 24 hours."),
        ("Do you support animated images?",
         "GIF, animated WebP and APNG upload and play natively. We generate a static poster frame for thumbnails automatically."),
    ],
    "stat_set": ["files", "users", "pb", "uptime", "speed"],
    "table": {
        "title": "Trending images",
        "note": "Most viewed public images in the last 24 hours.",
        "cols": [("Image", "filename"), ("Dimensions", "dims"), ("Size", "size"), ("Views", "count"), ("Uploader", "user")],
    },
    "formats": ["jpg", "png", "webp", "avif", "gif", "svg", "bmp", "tiff", "heic"],
}

PACKS["videoedit"] = {
    "id": "videoedit",
    "label": "video editing",
    "noun": "projects",
    "name_words": (["Clip", "Cut", "Frame", "Reel", "Scene", "Montage"],
                   ["Forge", "Lab", "Deck", "Works", "Studio", "Cut", "Reel"]),
    "taglines": [
        "Professional video editing, right in your browser.",
        "Cut, trim and export — no downloads, no license keys.",
        "The editor that runs where your footage already is.",
        "From raw footage to published cut in one tab.",
    ],
    "hero_heads": [
        "Edit video in the browser, export in minutes",
        "A full timeline editor, zero installs",
        "Video editing that keeps up with you",
        "Cut your first clip in under a minute",
        "The browser video studio your laptop can handle",
    ],
    "hero_subs": [
        "Multi-track timeline, frame-accurate trimming and GPU-accelerated preview. Export MP4 up to 4K without leaving the tab.",
        "Upload footage, cut on a real timeline, add titles and music, and publish straight to a shareable link — all WebRTC-free and entirely in the browser.",
        "No 4 GB downloads, no dongles, no subscription maze. Just a timeline, your footage and exports that render on our GPUs, not your battery.",
        "Collaborative by default: invite a reviewer, they leave comments right on the timeline, you fix the cut, everyone sees v2 instantly.",
    ],
    "features": [
        _feat("film", "Multi-track timeline", "Up to 12 video and audio tracks with ripple and roll edits, J/L cuts and keyboard shortcuts that match the editors you already know."),
        _feat("scissors", "Frame-accurate cutting", "Trim to the exact frame with an editable timecode display; every cut is non-destructive and re-editable forever."),
        _feat("play", "Real-time preview", "Scrub smoothly through 1080p at full frame rate; 4K projects preview in a proxy quality that renders in real time."),
        _feat("layers", "Effects & transitions", "60+ built-in effects and transitions with keyframeable parameters — fades, color wheels, speed ramps and text animations."),
        _feat("music", "Stock library", "A built-in library of licensed music and sound effects, searchable by mood and BPM, free for use in exported projects."),
        _feat("zap", "GPU rendering", "Exports render on our GPU fleet — a 10-minute 1080p export takes about 90 seconds, and you can close the tab while it finishes."),
        _feat("users", "Collaborative editing", "Invite editors and reviewers with per-project roles; reviewers comment on the timeline itself, frame by frame."),
        _feat("copy", "Reusable templates", "Save title styles, transitions and whole sequences as templates, then apply them to new footage in one click."),
        _feat("clock", "Auto-save & history", "Every change is saved within seconds, with a full version history you can scrub through like an edit timeline."),
        _feat("upload", "Any source", "Import from your computer, from a URL, or straight from a shareable camera roll — phone footage up to {maxsize} per clip."),
        _feat("eye", "Review links", "Send a review link; stakeholders watch, comment and approve without an account and without seeing the editor UI."),
        _feat("code", "Automation API", "Drive edits programmatically: assemble templated videos from a JSON recipe, trigger renders from your own pipeline."),
    ],
    "steps": [
        ("Import footage", "Drag clips in or pull from a link. We generate proxies for instant scrubbing on any machine."),
        ("Cut & compose", "Trim on the timeline, add music, titles and effects. Preview plays in real time as you work."),
        ("Export & share", "Render on our GPUs and get a download link or an embeddable player page, ready in minutes."),
    ],
    "faq": [
        ("Can it really replace a desktop editor?",
         "For most online work — YouTube, social, marketing cuts — yes: the timeline, keyframes and export pipeline are the real deal. For cinema-grade color and multicam sync, we're honest about the gap."),
        ("What footage formats can I import?",
         "MP4, MOV, MKV, WebM, AVI and ProRes, up to {maxsize} per file and 4K60. Camera footage from phones and drones works out of the box."),
        ("Where do exports render?",
         "On our GPU cluster, not your machine — you can close the tab. A 10-minute 1080p export typically finishes in under two minutes."),
        ("How does collaboration work?",
         "Editors work in the same project with live presence; reviewers get a lightweight link with frame-accurate commenting and an approve button."),
        ("Is my footage private?",
         "Projects are private by default and stored encrypted; review links are unguessable, and you can revoke any link instantly."),
        ("What about music licensing?",
         "The built-in library is licensed for use in videos you export from {brand}, including commercial work. Third-party tracks you upload remain your responsibility."),
    ],
    "stat_set": ["users", "pb", "uptime", "min", "countries"],
    "table": {
        "title": "Recently rendered projects",
        "note": "Public renders from the last few hours (shared with permission).",
        "cols": [("Project", "title"), ("Duration", "duration"), ("Resolution", "res"), ("Rendered", "ago"), ("Editor", "user")],
    },
    "formats": ["mp4", "mov", "mkv", "webm", "avi", "m4v", "prores", "gif"],
}

PACKS["pastebin"] = {
    "id": "pastebin",
    "label": "text sharing",
    "noun": "pastes",
    "name_words": (["Paste", "Text", "Snip", "Code", "Bin"],
                   ["Bin", "Box", "Store", "Board", "Hub", "Vault", "Notes"]),
    "taglines": [
        "Paste text, get a link. Simple as that.",
        "The paste tool developers actually like.",
        "Share code and text without the noise.",
        "Fast, clean pastes with syntax highlighting.",
    ],
    "hero_heads": [
        "Paste code. Get a link. Done.",
        "The fastest way to share a snippet",
        "Text sharing built for developers",
        "Your clipboard, on the internet",
        "Pastes that look good and load fast",
    ],
    "hero_subs": [
        "Syntax highlighting for 200+ languages, expiring pastes, client-side encryption and raw endpoints for curl. No account needed.",
        "Dump a stack trace, a config file or a poem; get a short link with highlighting, line numbers and a diff mode.",
        "Public, unlisted and private pastes; burn-after-read for secrets; API-friendly raw URLs that never redirect.",
        "Everything is keyboard-driven: paste, Ctrl+Enter, share. The API mirrors the UI, so scripts feel first-class.",
    ],
    "features": [
        _feat("code", "Syntax highlighting", "200+ languages with themes that match your editor, from Solarized to Gruvbox; language detection is automatic."),
        _feat("clock", "Expiring pastes", "Burn after reading, or expire in 10 minutes, a day or a month. Expired pastes return a clean 410 Gone, not an ad page."),
        _feat("lock", "Private & encrypted", "Optional client-side encryption: the key lives in the URL fragment and our servers only ever see ciphertext."),
        _feat("copy", "One-click copy", "Copy the whole paste, a line range or the raw URL without selecting anything with your mouse."),
        _feat("link", "Short, clean URLs", "Links like {domain}/p/{slug} — short enough to read over voice, long enough to be unguessable."),
        _feat("file", "Raw & embed views", "Append /raw for plain text, /download for a file, or embed a paste as an iframe with highlighting intact."),
        _feat("search", "Searchable public pastes", "Full-text search across public pastes with filters by language, size and date — useful as a living snippet archive."),
        _feat("users", "Team snippet library", "Organize pastes into collections your whole team can search, tag and pin — the end of 'check my last Slack message'."),
        _feat("zap", "Instant, no signup", "Anonymous pastes up to {freesize} with zero friction; accounts add history, editing and larger limits."),
        _feat("settings", "Line numbers & diffs", "Toggle line numbers, highlight a line range in the URL, or share two pastes as a rendered diff view."),
        _feat("eye", "View counters", "See how many times a paste was read, and when it was last accessed — without exposing who read it."),
        _feat("download", "Fork & edit", "Fork any public paste into your own editable copy, with a visible trail back to the original."),
    ],
    "steps": [
        ("Paste your text", "Type or paste anything — a snippet, log, config or note. The editor highlights as you type."),
        ("Set visibility", "Public, unlisted or encrypted; choose an expiry if the text shouldn't live forever."),
        ("Share the link", "Ctrl+Enter publishes and copies the URL. Share it, embed it, or curl the raw endpoint."),
    ],
    "faq": [
        ("What's the paste size limit?",
         "{freesize} for anonymous pastes and {maxsize} for registered users. For anything bigger, a link to a file host is usually the right tool anyway."),
        ("Are pastes indexed by search engines?",
         "Only public pastes, and only if you leave indexing on (default for public). Unlisted and private pastes are never crawled, and we honor noindex per paste."),
        ("Can I edit after publishing?",
         "Registered users can edit within a configurable window (default 24 h) or fork into a new paste with history preserved."),
        ("How does burn-after-read work?",
         "The paste is deleted from storage the moment it's fetched once. The reader can reload for 60 seconds from cache, then it's gone for everyone."),
        ("Do you keep edit history?",
         "For registered users: yes, the last 20 revisions of each paste, diffable. Anonymous pastes have no history — what you see is all there is."),
        ("Is there a rate limit?",
         "Anonymous: 20 pastes per hour per IP. Registered: 200 per hour. API tokens can be raised on request — we mostly care about floods, not volume."),
    ],
    "stat_set": ["links", "users", "uptime", "formats", "speed"],
    "table": {
        "title": "Recent public pastes",
        "note": "A live sample of public pastes from the last hour.",
        "cols": [("Title", "title"), ("Language", "lang"), ("Size", "size"), ("Views", "count"), ("Author", "user")],
    },
    "formats": ["py", "js", "ts", "go", "rs", "c", "cpp", "java", "sh", "yml", "json", "sql"],
}

PACKS["converter"] = {
    "id": "converter",
    "label": "file conversion",
    "noun": "conversions",
    "name_words": (["Convert", "Trans", "Morph", "Shift", "Alch"],
                   ["Files", "Mate", "Hub", "Lab", "Works", "Forge", "Box"]),
    "taglines": [
        "Convert anything to anything.",
        "300+ formats. One clean interface.",
        "The converter that doesn't waste your afternoon.",
        "Files in, files out, no watermarks.",
    ],
    "hero_heads": [
        "Convert {formats} file formats in your browser",
        "Any file, any format, minutes not hours",
        "Conversion without the watermark circus",
        "Drag in, convert, download. That simple.",
        "The last file converter you'll search for",
    ],
    "hero_subs": [
        "Documents, images, audio, video and ebooks — 300+ format pairs, batch mode, and files deleted from our servers within hours.",
        "Upload, pick a target format, download. No watermarks on paid plans, no email-required hostage downloads, no fake buttons.",
        "Batch-convert dozens of files at once with shared presets. GPU video transcoding and multi-core everything else.",
        "From URL to converted file in one step: paste a link, choose the output, and we fetch and convert without you downloading first.",
    ],
    "features": [
        _feat("repeat", "300+ format pairs", "Office documents, images, audio, video, ebooks, CAD and archives — the matrix covers every conversion people actually search for."),
        _feat("layers", "Batch processing", "Queue dozens of files, apply one preset to all, and download the results as a single archive when the batch finishes."),
        _feat("zap", "Fast cloud engine", "Conversions run on multi-core workers with GPU offload for video; a 100-page document lands in under a minute."),
        _feat("external", "Convert from URL", "Paste a link to a file anywhere on the public web and convert it without a local download first — perfect for phone workflows."),
        _feat("settings", "Quality presets", "Per-format controls: bitrate, resolution, color profile, compression level and OCR language, saved as reusable presets."),
        _feat("shield", "Auto-deleted input", "Source and output files are wiped within 6 hours of conversion (or on demand), and nothing is used for anything else. Ever."),
        _feat("cloud", "Cloud drive input", "Pull files straight from the major cloud drives and push results back, without round-tripping through your device."),
        _feat("download", "Bulk archives", "Multi-file conversions come back as a ZIP with a manifest; single files download directly with resume support."),
        _feat("mail", "Notify when done", "Large batches convert in the background; get an email (or a webhook) the moment the archive is ready."),
        _feat("cpu", "OCR built in", "Scanned PDFs and images convert to searchable text in 30+ languages, with layout and tables preserved."),
        _feat("code", "API & webhooks", "Automate conversions from your pipeline: queue a job by URL, poll or wait for a webhook, fetch the result. Simple and boring."),
        _feat("folder", "Archive aware", "Convert into and out of ZIP, 7z and TAR, including converting every file inside an archive in one job."),
    ],
    "steps": [
        ("Add your files", "Drop files, select a folder, or paste a URL. The format matrix shows what each file can become."),
        ("Pick output & options", "Choose the target format and tune quality presets. Batch mode applies your choices to everything."),
        ("Download results", "Grab files individually or as one archive; background jobs notify you when they're ready."),
    ],
    "faq": [
        ("Which formats are supported?",
         "{formats} pairs across documents, images, audio, video, ebooks and archives — the full matrix is on the formats page, with per-direction quality notes."),
        ("Do you add watermarks?",
         "Free plan: a small footer on document-to-PDF only. Paid plans: nothing, ever, on any format. We hate watermarks as much as you do."),
        ("How long are files kept?",
         "Six hours after the conversion completes, then permanently deleted from storage and backups. You can force-delete instantly from the job page."),
        ("Is there a file size limit?",
         "{freesize} per file on free, {maxsize} on paid. Video transcodes are additionally capped by duration: 30 min free, 6 h paid."),
        ("Can I convert files inside archives?",
         "Yes — a ZIP or 7z job can convert every contained file and repackage the results into a fresh archive with the same structure."),
        ("Do you support OCR?",
         "For PDFs and images, in 30+ languages, with automatic language detection. Output is a searchable PDF or plain text/DOCX as you prefer."),
    ],
    "stat_set": ["formats", "files", "pb", "uptime", "speed"],
    "table": {
        "title": "Recent conversions",
        "note": "Anonymized sample of jobs from the public queue.",
        "cols": [("Job", "convjob"), ("Direction", "convdir"), ("Size", "size"), ("Took", "secs"), ("User", "user")],
    },
    "formats": ["pdf", "docx", "xlsx", "pptx", "epub", "png", "webp", "mp3", "flac", "mp4", "gif", "svg"],
}

PACKS["shortener"] = {
    "id": "shortener",
    "label": "link shortening",
    "noun": "links",
    "name_words": (["Short", "Tiny", "Link", "Snip", "Trim"],
                   ["Link", "Links", "URL", "Hub", "Works", "Cut", "Bridge"]),
    "taglines": [
        "Short links with real analytics.",
        "Every link, measured.",
        "Shorten, track, and understand your traffic.",
        "Links that work as hard as you do.",
    ],
    "hero_heads": [
        "Short links that tell you everything",
        "Shorten. Track. Learn. Repeat.",
        "The link shortener marketers keep",
        "Your links, your brand, your data",
        "One click to a shorter, smarter link",
    ],
    "hero_subs": [
        "Custom back-halves, click analytics, QR codes and UTM building — with a fast API and no dark-pattern pricing.",
        "Shorten any URL, watch clicks arrive in real time, and see referrers, countries and devices for every single tap.",
        "Free custom domains, bulk shortening from CSV, and per-team workspaces. Built for people who ship campaigns weekly.",
        "Links are small; their data isn't. Every short link carries a live analytics dashboard — clicks, referrers, geography and bots filtered out.",
    ],
    "features": [
        _feat("link", "One-click shortening", "Paste a URL, hit enter, done — or use the keyboard-first UI, the browser extension or the API."),
        _feat("settings", "Custom back-halves", "Pick your own slug like {domain}/launch-2026, or let us generate short, pronounceable, case-safe ones."),
        _feat("eye", "Click analytics", "Unique vs. total clicks, referrers, countries, devices and a live stream — with bots and link previews filtered out."),
        _feat("layers", "QR codes", "Every short link gets a print-ready QR with your colors and logo; download as SVG or PNG at any size."),
        _feat("repeat", "Bulk shortening", "Paste a list or upload a CSV of hundreds of URLs and get all links back, named and tagged, in one file."),
        _feat("tag", "UTM builder", "Add campaign parameters with a guided builder; we validate the combination so your analytics stay clean."),
        _feat("users", "Team workspaces", "Shared link libraries with roles: editors create and edit, viewers get dashboards only, owners manage billing."),
        _feat("shield", "Abuse screening", "Every destination is checked against blocklists and phishing heuristics before a link goes live; flagged links stay locked until reviewed."),
        _feat("code", "API & webhooks", "Create links, fetch stats and manage tags over a tidy REST API; webhooks push click milestones to your systems."),
        _feat("clock", "Link scheduling", "Set a link to start redirecting (or stop) at a specific time — campaign launches without a person awake at 3 a.m."),
        _feat("external", "Custom domains", "Free on all paid plans: use your own domain with automatic HTTPS certificates issued within minutes."),
        _feat("copy", "Instant copy & share", "New links land on your clipboard automatically, ready for chat, social or docs."),
    ],
    "steps": [
        ("Paste a long URL", "Drop in any link — the builder can add UTMs and a custom slug in the same step."),
        ("Customize", "Choose the back-half, tags, schedule and QR options, or accept the sensible defaults."),
        ("Share & watch", "Copy the link and watch clicks arrive live, with referrers, countries and devices broken out."),
    ],
    "faq": [
        ("Do short links ever expire?",
         "Links on free accounts stay active while the account is used at least once every 6 months; paid links never expire, even if you cancel — they redirect to a parked notice instead of dying."),
        ("Can I edit where a link points?",
         "Yes, anytime — the short URL stays the same while the destination changes. Every edit is logged with a timestamp and which team member made it."),
        ("How are bots counted?",
         "We fingerprint fetchers by behavior and headers; known bots and link-preview scrapers are separated into their own counter so your numbers stay honest."),
        ("Can I use my own domain?",
         "On all paid plans, with unlimited domains. DNS verification takes a TXT record, and certificates issue automatically within minutes."),
        ("Is there a click limit?",
         "No. We've served links through viral moments with 2M clicks an hour; rate limits protect the API, not your redirects."),
        ("What happens if I delete a link?",
         "It stops redirecting immediately and its stats are archived for 30 days (recoverable), then everything is permanently deleted."),
    ],
    "stat_set": ["links", "users", "uptime", "countries", "speed"],
    "table": {
        "title": "Recently created links",
        "note": "Public links created in the last few minutes.",
        "cols": [("Short link", "slug"), ("Destination", "dest"), ("Clicks", "count"), ("Created", "ago"), ("By", "user")],
    },
    "formats": [],
}

PACKS["cloud"] = {
    "id": "cloud",
    "label": "cloud storage",
    "noun": "files",
    "name_words": (["Safe", "Vault", "Drive", "Stash", "Pocket", "Home"],
                   ["Drive", "Vault", "Store", "Space", "Cloud", "Keep", "Locker", "Box"]),
    "taglings_placeholder": None,  # cleanup marker, removed below
    "taglines": [
        "Your files, everywhere, actually private.",
        "Storage that syncs at LAN speed.",
        "The cloud drive you'll stop worrying about.",
        "Encrypted storage with a family plan that makes sense.",
    ],
    "hero_heads": [
        "All your files, one safe place",
        "Cloud storage people actually keep",
        "Sync everything, worry about nothing",
        "{freegb} GB free. Upgrade when you're ready.",
        "Storage that doesn't hold your files hostage",
    ],
    "hero_subs": [
        "Client-side encryption, selective sync and instant camera backup. Start with {freegb} GB free, upgrade whenever.",
        "Files sync at full line speed, share links get passwords and expiry, and deleted files stay recoverable for 30 days.",
        "One drive for documents, photos and backups — versioned, searchable and accessible from every device you own.",
        "Zero-knowledge encryption means we can't read your files even if we wanted to. Sharing still works, right from the browser.",
    ],
    "features": [
        _feat("cloud", "Sync everywhere", "Windows, macOS, Linux, Android and iOS apps keep a folder in sync — background, LAN-accelerated where possible."),
        _feat("lock", "Zero-knowledge mode", "Optional end-to-end encryption: keys stay on your devices; sharing with others works through wrapped keys, not trust."),
        _feat("clock", "30-day version history", "Every change is kept for 30 days (up to a year on paid plans) — ransomware Tuesday becomes a restore-and-lunch day."),
        _feat("upload", "Camera & folder backup", "Phone photos and desktop folders back up automatically, with charging and Wi-Fi rules you control."),
        _feat("search", "Full-text search", "Search inside PDFs, Office docs and notes (locally indexed in E2E mode) — results appear as fast as you type."),
        _feat("link", "Smart share links", "Password, expiry, download limits and view-only mode on any file or folder; revoke a link and every copy stops working."),
        _feat("folder", "Selective sync", "Choose which folders live on which machine; placeholders let you browse everything without filling your disk."),
        _feat("users", "Family & team plans", "One billing, separate spaces and a shared area; per-member quotas and parental controls that are simple enough to use."),
        _feat("trash", "Ransomware rollback", "Mass-change detection offers a one-click restore of an entire folder tree to any point in the last 30 days."),
        _feat("server", "Personal sync nodes", "Point the client at your own NAS or server for hybrid setups — same apps, your hardware, your rules."),
        _feat("cpu", "Deduplication", "Identical blocks upload once; families sharing photos save 40% of their quota without doing anything."),
        _feat("code", "WebDAV & API", "Mount your drive over WebDAV or script it via REST; S3-compatible endpoints for backup tools that speak S3."),
    ],
    "steps": [
        ("Install the app", "The client sets up a synced folder in about a minute — no account gymnastics, just email and a password."),
        ("Drop in your files", "Drag anything into the folder; changes sync in the background and versions accumulate automatically."),
        ("Share or publish", "Right-click any file for a share link with password, expiry and view tracking baked in."),
    ],
    "faq": [
        ("How much free storage do I get?",
         "{freegb} GB, permanently, no credit card. Invite friends and both sides gain 1 GB, up to a total of {freegbmax}."),
        ("Can I switch from Drive/Dropbox?",
         "The importer pulls files over from major providers while keeping folder structure, and can mirror-share links during the transition."),
        ("What happens if I go over quota?",
         "Sync pauses — nothing is deleted. You get an email and an in-app notice; files still download fine while uploads wait."),
        ("Is the encryption really end-to-end?",
         "In zero-knowledge mode: keys are generated on your device, stored in your OS keychain, and never uploaded — we couldn't read your files with a warrant and a time machine."),
        ("Do you throttle uploads?",
         "No. Free and paid get the same speed; only storage size and history length differ between plans."),
        ("Can I self-host part of it?",
         "Yes — point clients at your own storage node for selected folders. The cloud keeps metadata; your hardware keeps the bytes."),
    ],
    "stat_set": ["pb", "files", "users", "uptime", "retention"],
    "table": {
        "title": "Recent shared folders",
        "note": "Public folders shared by users in the last 24 hours.",
        "cols": [("Folder", "foldername"), ("Files", "count"), ("Size", "size"), ("Shared", "ago"), ("Owner", "user")],
    },
    "formats": ["docx", "pdf", "xlsx", "jpg", "png", "mp4", "zip", "txt"],
}

PACKS["screenshot"] = {
    "id": "screenshot",
    "label": "screenshot sharing",
    "noun": "shots",
    "name_words": (["Snap", "Shot", "Pixel", "Screen", "Glint", "Flash"],
                   ["Shot", "Shots", "Snap", "Snap", "Store", "Pix", "Deck"]),
    "taglines": [
        "Screenshot. Annotate. Share. Seconds.",
        "The screenshot tool with the shortest path to done.",
        "Capture, mark up and send — before your coffee cools.",
        "Screenshots that explain themselves.",
    ],
    "hero_heads": [
        "From screen to share link in three seconds",
        "Screenshots with annotation that doesn't suck",
        "Press one key. Get a link.",
        "The fastest screenshot workflow on any OS",
        "Capture it, mark it, ship it",
    ],
    "hero_subs": [
        "Capture a region, window or full page; annotate with arrows, text and blur; the link is on your clipboard when you let go of the hotkey.",
        "One hotkey captures, a second one shares. Annotations are non-destructive — un-blur or un-crop later without re-shooting.",
        "Scrolling-page capture, OCR text extraction and instant sharing — built for support teams and bug reporters who live in screenshots.",
        "Every shot gets a viewer page with zoom and comments; embed the direct link in tickets, docs and chats without attachments.",
    ],
    "features": [
        _feat("zap", "Global hotkey capture", "Press the hotkey, drag a region, release — the shot uploads and the URL is already on your clipboard."),
        _feat("scissors", "Non-destructive annotation", "Arrows, text, numbered steps, highlight and pixel-perfect blur; every element stays editable after saving."),
        _feat("search", "OCR text extraction", "Text inside shots becomes searchable and copyable — grab an error message or a serial number straight from the image."),
        _feat("image", "Scrolling capture", "Capture an entire scrolling page or chat as one tall shot, with sticky headers stitched out automatically."),
        _feat("eye", "Comments on shots", "Viewers comment directly on the image; discussions thread per annotation and resolve with a checkmark."),
        _feat("clock", "Auto-expiring shots", "Set shots to vanish in an hour or a month — perfect for sharing logs or customer data without a paper trail."),
        _feat("lock", "Private by default", "Links contain 48 bits of entropy; add a password or lock a shot to a specific email domain in two clicks."),
        _feat("film", "Screen recording", "The same hotkey records video: region or window, with system audio and mic mixing, exported as MP4 or GIF."),
        _feat("users", "Team collections", "Group shots into collections per project or customer, with per-collection privacy defaults and retention rules."),
        _feat("download", "Bulk export", "Download any collection as a ZIP with annotations baked in or as clean originals — your pick."),
        _feat("copy", "Embed-ready links", "Direct image URL, Markdown snippet, or an iframe viewer with comments; one click each."),
        _feat("code", "CLI & API", "Screenshot from scripts and CI: pipe an image in, get a URL out; the API covers collections, permissions and retention."),
    ],
    "steps": [
        ("Capture", "Hit the hotkey and drag — region, window, or a whole scrolling page."),
        ("Annotate", "Arrows, steps, blur and text; everything stays editable, even after sharing."),
        ("Share", "Release and the link is copied; viewers open a clean page with zoom and comments."),
    ],
    "faq": [
        ("Which platforms are supported?",
         "Windows, macOS and Linux clients, plus a browser extension for full-page captures; the web app handles uploads and management everywhere."),
        ("What's the retention on shots?",
         "Shots stay while your account is active (free: 90 days of history). Team plans set retention per collection, from 24 hours to forever."),
        ("Can blur be undone by viewers?",
         "No — blur bakes into the shared image. You can undo it yourself in the editor later, because the original capture is kept privately."),
        ("Is there a size or dimension limit?",
         "Up to {maxsize} per shot and 12,000 px on the long side (scrolling captures included). Animated GIFs up to 30 seconds."),
        ("Do viewers need accounts?",
         "Never. The viewer page is public-with-link, works on mobile, and supports zoom, dark mode and comments without sign-up."),
        ("How does screen recording work?",
         "Same hotkey family: record a region or window with audio mixing, trim in the browser, and share as a streaming page or MP4 download."),
    ],
    "stat_set": ["files", "users", "speed", "uptime", "countries"],
    "table": {
        "title": "Recent public shots",
        "note": "Public shots shared in the last few minutes.",
        "cols": [("Shot", "filename"), ("Dimensions", "dims"), ("Size", "size"), ("Views", "count"), ("Author", "user")],
    },
    "formats": ["png", "jpg", "webp", "gif", "mp4"],
}

PACKS["codehost"] = {
    "id": "codehost",
    "label": "code hosting",
    "noun": "repositories",
    "name_words": (["Code", "Git", "Repo", "Forge", "Source", "Dev"],
                   ["Forge", "Hub", "Base", "Vault", "Host", "Works", "Tree"]),
    "taglines": [
        "Git hosting without the complexity tax.",
        "Where your code lives when it grows up.",
        "Repositories, CI and reviews — batteries included.",
        "The forge built for small teams that ship.",
    ],
    "hero_heads": [
        "Git hosting that stays out of your way",
        "Your code, your rules, your forge",
        "Repos, reviews and CI in one calm place",
        "Unlimited private repositories",
        "The code host you can actually self-host",
    ],
    "hero_subs": [
        "Unlimited private repos, pull requests with real review tools, and CI minutes included on every plan — free for small teams.",
        "Import from any Git host in minutes, keep your issues and wiki, and give your team review workflows that don't fight back.",
        "A forge with the 20% of features you use daily — diffs, reviews, releases, CI — and none of the enterprise maze around them.",
        "Push, review, merge, release: keyboard-driven and fast. Self-hostable with Docker in one afternoon if you'd rather own the metal.",
    ],
    "features": [
        _feat("code", "Real diff review", "Side-by-side and split diffs, comment threads on lines, suggested changes and one-click apply of suggestions."),
        _feat("layers", "Branch protection", "Required reviews, status checks and immutable release tags — rules that read like sentences, not regex puzzles."),
        _feat("cpu", "Built-in CI", "YAML pipelines with hosted runners (Linux, Windows, arm64) and self-hosted agents; minutes pooled across the org."),
        _feat("shield", "Vulnerability scanning", "Dependency scanning on every push, with a quiet dashboard instead of alert spam for transitive noise."),
        _feat("tag", "Releases & packages", "Tag a release and attach artifacts; built-in package registry for npm, PyPI and containers, private by default."),
        _feat("search", "Code search", "Fast regex search across every repo you can read — results with context lines, not just file names."),
        _feat("film", "Merge queue", "Queue PRs, auto-rebase and run required checks again — merged changes always pass the branch rules, no exceptions."),
        _feat("users", "Fine-grained permissions", "Per-repo roles and scoped deploy tokens; audited access reviews remind owners about stale permissions quarterly."),
        _feat("folder", "Import everything", "One-command import from the big hosts, bringing issues, labels, releases and wiki history with you."),
        _feat("server", "Self-host option", "The same forge ships as a Docker stack: single binary plus Postgres, upgrade by pulling the next tag."),
        _feat("repeat", "Fork & mirror", "Fork publicly or privately, mirror to other forges on a schedule, and sync upstream with two clicks."),
        _feat("key", "Static Pages", "Publish static sites straight from a repo: push HTML or a framework build, get HTTPS and preview URLs per PR."),
    ],
    "steps": [
        ("Create or import a repo", "New repo in seconds, or import from your current host with issues and releases intact."),
        ("Push & review", "Open a PR, get a real diff with threaded comments and suggested changes, merge through the queue."),
        ("Automate & release", "CI runs your checks; tag a release with artifacts attached and packages published."),
    ],
    "faq": [
        ("How many private repos do I get?",
         "Unlimited on every plan, including free. The free tier is capped by collaborators (5) and CI minutes (2,000/mo), not by repository count."),
        ("Can I import from GitHub/GitLab?",
         "Yes: the importer pulls repos, issues, labels, milestones, releases and wiki history, and keeps a redirect map of issue URLs."),
        ("What are CI minutes exactly?",
         "Wall-clock time on hosted runners. Self-hosted runners are unlimited and free; jobs cache dependencies to keep minute usage honest."),
        ("Is there an API?",
         "Full REST and a stable webhook set covering pushes, PRs, issues and releases — enough to wire the forge into anything you already run."),
        ("Can we self-host later?",
         "Yes, and you can start hosted and move: export is a documented, complete archive, and the self-hosted edition reads it natively."),
        ("How are security issues handled?",
         "We run dependency scanning on every push and accept reports via our security.txt; criticals get patch releases within 72 hours."),
    ],
    "stat_set": ["files", "users", "uptime", "countries", "speed"],
    "table": {
        "title": "Trending repositories",
        "note": "Public repos with the most stars gained this week.",
        "cols": [("Repository", "reponame"), ("Language", "lang"), ("Stars", "count"), ("Updated", "ago"), ("Owner", "user")],
    },
    "formats": ["git", "zip", "tar.gz", "docker", "npm", "pypi"],
}

PACKS["analytics"] = {
    "id": "analytics",
    "label": "web analytics",
    "noun": "sites",
    "name_words": (["Meta", "Count", "Pulse", "Stat", "Metric", "Insight"],
                   ["Metrics", "Pulse", "Board", "Scope", "Lab", "Deck", "Stats"]),
    "taglines": [
        "Web analytics without the creep factor.",
        "Know your traffic. Skip the surveillance.",
        "Privacy-first analytics that load fast.",
        "Every visit, counted honestly.",
    ],
    "hero_heads": [
        "Analytics that respect your visitors",
        "See every visitor, track nothing creepy",
        "Real-time analytics, cookieless",
        "The dashboard your whole team opens",
        "Numbers you can act on by lunch",
    ],
    "hero_subs": [
        "One script tag, 1.2 KB, no cookies, no personal data. Dashboards load in real time and stay readable by non-analysts.",
        "Pageviews, referrers, geography and funnels without consent banners — the privacy side effect of collecting nothing personal.",
        "Set up in five minutes: one tag, one dashboard. Real-time view, funnel analysis and email reports your CEO can read.",
        "Aggregate metrics that answer real questions — where traffic comes from, what it reads, where it leaves — with zero PII collected.",
    ],
    "features": [
        _feat("eye", "Real-time dashboard", "Watch visitors arrive live: active people, current pages, referrers and a rolling 30-minute pulse."),
        _feat("zap", "1 KB script", "A single async tag under 1.2 KB; nothing blocks rendering, and ad blockers increasingly let it through."),
        _feat("globe", "Geography & language", "Country and language breakdowns from header data — accurate to a region, without an IP address stored."),
        _feat("layers", "Funnels & goals", "Define goals and multi-step funnels in plain language; see drop-off per step with segment comparison."),
        _feat("search", "Site search tracking", "See what visitors search for inside your site — a content roadmap written by your audience."),
        _feat("clock", "Email reports", "Daily or weekly digests per team member, in plain language, with the one number that changed most on top."),
        _feat("shield", "No cookies, ever", "No consent banner needed: no cookies, no fingerprints, no cross-site IDs. GDPR-friendly by architecture, not policy."),
        _feat("users", "Unlimited team seats", "Every plan includes unlimited teammates with view or admin roles — analytics shouldn't be priced per chair."),
        _feat("tag", "UTM & campaigns", "Automatic UTM parsing with a campaign timeline, so 'did the launch post work' has an actual answer."),
        _feat("external", "SPA & static friendly", "Route-change events for SPAs, works with every static site generator, and a server-side API for apps without pages."),
        _feat("message", "Slack & webhook alerts", "Traffic spike alerts to Slack or any webhook, tuned per team so nobody gets paged for a Tuesday."),
        _feat("code", "Data export & API", "Full CSV export and a read API; your numbers are yours, and leaving shouldn't mean losing history."),
    ],
    "steps": [
        ("Add the tag", "One script tag in your <head> (or one API call) — no config files, no SDK, no cookie banner to deploy."),
        ("Watch it fill", "The dashboard shows live visits within seconds of the first pageview."),
        ("Set goals", "Define funnels and goals in plain language; alerts and reports follow automatically."),
    ],
    "faq": [
        ("Is it really cookieless?",
         "Yes — no cookies, no localStorage identifiers, no fingerprinting. Uniqueness is estimated statistically per time window, never per person."),
        ("How accurate are unique counts?",
         "Within a few percent for typical sites. Because we don't persist identifiers, the same person on a new device is counted again — we show both raw and estimated views."),
        ("Will ad blockers break it?",
         "A share of blockers filter the script; a first-party subdomain setup (included on paid plans) recovers most of that traffic."),
        ("Does it slow my site down?",
         "The tag is 1.2 KB, async, and served from a cookieless domain — measured impact on LCP is consistently under 10 ms."),
        ("Can I track a SPA?",
         "Yes: one call per route change (or automatic history-hooking), with duration tracking per virtual pageview."),
        ("What about GDPR/ePrivacy?",
         "No personal data is collected or stored, so in most cases no consent is required; our docs include per-jurisdiction notes and a DPA template."),
    ],
    "stat_set": ["users", "links", "uptime", "countries", "speed"],
    "table": {
        "title": "Live activity",
        "note": "Anonymized sample of events from the last few minutes.",
        "cols": [("Site", "sitename"), ("Visitors now", "count"), ("Top page", "page"), ("Trend", "trend"), ("Owner", "user")],
    },
    "formats": [],
}

PACKS["uptime"] = {
    "id": "uptime",
    "label": "uptime monitoring",
    "noun": "monitors",
    "name_words": (["Up", "Watch", "Sentinel", "Pulse", "Guard", "Ping"],
                   ["Dog", "Tower", "Watch", "Pulse", "Scope", "Eye", "Monitor"]),
    "taglines": [
        "Know your site is down before your users do.",
        "Uptime monitoring with honest 30-second checks.",
        "Down before Twitter. Every time.",
        "Monitoring that doesn't cry wolf.",
    ],
    "hero_heads": [
        "Your site is down. You know in 30 seconds.",
        "Monitoring that beats the Twitter mentions",
        "Every minute of downtime, measured",
        "Status pages people actually trust",
        "Alerts that wake you only when needed",
    ],
    "hero_subs": [
        "HTTP, keyword, port and heartbeat checks from 12 regions every 30 seconds, with escalation policies that respect on-call sleep.",
        "Public status pages with real history, subscriber notifications and a 99.9x% number you can put in your SLA — because it's honest.",
        "If a probe in Frankfurt fails but 11 others pass, you get a note, not a 3 a.m. page. Alerting logic with a brain, in other words.",
        "Heartbeat monitoring for cron jobs and backups: if your script doesn't check in, that's an incident too — a quiet one, until it isn't.",
    ],
    "features": [
        _feat("eye", "30-second checks", "Every monitor polls from all regions every 30 seconds on paid plans (60 s free) — not the 5-10 minutes that let outages hide."),
        _feat("globe", "12 global regions", "North America, Europe, Asia and Oceania probes let you tell 'site down' from 'one BGP route being weird'."),
        _feat("zap", "Smart alerting", "Region-majority logic, confirmation windows and maintenance windows: you get paged for real outages, not flapping edges."),
        _feat("message", "Everything rings", "Email, SMS, phone call, Slack, Telegram, PagerDuty, webhooks — escalation ladders per team with quiet hours respected."),
        _feat("clock", "Heartbeats for cron", "Watch scheduled jobs and backups: expected check-ins that page when silent, with grace periods per job."),
        _feat("layers", "Status pages", "Hosted status pages with component-level history, subscriber email/SMS/RSS updates and your own domain and branding."),
        _feat("server", "SSL & domain expiry", "Certificate expiry and renewal checks, plus domain expiration monitoring — the boring failures that hurt most."),
        _feat("chart", "Latency percentiles", "p50/p95/p99 charts per region, so 'slow but up' gets caught before it becomes 'down'."),
        _feat("users", "On-call schedules", "Calendar rotation with overrides, handoffs and fair warning before someone's first 3 a.m. shift."),
        _feat("shield", "Incident post-mortems", "Timeline view of every incident: what failed, when, who responded — exportable for your post-mortem doc."),
        _feat("repeat", "Maintenance windows", "Planned work suppresses alerts per monitor or tag, and the status page shows it as maintenance, not downtime."),
        _feat("code", "API & Terraform", "Monitors, alerts and status pages as code: full REST API, Terraform provider and an Ansible module."),
    ],
    "steps": [
        ("Add a monitor", "Paste a URL (or host:port) — first check runs within seconds from all regions."),
        ("Set up alerting", "Pick channels and escalation rules; the wizard previews exactly who gets notified when."),
        ("Publish your status", "Enable a public status page with your domain, and let subscribers sign up for updates."),
    ],
    "faq": [
        ("How fast are down alerts?",
         "Median time-to-alert is 40 seconds from first failing check on 30-second plans; confirmation windows add 1-2 checks if you want fewer false positives."),
        ("What can be monitored?",
         "HTTP(S) with keyword/body checks, raw TCP ports, ICMP pings, cron heartbeats and — on team plans — full browser flows like login paths."),
        ("Do you offer SMS/calls?",
         "Yes, worldwide SMS and voice calls on paid plans, with fair-use pricing spelled out (no surprise per-page bills)."),
        ("Can status pages use our domain?",
         "status.yourdomain.com with automatic HTTPS on all plans, plus custom CSS and components on Team."),
        ("What's the false alert rate?",
         "Region-majority confirmation cuts false pages to near zero; our own monitors get paged more often than our customers do."),
        ("Is there a free tier?",
         "10 monitors at 60-second intervals with email alerts — free forever, no credit card, no 'trial' countdown."),
    ],
    "stat_set": ["uptime", "users", "countries", "speed", "min"],
    "table": {
        "title": "Recent incidents (public)",
        "note": "Public status pages reporting incidents right now.",
        "cols": [("Service", "sitename"), ("Status", "status"), ("Started", "ago"), ("Duration", "duration"), ("Region", "region")],
    },
    "formats": [],
}

PACKS["archive"] = {
    "id": "archive",
    "label": "online archiving",
    "noun": "archives",
    "name_words": (["Archive", "Vault", "Keep", "Vault", "Vault", "Preserve"],
                   ["Vault", "Keep", "Archive", "Stack", "Shelf", "Depot", "Bay"]),
    "taglines": [
        "Archiving that outlives link rot.",
        "Save web pages exactly as they are.",
        "The internet's memory, one snapshot at a time.",
        "Permanent storage for things that matter.",
    ],
    "hero_heads": [
        "Archive any web page, forever",
        "Snapshots that don't rot",
        "Your own internet archive",
        "Cite it. It won't move.",
        "Save the page, keep the proof",
    ],
    "hero_subs": [
        "Paste a URL and get a permanent, timestamped snapshot with images, styles and scripts frozen — citable and shareable.",
        "Full-page captures stored redundantly with cryptographic timestamps: the citation you make today still resolves in ten years.",
        "Auto-archive on a schedule: watch a page, keep every change, and diff any two versions side by side.",
        "Collections for research, legal and journalism teams — exportable as WARC, the archival format libraries actually accept.",
    ],
    "features": [
        _feat("globe", "Full-page capture", "The entire page — HTML, CSS, images, fonts and inline scripts — frozen into a single replayable snapshot."),
        _feat("clock", "Cryptographic timestamps", "Every snapshot is hashed and anchored to a public timestamp chain; prove a page said X on a given day."),
        _feat("repeat", "Scheduled re-captures", "Watch any URL hourly, daily or weekly; every version is kept and diffable against any other."),
        _feat("layers", "Version diffing", "Text and visual diffs between any two snapshots — spot the edited paragraph, the vanished disclaimer."),
        _feat("folder", "Collections", "Organize snapshots into research collections with notes, tags and per-collection sharing and export."),
        _feat("search", "Full-text search", "Search the text of everything you've archived, or everything public — a private search engine of the pages you care about."),
        _feat("download", "WARC export", "Standard WARC exports per snapshot or collection — load them in any archival tool, forever, no lock-in."),
        _feat("users", "Team research spaces", "Shared collections for legal, journalism and research teams, with roles and an activity log of who archived what."),
        _feat("mail", "Page-change alerts", "Get an email digest when a watched page changes: the diff, front and center, no login needed to read it."),
        _feat("shield", "Tamper-evident audit log", "Snapshots are append-only; even we can't quietly edit history, and the hash chain would notice if we tried."),
        _feat("tag", "Citations & embeds", "Every snapshot gets a stable citation URL and an embed code — footnotes that survive redesigns."),
        _feat("code", "API & browser extension", "Archive from a right-click or a script: the extension captures the live tab, the API ingests URLs and sitemaps."),
    ],
    "steps": [
        ("Paste a URL", "We fetch the page with all assets and freeze it into a replayable snapshot."),
        ("Keep versions", "Schedule re-captures and get change alerts with clean diffs between versions."),
        ("Cite & export", "Share the stable snapshot URL, or export collections as standard WARC files."),
    ],
    "faq": [
        ("What exactly gets saved?",
         "The rendered page: HTML, CSS, images, fonts and first-party scripts — enough for a pixel-faithful replay of what a visitor saw. Third-party trackers are deliberately dropped."),
        ("How long do snapshots live?",
         "Permanently by default on paid plans; free snapshots are kept while the account is active, with a yearly 'still want this?' email before any cleanup."),
        ("Can a snapshot be deleted?",
         "By the account owner, yes (and by valid legal notice). Deletions are logged in the public audit log as 'removed at owner request', without exposing content."),
        ("Is archiving legal?",
         "For personal reference, research and citation, generally yes in most jurisdictions; our docs cover the nuances and we honor takedown requests."),
        ("Can I import existing archives?",
         "Upload WARC files and they merge into your collection, replayable and searchable alongside new captures."),
        ("Do you respect robots.txt?",
         "No — but we respect site rate limits and we don't republish private pages: snapshots are unlisted, and public listing is a deliberate choice per snapshot."),
    ],
    "stat_set": ["files", "pb", "users", "retention", "countries"],
    "table": {
        "title": "Recently archived pages",
        "note": "Public snapshots from the last few hours.",
        "cols": [("Page", "pagetitle"), ("Domain", "domain"), ("Size", "size"), ("Captured", "ago"), ("By", "user")],
    },
    "formats": ["warc", "html", "pdf", "png"],
}

PACKS["notes"] = {
    "id": "notes",
    "label": "note taking",
    "noun": "notes",
    "name_words": (["Note", "Jot", "Scribe", "Ink", "Leaf", "Quill"],
                   ["Notes", "Book", "Space", "Pad", "Well", "Forest", "Stack"]),
    "taglines": [
        "Notes that sync and never get lost.",
        "Markdown notes with a brain.",
        "Write it down, find it forever.",
        "The calm notebook for busy minds.",
    ],
    "hero_heads": [
        "Write it down. Find it in a year.",
        "Notes that organize themselves",
        "A notebook that thinks in links",
        "Markdown, backlinks, zero chaos",
        "Your second brain, without the setup",
    ],
    "hero_subs": [
        "Plain Markdown files, bi-directional links, instant search and end-to-end encryption — the note app that doesn't hold your notes hostage.",
        "Notes are plain .md files on your device, synced with conflict-free merging. Backlinks and a graph emerge as you write.",
        "Capture on any device, structure later: tags, links and daily notes turn a pile of thoughts into a searchable second brain.",
        "End-to-end encrypted sync with a fast editor: 20 ms keystrokes, offline-first, and a web clipper for research sessions.",
    ],
    "features": [
        _feat("file", "Plain Markdown files", "Your notes are .md files in a folder you own — open them in any editor, forever, no export needed."),
        _feat("repeat", "Backlinks & graph", "Every note shows what links to it, and the graph view maps how your thinking connects."),
        _feat("search", "Instant search", "Search-as-you-type across every note's full text, with fuzzy matching and tag filters."),
        _feat("clock", "Daily notes & journal", "One keystroke opens today's note; the journal view stitches them into a timeline you'll actually reread."),
        _feat("scissors", "Web clipper", "Clip pages as clean Markdown — articles without the popups — filed under a tag you choose."),
        _feat("lock", "End-to-end encryption", "Optional E2E sync: keys on your devices, notes encrypted before they leave, sharing via wrapped keys."),
        _feat("layers", "Nested tags & folders", "Organize however you think — folders, nested tags, or both; moving things never breaks links."),
        _feat("users", "Shared notebooks", "Share a notebook or a single note with view or edit rights; changes merge without conflicts."),
        _feat("image", "Inline images & code", "Paste images and code blocks with syntax highlighting; math renders via a built-in pipeline."),
        _feat("zap", "Offline-first", "Everything works offline and syncs when you're back — merging is automatic, with a per-note history."),
        _feat("code", "Plugin API", "A small, stable plugin API: themes, export formats and editor extensions, sandboxed from your data."),
        _feat("download", "Export anywhere", "Export to Markdown, HTML or PDF — a whole notebook or a single note, structure preserved."),
    ],
    "steps": [
        ("Capture a thought", "Open the app and type; daily notes and quick capture keep friction at zero."),
        ("Link as you go", "Double-bracket a name to create or link a note; the backlink graph builds itself."),
        ("Find it later", "Search anything in a few keystrokes, or follow links the way you think."),
    ],
    "faq": [
        ("Where are my notes stored?",
         "As plain .md files in a local folder, synced through our servers (encrypted in E2E mode). If we vanish, your files remain."),
        ("Can I use it offline?",
         "Fully. The apps are offline-first; edits queue and merge automatically when a connection returns."),
        ("How does E2E sharing work?",
         "Each shared note gets a wrapped key per recipient; we store ciphertext and metadata only — we can't read shared content."),
        ("Is there a mobile app?",
         "iOS and Android apps with the full editor, offline sync and the clipper share-sheet; the web app covers everything else."),
        ("What's the free plan?",
         "Unlimited local notes, sync of up to 200 notes and 50 MB of attachments — enough to live on for a while, honestly."),
        ("Can I migrate from Notion/Obsidian?",
         "The importer reads Markdown exports (Obsidian directly, Notion via its export) and keeps attachments, links and tags."),
    ],
    "stat_set": ["files", "users", "uptime", "speed", "retention"],
    "table": {
        "title": "Public notes",
        "note": "Notes users chose to publish, updated recently.",
        "cols": [("Note", "notetitle"), ("Words", "count"), ("Tags", "tags"), ("Updated", "ago"), ("Author", "user")],
    },
    "formats": ["md", "txt", "html", "pdf"],
}

PACKS["backup"] = {
    "id": "backup",
    "label": "backup service",
    "noun": "backups",
    "name_words": (["Back", "Guard", "Shield", "Safe", "Anchor", "Haven"],
                   ["Up", "Keep", "Vault", "Store", "Hold", "Guard", "Bunker"]),
    "taglines": [
        "Set it. Forget it. Restore it.",
        "Backup that's tested before you need it.",
        "Backups with a restore button that works.",
        "Your last line of defense, automated.",
    ],
    "hero_heads": [
        "Backups you'll never have to think about",
        "Automatic backups, verified restores",
        "The backup service with receipts",
        "Sleep through the disk failure",
        "Every file, every version, every night",
    ],
    "hero_subs": [
        "Continuous or scheduled backups of files, databases and configs, with automated restore tests that email you proof.",
        "Back up machines, databases and containers over encrypted channels; restore whole systems or single files in minutes.",
        "Immutable, versioned, off-site backups with cryptographic verification — the boring kind of safety that actually restores.",
        "Agent-based backups for servers and laptops alike: deduped, encrypted, incremental forever, with bare-metal restore media on demand.",
    ],
    "features": [
        _feat("clock", "Continuous backup", "Changes upload as they happen (or on your schedule) — the RPO is minutes, not last night."),
        _feat("shield", "Immutable history", "Retention-locked versions even a compromised admin account can't delete — ransomware can't encrypt what it can't touch."),
        _feat("cpu", "Automated restore tests", "Nightly test-restores of your latest backups with an emailed receipt; an untested backup is a hope, not a backup."),
        _feat("server", "Files, DBs & containers", "Agents cover plain files, MySQL/Postgres/Mongo and volume-level container backups with consistent snapshots."),
        _feat("lock", "Zero-knowledge option", "Client-side encryption with keys you hold; we store opaque blocks and can't read a byte of your data."),
        _feat("zap", "Global deduplication", "Identical blocks store once across all your machines — typical environments see 60-80% storage savings."),
        _feat("download", "Granular restore", "Restore a whole server, one database, or a single file from any point in the retention window — from the same archive."),
        _feat("layers", "Bare-metal recovery", "Bootable restore media for physical machines: boot, point at the archive, walk away for coffee."),
        _feat("globe", "Multi-region copies", "Every backup replicates to a second region by default; enable a third with a toggle and a clear price."),
        _feat("users", "Team policies", "Organization-wide policies: retention tiers per device class, quota alerts and per-team restore permissions."),
        _feat("chart", "Coverage dashboard", "One screen shows every protected machine, last success, verification status and storage trend — no spreadsheet archaeology."),
        _feat("code", "API & CLI", "Script everything: trigger backups, verify jobs and restore files from CI or your own tooling."),
    ],
    "steps": [
        ("Install the agent", "One command (or one .msi) per machine; the agent auto-registers and starts the first full backup."),
        ("Define the policy", "Schedules, retention and encryption per device class — sensible defaults mean you can accept and walk away."),
        ("Restore anything", "Single files or whole systems from any point in time; nightly test-restores prove it works."),
    ],
    "faq": [
        ("How long does the first backup take?",
         "Depends on data size and line speed; after that, incremental forever — only changed blocks move, deduped across machines."),
        ("Can I back up databases live?",
         "Yes: consistent snapshots for MySQL, Postgres and MongoDB without stopping writes; the agent handles the plumbing."),
        ("What's the retention model?",
         "Keep everything forever, or tiered: 30 daily, 12 monthly, 7 yearly — configurable per policy, with immutable lock as an option."),
        ("Is my data encrypted in transit and at rest?",
         "TLS in transit, AES-256 at rest, and an optional zero-knowledge mode where encryption happens on your machine first."),
        ("How fast are restores?",
         "Whole-server restores run at disk-limited speed (typically 300 MB/s+ per stream); single files appear in the browser within seconds."),
        ("What if I exceed my quota?",
         "Backups continue; you get alerts at 80% and 100% and a grace period before any pruning, so a spike never silently drops history."),
    ],
    "stat_set": ["pb", "files", "uptime", "retention", "users"],
    "table": {
        "title": "Recently verified restores",
        "note": "Automated nightly test-restores from the last 24 hours.",
        "cols": [("Machine", "hostname"), ("Type", "backtype"), ("Size", "size"), ("Verified", "ago"), ("Owner", "user")],
    },
    "formats": ["img", "vhd", "qcow2", "sql", "tar", "gz"],
}

CATEGORY_ORDER = [
    "fileshare", "imagehost", "videoedit", "pastebin", "converter",
    "shortener", "cloud", "screenshot", "codehost", "analytics",
    "uptime", "archive", "notes", "backup",
]
# ----------------------------------------------------------------------------
# 8. Тарифы, датасеты, отзывы, юридические данные
# ----------------------------------------------------------------------------

PLAN_NAMES = [
    "Free", "Starter", "Basic", "Plus", "Pro", "Team", "Business",
    "Premium", "Max", "Scale", "Enterprise",
]
PLAN_BILLING = [("monthly", 3), ("yearly", 2)]


def _money(v):
    if v == 0:
        return "Free"
    if v % 1 == 0:
        return "$%d" % int(v)
    return "$%.2f" % v


def build_plans(rng, pack):
    """2-4 тарифа с ценами и фичами, специфичными для категории."""
    n = rng.randint(3, 4)
    names = [PLAN_NAMES[0]]
    # не берём подряд идущие имена, а случайные «взрослые»
    adult = [x for x in PLAN_NAMES[1:-1] if x != "Free"]
    picked = rng.sample(adult, n - 2)
    names += picked
    names.append("Enterprise") if rng.maybe(0.45) else names.append(rng.choice(["Scale", "Max", "Ultimate"]))
    has_free = True
    prices = [0]
    base = rng.choice([3, 4, 5, 6, 7, 8, 9, 12, 15, 19, 24, 29])
    step = rng.choice([2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 40])
    for i in range(1, len(names)):
        prices.append(base + step * i)
    yearly = [0] + [max(1, int(round(p * rng.randint(80, 92) / 100.0))) for p in prices[1:]]
    free_limits = {
        "fileshare": "%s per transfer" % rng.choice(["2 GB", "5 GB", "10 GB"]),
        "imagehost": "%s per image, %s monthly" % (rng.choice(["10 MB", "20 MB", "32 MB"]), rng.choice(["1 GB", "2 GB", "5 GB"])),
        "videoedit": "%s storage, 720p export" % rng.choice(["5 GB", "10 GB"]),
        "pastebin": "%s per paste" % rng.choice(["512 KB", "1 MB"]),
        "converter": "%s per file, 25 conversions/day" % rng.choice(["100 MB", "200 MB"]),
        "shortener": "1,000 links, 30-day analytics",
        "cloud": "%s storage" % rng.choice(["5 GB", "10 GB", "15 GB"]),
        "screenshot": "%s per shot, 90-day history" % rng.choice(["8 MB", "10 MB"]),
        "codehost": "Unlimited private repos, 5 collaborators",
        "analytics": "10k pageviews/month, 1 site",
        "uptime": "10 monitors, 60-second checks",
        "archive": "250 snapshots/month",
        "notes": "200 synced notes, 50 MB attachments",
        "backup": "1 machine, %s" % rng.choice(["50 GB", "100 GB"]),
    }
    pro_limits = {
        "fileshare": "%s transfers, no caps" % rng.choice(["100 GB", "250 GB", "1 TB"]),
        "imagehost": "Unlimited bandwidth, %s per image" % rng.choice(["50 MB", "100 MB"]),
        "videoedit": "%s storage, 4K export, GPU rendering" % rng.choice(["500 GB", "1 TB", "2 TB"]),
        "pastebin": "%s per paste, edit history" % rng.choice(["10 MB", "25 MB", "50 MB"]),
        "converter": "%s per file, batch mode, no watermark" % rng.choice(["2 GB", "5 GB", "10 GB"]),
        "shortener": "Unlimited links, custom domains",
        "cloud": "%s storage, version history" % rng.choice(["1 TB", "2 TB", "5 TB"]),
        "screenshot": "Unlimited shots, team collections",
        "codehost": "Unlimited collaborators, %s CI minutes" % rng.choice(["6,000", "10,000", "25,000"]),
        "analytics": "Unlimited pageviews, funnels, alerts",
        "uptime": "Unlimited monitors, 30-second checks",
        "archive": "%s snapshots, WARC export" % rng.choice(["10,000", "25,000", "Unlimited"]),
        "notes": "Unlimited notes, E2E encryption",
        "backup": "%s pooled, unlimited machines" % rng.choice(["1 TB", "2 TB", "5 TB"]),
    }
    plans = []
    for i, (name, price, yprice) in enumerate(zip(names, prices, yearly)):
        if i == 0:
            lim = free_limits.get(pack["id"], "Core features")
            feats = [lim, "Community support", "API access"]
        elif i == len(names) - 1:
            lim = "Everything in %s, plus:" % names[i - 1]
            feats = [lim, "SSO & audit logs", "Dedicated support", "Custom contracts (SLA)"]
        else:
            lim = pro_limits.get(pack["id"], "Higher limits")
            feats = [lim, "Priority support", "Advanced sharing controls",
                     "Version history %s" % rng.choice(["30 days", "90 days", "1 year"])]
            if rng.maybe(0.5):
                feats.append(rng.choice(["Team workspaces", "Custom domains", "API rate boost", "Webhooks"]))
        plans.append({
            "name": name, "price": price, "yearly": yprice,
            "features": feats, "highlight": (i == 1),
        })
    return plans


TESTIMONIAL_TPL = [
    ("quote", "We replaced three tools with {brand} in a single afternoon. The {noun} just work, and the dashboard never makes me guess.",
     "roles"),
    ("quote", "Our team moves {stat} a week through {brand}. Support answers in minutes, and the API made our automation trivial.",
     "roles"),
    ("quote", "I tested every alternative before settling here. {brand} is the only one that didn't get in my way — the {noun} are exactly where you expect them.",
     "roles"),
    ("quote", "The free plan alone solved my problem; we upgraded because it deserved it, not because it nagged us to.",
     "roles"),
    ("quote", "Uptime matters more than features for us, and {brand} has been rock solid since we switched {months} months ago.",
     "roles"),
    ("quote", "Onboarding a client used to take an hour of explanations. With {brand} it's a link and one sentence.",
     "roles"),
    ("quote", "The export button actually exports everything. That sentence alone should tell you what we dealt with before.",
     "roles"),
    ("quote", "Fast, honest pricing, no dark patterns. Rare combination in this space.",
     "roles"),
]


def build_testimonials(rng, pack, brand, n=3):
    out = []
    used = set()
    for _ in range(n):
        tpl = rng.choice(TESTIMONIAL_TPL)
        person = make_person(rng)
        months = rng.randint(4, 26)
        stat = rng.choice(["terabytes", "hundreds of files", "thousands of links"])
        while person["full"] in used:
            person = make_person(rng)
        used.add(person["full"])
        text = tpl[1].format(brand=brand, noun=pack["noun"], stat=stat, months=months)
        out.append({"person": person, "text": text})
    return out


# --- датасеты: правдоподобные строки таблиц --------------------------------

WORDS_TECHY = [
    "final", "v2", "backup", "untitled", "draft", "export", "render", "master",
    "copy", "old", "new", "test", "report", "archive", "summer", "q3", "q4",
    "project", "alpha", "beta", "release", "promo", "demo", "sample", "logo",
    "banner", "intro", "outro", "cut", "scene", "take", "shot", "raw",
]
WORDS_TOPIC = [
    "invoice", "contract", "presentation", "budget", "resume", "portfolio",
    "screenshot", "photo", "wallpaper", "meme", "avatar", "poster", "flyer",
    "recipe", "notes", "meeting", "lecture", "playlist", "podcast", "trailer",
    "dataset", "backup", "config", "schema", "migration", "log", "dump",
]
EXT_BY_CAT = {
    "fileshare": ["zip", "rar", "7z", "tar.gz", "mp4", "mkv", "iso", "psd", "pdf", "dmg"],
    "imagehost": ["png", "jpg", "webp", "gif", "avif"],
    "videoedit": ["mp4", "mov", "mkv", "prproj", "fcpxml"],
    "pastebin": ["txt", "md", "log", "json"],
    "converter": ["pdf", "docx", "epub", "mp3", "wav", "csv", "png"],
    "shortener": [],
    "cloud": ["docx", "xlsx", "pdf", "jpg", "mp4", "zip"],
    "screenshot": ["png", "jpg", "gif", "mp4"],
    "codehost": ["git", "zip"],
    "analytics": [],
    "uptime": [],
    "archive": ["warc", "html", "pdf"],
    "notes": ["md", "txt"],
    "backup": ["img", "sql", "tar", "vhd"],
}
PAGE_PATHS = [
    "/", "/pricing", "/about", "/docs", "/blog", "/changelog", "/help",
    "/blog/scaling-2026", "/docs/getting-started", "/blog/release-3-2",
    "/features", "/download", "/integrations", "/status",
]
SITE_LIKE = [
    "acrobat-portal", "brick-studio", "cedar-analytics", "dune-consulting",
    "ember-games", "flux-widget", "granite-bank", "harbor-lab",
    "indigo-shop", "jade-media", "kite-tracking", "lumen-festival",
    "maple-hardware", "nimbus-weather", "orbit-agency", "pine-notes",
    "quartz-museum", "ridge-farms", "sable-security", "tidal-radio",
    "umbra-cinema", "vela-shipping", "willow-clinic", "xenon-lights",
    "yonder-travel", "zephyr-boards", "atlas-print", "beacon-press",
]
HOSTNAMES = [
    "web%02d", "app%02d", "db%02d", "build%02d", "mail%02d", "cache%02d",
    "backup%02d", "api%02d", "ci%02d", "edge%02d", "store%02d", "git%02d",
]
NOTE_TITLES = [
    "Reading list — {month}", "Meeting notes {month} sync", "Recipe: {dish}",
    "Book notes: {book}", "Ideas for side projects", "Workout plan v{n}",
    "Trip plan: {city2}", "Interview questions bank", "Server maintenance checklist",
    "Drafts for the announcement post", "Home lab inventory", "Language learning log",
]
NOTE_DISHES = ["miso ramen", "shakshuka", "carbonara", "borscht", "khachapuri", "pho"]
NOTE_BOOKS = [
    "Thinking in Systems", "The Pragmatic Programmer", "Deep Work",
    "Designing Data-Intensive Applications", "The Mom Test", "Shape Up",
]
REPO_NAMES = [
    "dotfiles", "blog-engine", "cli-%s" % "tool", "hello-%s" % "world",
    "awesome-list", "homelab", "leetcode", "advent-of-code", "personal-site",
    "flappy-clone", "raytracer", "toy-compiler", "kanban-tui", "weather-cli",
]
CONV_FROM = ["PDF", "DOCX", "PNG", "MP4", "WEBM", "EPUB", "MP3", "SVG", "XLSX", "HEIC"]
CONV_TO = ["PDF", "DOCX", "PNG", "WEBP", "MP4", "MP3", "EPUB", "TXT", "CSV", "AVIF"]
REPO_LANGS = ["Python", "TypeScript", "Rust", "Go", "C++", "Lua", "Zig", "Elixir", "Kotlin", "Shell"]
PASTE_LANGS = ["plaintext", "python", "javascript", "bash", "json", "yaml", "sql", "markdown", "rust", "go", "diff"]
TLD_LIST_FOR_DOMAINS = [".com", ".io", ".net", ".dev", ".app", ".org", ".co", ".xyz"]


def _ago(rng):
    units = [("minute", 60), ("hour", 24), ("day", 30), ("day", 400)]
    u = rng.weighted([("minute", 3), ("hour", 4), ("day", 5)])
    if u == "minute":
        return "%d minutes ago" % rng.randint(2, 59)
    if u == "hour":
        return "%d hours ago" % rng.randint(1, 23)
    return "%d days ago" % rng.randint(1, 21)


def _slug(rng, n=None):
    n = n or rng.randint(4, 8)
    return Rng.token(rng, n + 3)


def dataset_row(rng, kind):
    """Одна строка таблицы «свежих данных» по типу колонки."""
    person = make_person(rng)
    size = rng.randint(20, 95000) * rng.choice([1024, 4096])
    if kind == "filename":
        ext = rng.choice(EXT_BY_CAT.get(rng.choice(list(EXT_BY_CAT)), ["zip"]) or ["zip"])
        base = rng.choice(WORDS_TECHY + WORDS_TOPIC)
        if rng.maybe(0.4):
            base += "-%s" % rng.choice(WORDS_TECHY[:10])
        if rng.maybe(0.3):
            base += str(rng.randint(2, 9))
        return "%s.%s" % (base, ext)
    if kind == "title":
        w = rng.choice(WORDS_TECHY + WORDS_TOPIC)
        if rng.maybe(0.5):
            w += " %s" % rng.choice(["notes", "final", "draft", "v%d" % rng.randint(2, 5)])
        return w.capitalize()
    if kind == "notetitle":
        t = rng.choice(NOTE_TITLES)
        return t.format(
            month=rng.choice(["January", "March", "April", "June", "September", "November"]),
            dish=rng.choice(NOTE_DISHES), book=rng.choice(NOTE_BOOKS),
            n=rng.randint(2, 4), city2=rng.choice(["Lisbon", "Tbilisi", "Osaka", "Kyiv", "Bergen"]),
        )
    if kind == "size":
        return human_size(size)
    if kind == "count":
        return human_count(rng.randint(12, 4800000))
    if kind == "ago":
        return _ago(rng)
    if kind == "user":
        return rng.choice([person["handle"], person["full"]])
    if kind == "dims":
        return "%d×%d" % (rng.choice([640, 800, 1024, 1280, 1920, 2560]),
                          rng.choice([360, 480, 600, 720, 1080, 1440]))
    if kind == "duration":
        m, s = rng.randint(0, 14), rng.randint(0, 59)
        return "%02d:%02d" % (m, s)
    if kind == "res":
        return rng.choice(["720p", "1080p", "1440p", "4K"])
    if kind == "lang":
        return rng.choice(PASTE_LANGS + REPO_LANGS)
    if kind == "slug":
        return _slug(rng)
    if kind == "dest":
        site = rng.choice(SITE_LIKE)
        tld = rng.choice(TLD_LIST_FOR_DOMAINS)
        path = rng.choice(PAGE_PATHS)
        return "https://%s%s%s" % (site, tld, path)
    if kind == "convjob":
        return "%s → %s" % (rng.choice(["report", "slides", "photo", "video", "track", "book", "scan"]) + rng.choice(["", "-final", "-v2", str(rng.randint(2, 9))]),
                            rng.choice(CONV_TO).lower())
    if kind == "convdir":
        return "%s → %s" % (rng.choice(CONV_FROM), rng.choice(CONV_TO))
    if kind == "secs":
        return "%d s" % rng.randint(2, 240)
    if kind == "foldername":
        return rng.choice(["Projects", "Photos 2026", "Invoices", "team-assets",
                           "backups", "client-work", "screenshots", "music",
                           "renders", "scans"]) + rng.choice(["", "-%d" % rng.randint(2, 9), " final"])
    if kind == "reponame":
        return rng.choice(REPO_NAMES) + rng.choice(["", "-%d" % rng.randint(2, 9), "2"])
    if kind == "sitename":
        return rng.choice(SITE_LIKE) + rng.choice(TLD_LIST_FOR_DOMAINS)
    if kind == "page":
        return rng.choice(PAGE_PATHS)
    if kind == "trend":
        return rng.choice(["+12%", "+4%", "+31%", "−2%", "+8%", "+57%", "flat"])
    if kind == "status":
        return rng.choice(["degraded", "down", "maintenance"])
    if kind == "region":
        return rng.choice(["eu-central", "us-east", "us-west", "ap-south",
                           "ap-northeast", "sa-east", "eu-north"])
    if kind == "pagetitle":
        site = rng.choice(SITE_LIKE)
        return "%s%s — %s" % (site, rng.choice(TLD_LIST_FOR_DOMAINS),
                              rng.choice(["pricing page", "announcement", "docs index",
                                          "changelog", "terms of service", "homepage"]))
    if kind == "domain":
        return rng.choice(SITE_LIKE) + rng.choice(TLD_LIST_FOR_DOMAINS)
    if kind == "hostname":
        return rng.choice(HOSTNAMES) % rng.randint(1, 42)
    if kind == "backtype":
        return rng.choice(["full system", "postgres", "mysql", "folder", "vm image", "docker volumes"])
    if kind == "tags":
        return ", ".join(rng.sample(["work", "ideas", "reading", "personal", "draft",
                                      "research", "urgent", "someday", "home",
                                      "finance", "travel"], rng.randint(2, 3)))
    raise ValueError("unknown kind: %s" % kind)


def build_table(rng, pack, n=None):
    """Датасет-таблица «последних активностей» для главной страницы."""
    spec = pack["table"]
    n = n or rng.randint(5, 8)
    rows = []
    for _ in range(n):
        row = []
        for _, kind in spec["cols"]:
            if kind == "count":
                row.append(human_count(rng.randint(3, 240000)))
            elif kind == "size":
                row.append(human_size(rng.randint(40, 880000) * 1024))
            else:
                row.append(dataset_row(rng, kind))
        rows.append(row)
    return {"title": spec["title"], "note": spec["note"], "cols": spec["cols"], "rows": rows}


def build_stats(rng, pack):
    kinds = pack["stat_set"]
    chosen = rng.sample(kinds, min(4, len(kinds)))
    stats = []
    for k in chosen:
        label, fn = STAT_KINDS[k]
        stats.append({"value": fn(rng), "label": label})
    return stats


def build_legal(rng, brand, tld):
    """Юридические данные: компания, адрес, даты документов."""
    city = rng.choice(CITIES)
    parts = city.split(", ")
    company = "%s %s" % (brand, rng.choice(LEGAL_FORMS))
    return {
        "company": company,
        "city": city,
        "country": parts[-1] if len(parts) > 1 else parts[0],
        "address": "%d %s St., %s" % (rng.randint(2, 240),
                                       rng.choice(["Oak", "Maple", "Cedar", "Birch",
                                                   "Aspen", "Elm", "Pine", "Fir"]),
                                       city),
        "email": "support@%s%s" % (brand.lower(), tld),
        "abuse_email": "abuse@%s%s" % (brand.lower(), tld),
        "legal_email": "legal@%s%s" % (brand.lower(), tld),
        "founded": rng.randint(2016, 2024),
        "updated_terms": rng.date_between(2025, 2026).isoformat(),
        "updated_privacy": rng.date_between(2025, 2026).isoformat(),
        "reg_no": "REG %d-%04d" % (rng.randint(100000, 999999), rng.randint(1, 9999)),
        "hours": rng.choice(SUPPORT_HOURS),
    }


# ----------------------------------------------------------------------------
# 9. Модель сайта: собирает всё в один профиль
# ----------------------------------------------------------------------------

class Site(object):
    def __init__(self, seed):
        self.seed = seed
        rng = Rng(seed)
        self.rng = rng
        self._fmt_rng = rng.spawn("fmt")
        # категория и бренд
        self.pack_id = rng.choice(CATEGORY_ORDER)
        self.pack = PACKS[self.pack_id]
        prng = rng.spawn("brand")
        self.brand, self.tld = make_brand(prng, self.pack)
        self.domain = (self.brand.lower() + self.tld)
        # дизайн
        drng = rng.spawn("design")
        self.design = Design(drng)
        self.tone = rng.choice(list(TONES.keys()))
        # текстовые значения для подстановок
        self.freesize = rng.choice(["2 GB", "5 GB", "10 GB"])
        self.maxsize = rng.choice(["25 GB", "50 GB", "100 GB"])
        self.freegb = rng.choice(["5", "10", "15"])
        self.freegbmax = "25 GB"
        self.formats_n = rng.randint(180, 400)
        # контент
        self.plans = build_plans(rng.spawn("plans"), self.pack)
        self.testimonials = build_testimonials(rng.spawn("tmon"), self.pack, self.brand)
        self.stats = build_stats(rng.spawn("stats"), self.pack)
        self.table = build_table(rng.spawn("table"), self.pack)
        self.legal = build_legal(rng.spawn("legal"), self.brand, self.tld)
        self.people = [make_person(rng.spawn("p%d" % i)) for i in range(rng.randint(3, 5))]
        self.faq = self._build_faq()
        self.features = self._build_features()
        self.year = 2026
        # готовые текстовые блоки (форматирование один раз, до любого рендера)
        self.tagline = self._fmt(rng.choice(self.pack["taglines"]))
        self.hero_head = self._fmt(rng.choice(self.pack["hero_heads"]))
        self.hero_sub = self._fmt(rng.choice(self.pack["hero_subs"]))
        self.steps = [(self._fmt(t), self._fmt(d)) for t, d in self.pack["steps"]]
        self.tone_obj = TONES[self.tone]
        self.cta = self._fmt_tone(rng.choice(self.tone_obj["cta"]))
        self.cta2 = self._fmt_tone(rng.choice(self.tone_obj["cta2"]))
        self.eyebrow = self._fmt_tone(rng.choice(self.tone_obj["eyebrow"]))
        self.footer_note = self._fmt_tone(rng.choice(self.tone_obj["footer"]))
        self.about_open = self._fmt_tone(rng.choice(self.tone_obj["about_open"]))
        # SVG-активы
        arng = rng.spawn("assets")
        self.logo_svg = svg_logo(arng, self.design, self.brand)
        self.favicon_svg = svg_favicon(self.design, self.brand, arng)
        self.hero_mock = svg_app_window(arng, self.design, self.brand,
                                        self._mock_kind())
        self.gallery = [svg_placeholder(arng, self.design,
                                         rng.choice([320, 360, 400, 480]),
                                         rng.choice([200, 220, 240, 270]),
                                         self.brand)
                        for _ in range(rng.randint(4, 6))]
        self.avatars = {p["full"]: svg_avatar(arng, self.design, p["initials"]) for p in self.people}
        self.chart = svg_chart(arng, self.design, 320, 150)
        self.meta_desc = self._meta_desc()

    def _mock_kind(self):
        return {
            "fileshare": "table", "imagehost": "gallery", "videoedit": "editor",
            "pastebin": "table", "converter": "table", "shortener": "generic",
            "cloud": "generic", "screenshot": "gallery", "codehost": "table",
            "analytics": "generic", "uptime": "generic", "archive": "table",
            "notes": "generic", "backup": "generic",
        }[self.pack_id]

    def _meta_desc(self):
        tag = self.pack["taglines"][0]
        return "%s %s" % (self.brand, tag[0].lower() + tag[1:])

    def _build_faq(self):
        frng = self.rng.spawn("faq")
        cat = [(q, a) for q, a in self.pack["faq"]]
        gen = [(q, a) for q, a in GENERIC_FAQ]
        chosen = frng.sample(cat, min(5, len(cat)))
        if frng.maybe(0.75):
            chosen += frng.sample(gen, frng.randint(1, 2))
        frng.shuffle(chosen)
        return [(q, self._fmt(a)) for q, a in chosen]

    def _build_features(self):
        frng = self.rng.spawn("feats")
        feats = list(self.pack["features"])
        n = frng.choice([6, 6, 8, 9, 12])
        chosen = frng.sample(feats, min(n, len(feats)))
        out = []
        for f in chosen:
            out.append({"icon": f["icon"], "title": f["title"],
                        "desc": self._fmt(f["desc"])})
        return out

    def _fmt(self, text):
        return text.format(
            brand=self.brand, domain=self.domain, label=self.pack["label"],
            noun=self.pack["noun"], freesize=self.freesize, maxsize=self.maxsize,
            freegb=self.freegb, freegbmax=self.freegbmax, formats=self.formats_n,
            year=self.legal["founded"], region=self.legal["city"],
            slug=_slug(self._fmt_rng, 5),
        )

    def _fmt_tone(self, text):
        return text.format(brand=self.brand, label=self.pack["label"],
                           year=self.legal["founded"], region=self.legal["city"])


def rng_choice(rng, seq):
    return rng.choice(seq)


# ----------------------------------------------------------------------------
# 10. CSS-движок: рандомизированные имена классов, порядок правил, форматы цветов
# ----------------------------------------------------------------------------

# Логические имена -> CSS-классы сайта. Порядок фиксирован (нужен для карты),
# фактические имена и порядок вывода правил рандомизируются.
# STATE_CLASSES — статические имена состояний (добавляются/снимаются JS-ом):
# они одинаковы на всех сайтах и в карту не входят.
STATE_CLASSES = {"open", "on", "show", "legal_h", "toggle-check", "tab-active"}
CLASS_SPECS = [
    "root", "body", "container", "nav", "nav_inner", "nav_brand", "nav_logo",
    "nav_links", "nav_link", "nav_cta", "hero", "hero_inner", "hero_copy",
    "hero_eyebrow", "hero_title", "hero_sub", "hero_actions", "btn",
    "btn_primary", "btn_ghost", "hero_visual", "stats", "stat", "stat_value",
    "stat_label", "section", "section_head", "section_title", "section_sub",
    "features", "feature", "feature_icon", "feature_title", "feature_desc",
    "steps", "step", "step_num", "table_wrap", "table", "pricing", "plan",
    "plan_name", "plan_price", "plan_features", "plan_highlight", "faq",
    "faq_item", "faq_q", "faq_a", "testimonials", "testimonial", "quote",
    "avatar", "footer", "footer_cols", "footer_col", "footer_link", "badge",
    "chip", "input", "label", "form", "auth_card", "auth_wrap", "muted",
    "grid2", "grid3", "grid4", "legal", "legal_toc", "code_block", "kicker",
    "tag_row", "divider", "notfound", "gallery", "gallery_item", "alert",
    "toggle", "cookie", "lang", "status_page", "uptime_bar", "notice",
]


class CssNamer(object):
    """Даёт каждому логическому классу случайное короткое имя.

    Стиль имени (по сиду): .kv-3f9a / .u7Kz / .c-a1b2 / .w_x9 …
    """

    STYLES = ["kv", "u3", "dash", "und"]

    def __init__(self, rng):
        self.style = rng.choice(self.STYLES)
        self.map = {}
        used = set()
        for logical in CLASS_SPECS:
            while True:
                name = self._make(rng)
                if name not in used and not name[0].isdigit():
                    break
            used.add(name)
            self.map[logical] = name
        # синонимы: btn_primary == cta и т.п. остаются независимыми

    def _make(self, rng):
        alpha = "abcdefghijklmnopqrstuvwxyz"
        if self.style == "kv":
            return rng.choice(["k", "v", "s", "c", "h", "u", "r"]) + "-" + rng.token(4)
        if self.style == "u":
            return "u" + rng.token(4)
        if self.style == "dash":
            return rng.choice(alpha) + "-" + rng.token(3)
        return rng.choice(alpha) + "_" + rng.token(3)

    def __call__(self, logical):
        return self.map[logical]


def _css_color(rng, c):
    """Вариативная запись одного цвета: #hex / #HEX / rgb() — микро-отпечаток CSS.
    Не-hex значения (rgba(...) и т.п.) пропускает как есть."""
    if not c.startswith("#"):
        return c
    r = rng.random()
    if r < 0.55:
        return c
    if r < 0.7:
        return c.upper()
    rgb = hex_to_rgb(c)
    return "rgb(%d,%d,%d)" % rgb if rng.maybe(0.5) else "rgb(%d, %d, %d)" % rgb


class CssBuilder(object):
    """Собирает CSS: значения из Design, имена из CssNamer, порядок правил
    из RNG. Правила группируются по «блокам» (reset, layout, components),
    порядок блоков и правил внутри блока перемешивается."""

    def __init__(self, rng, design, namer, site):
        self.rng = rng
        self.d = design
        self.n = namer
        self.s = site
        self.pal = design.pal

    def col(self, c):
        return _css_color(self.rng, c)

    # --- крупные блоки -------------------------------------------------------
    def block_reset(self):
        n = self.n
        return [
            (":root", "--border:%s;--surface:%s;--bg:%s;--text:%s;--accent:%s" %
             (self.col(self.pal["border"]), self.col(self.pal["surface"]),
              self.col(self.pal["bg"]), self.col(self.pal["text"]), self.col(self.pal["accent"]))),
            ("*", "box-sizing:border-box;margin:0;padding:0"),
            (n("body"), "font-family:%s;font-size:%dpx;line-height:1.6;color:%s;background:%s;-webkit-font-smoothing:antialiased" %
             (self.d.type_pair["body"], self.d.body_size, self.col(self.pal["text"]), self.col(self.pal["bg"]))),
            ("img,svg", "max-width:100%;height:auto;display:block"),
            ("a", "color:%s;text-decoration:%s" % (self.col(self.pal["accent"]),
                                                   "underline" if self.d.link_underline else "none")),
            ("h1,h2,h3,h4", "font-family:%s;font-weight:%d;line-height:1.15;letter-spacing:%s;color:%s" %
             (self.d.type_pair["head"], self.d.head_weight, self.d.head_tracking, self.col(self.pal["text"]))),
            ("button,input,select,textarea", "font:inherit;color:inherit"),
        ]

    def block_layout(self):
        n, d = self.n, self.d
        rules = [
            (n("container"), "width:100%%;max-width:%dpx;margin:0 auto;padding:0 24px" % d.container),
            (n("section"), "padding:%dpx 0" % d.section_pad),
            (n("section_head"), "max-width:640px;margin:0 auto %dpx;text-align:center" % (d.section_pad // 2)),
            (n("section_title"), "font-size:clamp(1.5rem,3.2vw,2.1rem);margin-bottom:12px"),
            (n("section_sub"), "color:%s" % self.col(self.pal["muted"])),
            (n("grid2"), "display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px"),
            (n("grid3"), "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:24px"),
            (n("grid4"), "display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px"),
            (n("divider"), "border:0;border-top:1px solid %s;margin:%dpx 0" % (self.col(self.pal["border"]), d.section_pad // 2)),
            (n("muted"), "color:%s" % self.col(self.pal["muted"])),
        ]
        return rules

    def block_nav(self):
        n, d = self.n, self.d
        pos = "position:sticky;top:0;z-index:50" if d.nav_sticky else "position:relative"
        rules = [
            (n("nav"), "%s;background:%s;border-bottom:1px solid %s;backdrop-filter:blur(8px)" %
             (pos, self.col(self._nav_bg()), self.col(self.pal["border"]))),
            (n("nav_inner"), "display:flex;align-items:center;gap:32px;height:64px"),
            (n("nav_brand"), "display:flex;align-items:center;gap:10px;font-family:%s;font-weight:%d;font-size:1.15rem;color:%s;text-decoration:none" %
             (d.type_pair["head"], d.head_weight, self.col(self.pal["text"]))),
            (n("nav_links"), "display:flex;gap:%dpx;margin-left:auto;list-style:none" % self.rng.choice([18, 22, 26, 32])),
            (n("nav_link"), "color:%s;text-decoration:none;font-size:.95rem;opacity:.85" % self.col(self.pal["text"])),
            (n("nav_link") + ":hover", "opacity:1;color:%s" % self.col(self.pal["accent"])),
            (n("nav_cta"), "margin-left:%dpx" % self.rng.choice([8, 12, 16])),
        ]
        m = "@media (max-width:840px){.%s{display:none}.%s{height:60px;gap:14px}.%s{display:none}.%s{padding:9px 14px;font-size:.88rem}}" % (
            n("nav_links"), n("nav_inner"), n("nav_cta"), n("btn"))
        rules.append(("@media-nav", m))
        return rules

    def _nav_bg(self):
        # полупрозрачная плашка поверх фона: работает и в тёмной, и в светлой
        if self.d.is_dark:
            c = hex_to_rgb(self.pal["surface"])
            return "rgba(%d,%d,%d,.88)" % c
        c = hex_to_rgb(self.pal["surface"])
        return "rgba(%d,%d,%d,.86)" % c

    def block_hero(self):
        n, d = self.n, self.d
        pattern = self._hero_bg()
        rules = [
            (n("hero"), "padding:%dpx 0 %dpx;background:%s%s;border-bottom:1px solid %s" %
             (d.section_pad, d.section_pad // 2, self.col(self.pal["bg"]), pattern, self.col(self.pal["border"]))),
            (n("hero_inner"), "display:grid;grid-template-columns:1fr;gap:40px;align-items:center"),
            (n("hero_copy"), "min-width:0"),
            (n("hero_eyebrow"), "display:inline-block;font-size:.8rem;font-weight:600;letter-spacing:.08em;text-transform:%s;color:%s;background:%s;padding:6px 12px;border-radius:%dpx;border:1px solid %s" %
             ("uppercase" if d.eyebrow_caps else "none", self.col(self.pal["accent"]),
              self.col(d.accent_soft), min(d.radius, 999) if d.radius else 0, self.col(self.pal["border"]))),
            (n("hero_title"), "font-size:clamp(2rem,5.2vw,3.4rem);margin:18px 0 16px;max-width:21ch"),
            (n("hero_sub"), "font-size:clamp(1rem,1.6vw,1.2rem);color:%s;max-width:56ch;margin-bottom:28px" % self.col(self.pal["muted"])),
            (n("hero_actions"), "display:flex;gap:14px;flex-wrap:wrap"),
            (n("hero_visual"), "margin-top:12px;box-shadow:%s;border-radius:%dpx;overflow:hidden;border:1px solid %s" %
             (d.shadow[1], min(d.radius, 14) or 2, self.col(self.pal["border"]))),
            ("@media-hero", "@media (min-width:960px){.%s{grid-template-columns:1.05fr .95fr}.%s{margin-top:0}}" %
             (n("hero_inner"), n("hero_visual"))),
        ]
        return rules

    def _hero_bg(self):
        p = self._hero_pattern_css()
        return ";background-image:%s" % p if p else ""

    def _hero_pattern_css(self):
        pat = self.d.hero_pattern
        pal = self.pal
        if pat == "grid":
            line = mix(pal["border"], pal["accent"], 0.25)
            return "linear-gradient(%s 1px,transparent 1px),linear-gradient(90deg,%s 1px,transparent 1px)" % (line, line) + \
                   ";background-size:44px 44px"
        if pat == "dots":
            dotc = mix(pal["accent"], pal["muted"], 0.4)
            return "radial-gradient(%s 1px,transparent 1px)" % dotc + ";background-size:26px 26px"
        if pat == "glow":
            return "radial-gradient(600px 300px at 20%% 0%%,%s,transparent 70%%),radial-gradient(700px 320px at 85%% 10%%,%s,transparent 70%%)" % (
                self.d.hero_grad_a, self.d.hero_grad_b)
        if pat == "rings":
            ring = mix(pal["accent"], pal["bg"], 0.55)
            return "repeating-radial-gradient(circle at 85%% 20%%,transparent 0,transparent %dpx,%s %dpx,%s %dpx)" % (
                self.rng.randint(18, 30), ring, self.rng.randint(18, 30) + 2, "transparent", self.rng.randint(36, 60))
        return ""

    def block_buttons(self):
        n, d = self.n, self.d
        pal = self.pal
        base = "display:inline-flex;align-items:center;gap:8px;padding:%s;border-radius:%s;font-weight:600;font-size:.95rem;text-decoration:none;cursor:pointer;border:1px solid transparent;transition:transform .12s ease,box-shadow .12s ease" % (
            self.rng.choice(["10px 18px", "11px 20px", "12px 22px", "10px 22px"]),
            "999px" if d.btn == "pill" else "%dpx" % (d.radius if d.radius else 2),
        )
        rules = []
        if d.btn == "gradient":
            prim = "background:linear-gradient(135deg,%s,%s);color:%s" % (
                self.col(pal["accent"]), self.col(pal["accent2"]), self.col(pal["on_accent"]))
        else:
            prim = "background:%s;color:%s" % (self.col(pal["accent"]), self.col(pal["on_accent"]))
        if d.btn == "outline":
            prim = "background:transparent;color:%s;border-color:%s" % (
                self.col(pal["accent"]), self.col(pal["accent"]))
        rules.append((n("btn_primary"), "%s;%s" % (base, prim)))
        rules.append((n("btn_primary") + ":hover", "transform:translateY(-1px)"))
        ghost = "background:transparent;color:%s;border-color:%s" % (
            self.col(pal["text"]), self.col(self.pal["border"]))
        rules.append((n("btn_ghost"), "%s;%s" % (base, ghost)))
        rules.append((n("btn_ghost") + ":hover", "border-color:%s;color:%s" % (
            self.col(pal["accent"]), self.col(pal["accent"]))))
        rules.append((n("btn") + ":active", "transform:translateY(0)"))
        return rules

    def block_cards(self):
        n, d = self.n, self.d
        pal = self.pal
        rules = [
            (n("feature"), "background:%s;border:1px solid %s;border-radius:%dpx;padding:%s;box-shadow:%s;transition:border-color .15s ease,transform .15s ease" %
             (self.col(pal["surface"]), self.col(pal["border"]), d.radius or 2,
              self.rng.choice(["20px 22px", "24px", "22px 26px"]), d.shadow[1])),
            (n("feature") + ":hover", "border-color:%s;transform:translateY(-2px)" % self.col(mix(pal["accent"], pal["border"], 0.45))),
            (n("feature_icon"), "width:42px;height:42px;display:flex;align-items:center;justify-content:center;border-radius:%dpx;background:%s;color:%s;margin-bottom:14px" %
             (min(d.radius, 12) or 4, self.col(d.accent_soft), self.col(pal["accent"]))),
            (n("feature_title"), "font-size:1.05rem;margin-bottom:8px;font-weight:600"),
            (n("feature_desc"), "color:%s;font-size:.93rem" % self.col(pal["muted"])),
            (n("stat"), "text-align:center;padding:18px 12px"),
            (n("stat_value"), "font-family:%s;font-size:clamp(1.6rem,3vw,2.2rem);font-weight:%d;color:%s" %
             (d.type_pair["head"], d.head_weight, self.col(pal["accent"]))),
            (n("stat_label"), "color:%s;font-size:.85rem;margin-top:4px" % self.col(pal["muted"])),
        ]
        return rules

    def block_table(self):
        n, d = self.n, self.d
        pal = self.pal
        return [
            (n("table_wrap"), "overflow-x:auto;border:1px solid %s;border-radius:%dpx;background:%s" %
             (self.col(pal["border"]), d.radius or 2, self.col(pal["surface"]))),
            (n("table"), "width:100%%;border-collapse:collapse;font-size:%s" % self.rng.choice([".88rem", ".9rem", ".92rem"])),
            ("th,td", "text-align:left;padding:%s;border-bottom:1px solid %s;white-space:nowrap" %
             (self.rng.choice(["10px 16px", "12px 18px"]), self.col(mix(pal["border"], pal["bg"], 0.35)))),
            ("th", "color:%s;font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.06em" % self.col(pal["muted"])),
            ("tbody tr:last-child td", "border-bottom:0"),
            ("tbody tr:hover td", "background:%s" % self.col(mix(pal["surface"], pal["accent"], 0.06))),
        ]

    def block_pricing(self):
        n, d = self.n, self.d
        pal = self.pal
        rules = [
            (n("plan"), "background:%s;border:1px solid %s;border-radius:%dpx;padding:28px;display:flex;flex-direction:column;position:relative" %
             (self.col(pal["surface"]), self.col(pal["border"]), d.radius or 2)),
            (n("plan_name"), "font-size:1rem;font-weight:600;margin-bottom:10px"),
            (n("plan_price"), "font-family:%s;font-size:2.3rem;font-weight:%d;margin-bottom:%dpx" %
             (d.type_pair["head"], d.head_weight, self.rng.choice([10, 14, 18]))),
            (n("plan_features"), "list-style:none;display:grid;gap:10px;font-size:.92rem;color:%s;margin-bottom:24px" % self.col(pal["muted"])),
            (n("plan_features") + " li", "padding-left:24px;position:relative"),
            (n("plan_features") + " li::before", "content:'';position:absolute;left:0;top:.35em;width:14px;height:14px;border-radius:50%%;background:%s" %
             self.col(d.accent_soft)),
        ]
        hl = n("plan_highlight")
        rules.append((hl, "border-color:%s;box-shadow:0 0 0 1px %s,%s" % (
            self.col(pal["accent"]), self.col(pal["accent"]), d.shadow[1])))
        rules.append((hl + "::before", "content:'%s';position:absolute;top:-11px;left:50%%;transform:translateX(-50%%);background:%s;color:%s;font-size:.72rem;font-weight:700;letter-spacing:.06em;padding:4px 12px;border-radius:%s" % (
            "MOST POPULAR", self.col(pal["accent"]), self.col(pal["on_accent"]),
            "999px" if d.btn == "pill" else "%dpx" % (min(d.radius, 8) or 2))))
        return rules

    def block_faq(self):
        n, d = self.n, self.d
        pal = self.pal
        return [
            (n("faq"), "max-width:760px;margin:0 auto"),
            (n("faq_item"), "border:1px solid %s;border-radius:%dpx;background:%s;margin-bottom:12px;overflow:hidden" %
             (self.col(pal["border"]), d.radius or 2, self.col(pal["surface"]))),
            (n("faq_q"), "width:100%%;display:flex;justify-content:space-between;align-items:center;gap:16px;padding:%s;background:none;border:0;text-align:left;font-weight:600;font-size:1rem;cursor:pointer;color:%s" %
             (self.rng.choice(["14px 18px", "16px 20px"]), self.col(pal["text"]))),
            (n("faq_a"), "padding:0 %s %s;color:%s;font-size:.95rem;display:none" %
             (self.rng.choice(["18px", "20px"]), self.rng.choice(["16px", "18px", "20px"]), self.col(pal["muted"]))),
            (n("faq_item") + ".open " + n("faq_a"), "display:block"),
            (n("faq_item") + ".open " + n("faq_q") + " svg", "transform:rotate(180deg)"),
            (n("faq_q") + " svg", "transition:transform .18s ease;flex:none;color:%s" % self.col(pal["muted"])),
        ]

    def block_testimonials(self):
        n, d = self.n, self.d
        pal = self.pal
        return [
            (n("testimonial"), "background:%s;border:1px solid %s;border-radius:%dpx;padding:24px;display:flex;flex-direction:column;gap:16px" %
             (self.col(pal["surface"]), self.col(pal["border"]), d.radius or 2)),
            (n("quote"), "font-size:1rem;line-height:1.55;color:%s" % self.col(pal["text"])),
            (n("quote") + "::before", "content:'\\201C';font-family:Georgia,serif;font-size:2.6rem;line-height:0;vertical-align:-0.35em;margin-right:6px;color:%s" % self.col(pal["accent"])),
            (n("avatar"), "border-radius:50%%;flex:none"),
        ]

    def block_forms(self):
        n, d = self.n, self.d
        pal = self.pal
        return [
            (n("auth_wrap"), "min-height:70vh;display:flex;align-items:center;justify-content:center;padding:40px 0"),
            (n("auth_card"), "width:100%%;max-width:%dpx;background:%s;border:1px solid %s;border-radius:%dpx;padding:%s;box-shadow:%s" %
             (self.rng.choice([380, 400, 420, 440]), self.col(pal["surface"]), self.col(pal["border"]),
              d.radius or 2, self.rng.choice(["28px 32px", "32px", "36px 40px"]), d.shadow[1])),
            (n("form"), "display:grid;gap:16px;margin-top:20px"),
            (n("label"), "font-size:.85rem;font-weight:600;color:%s" % self.col(pal["text"])),
            (n("input"), "width:100%%;padding:%s;background:%s;border:1px solid %s;border-radius:%s;color:%s;font-size:.95rem" %
             (self.rng.choice(["10px 14px", "11px 15px", "12px 16px"]), self.col(pal["bg"]),
              self.col(pal["border"]), "%dpx" % (min(d.radius, 10) or 2), self.col(pal["text"]))),
            (n("input") + ":focus", "outline:2px solid %s;outline-offset:1px;border-color:%s" %
             (self.col(mix(pal["accent"], pal["bg"], 0.6)), self.col(pal["accent"]))),
            (n("alert"), "display:none;padding:12px 16px;border-radius:%dpx;font-size:.9rem;border:1px solid %s;background:%s;color:%s" %
             (d.radius or 2, self.col(mix(pal["bad"], pal["bg"], 0.7)),
              self.col(mix(pal["bad"], pal["bg"], 0.88)), self.col(pal["bad"]))),
            (n("alert") + ".show", "display:block"),
        ]

    def block_footer(self):
        n, d = self.n, self.d
        pal = self.pal
        rules = [
            (n("footer"), "border-top:1px solid %s;background:%s;padding:%dpx 0 32px;margin-top:%dpx" %
             (self.col(pal["border"]), self.col(mix(pal["bg"], pal["surface"], 0.5)),
              d.section_pad // 2, d.section_pad)),
            (n("footer_cols"), "display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:32px;margin-bottom:28px"),
            (n("footer_col") + " h4", "font-size:.8rem;text-transform:uppercase;letter-spacing:.07em;color:%s;margin-bottom:12px" %
             self.col(pal["muted"])),
            (n("footer_link"), "display:block;color:%s;text-decoration:none;font-size:.9rem;padding:4px 0" % self.col(mix(pal["text"], pal["muted"], 0.35))),
            (n("footer_link") + ":hover", "color:%s" % self.col(pal["accent"])),
        ]
        return rules

    def block_misc(self):
        n, d = self.n, self.d
        pal = self.pal
        return [
            (n("badge"), "display:inline-flex;align-items:center;gap:6px;font-size:.75rem;font-weight:600;padding:4px 10px;border-radius:%s;border:1px solid %s;color:%s" %
             ("999px" if self.rng.maybe(0.6) else "%dpx" % (min(d.radius, 8) or 2), self.col(pal["border"]), self.col(pal["muted"]))),
            (n("chip"), "display:inline-block;font-family:%s;font-size:.78rem;background:%s;color:%s;border-radius:%s;padding:3px 10px;margin:2px" %
             (d.type_pair["mono"], self.col(d.accent2_soft), self.col(pal["accent2"]), "999px")),
            (n("kicker"), "font-size:.8rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:%s" % self.col(pal["accent"])),
            (n("steps"), "display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:24px;counter-reset:step"),
            (n("step"), "position:relative;padding-left:56px"),
            (n("step_num"), "position:absolute;left:0;top:0;width:40px;height:40px;border-radius:50%%;background:%s;color:%s;display:flex;align-items:center;justify-content:center;font-weight:700;font-family:%s" %
             (self.col(pal["accent"]), self.col(pal["on_accent"]), d.type_pair["head"])),
            (n("code_block"), "font-family:%s;font-size:.85rem;background:%s;border:1px solid %s;border-radius:%dpx;padding:16px 18px;overflow-x:auto;color:%s" %
             (d.type_pair["mono"], self.col(darken(pal["bg"], 0.15) if d.is_dark else mix(pal["bg"], pal["text"], 0.06)),
              self.col(pal["border"]), d.radius or 2,
              self.col(mix(pal["muted"], pal["text"], 0.4)))),
            (n("notfound"), "text-align:center;padding:%dpx 0" % (d.section_pad * 2)),
            (n("notfound") + " h1", "font-family:%s;font-size:clamp(5rem,14vw,9rem);font-weight:%d;line-height:1;color:%s" %
             (d.type_pair["head"], d.head_weight, self.col(pal["accent"]))),
            (n("gallery"), "display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px"),
            (n("gallery_item"), "border-radius:%dpx;overflow:hidden;border:1px solid %s" % (d.radius or 2, self.col(pal["border"]))),
            (n("legal"), "max-width:760px;margin:0 auto;font-size:.95rem"),
            (n("legal_toc"), "background:%s;border:1px solid %s;border-radius:%dpx;padding:20px 26px;margin-bottom:32px;font-size:.9rem" %
             (self.col(pal["surface"]), self.col(pal["border"]), d.radius or 2)),
            ("h2.legal_h", "font-size:1.25rem;margin:36px 0 12px"),
            (n("legal") + " p, " + n("legal") + " li", "margin-bottom:12px;color:%s" % self.col(mix(pal["text"], pal["muted"], 0.25))),
            (n("legal") + " ul", "padding-left:22px"),
            (n("toggle"), "width:44px;height:24px;border-radius:12px;background:%s;position:relative;cursor:pointer;border:0;flex:none" % self.col(mix(pal["border"], pal["muted"], 0.3))),
            (n("toggle") + "::after", "content:'';position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%%;background:%s;transition:left .15s ease" % self.col(pal["surface"])),
            (n("toggle") + ".on::after", "left:23px"),
            (n("toggle") + ".on", "background:%s" % self.col(pal["accent"])),
            (n("notice"), "background:%s;border:1px solid %s;border-radius:%dpx;padding:14px 18px;font-size:.9rem;color:%s" %
             (self.col(d.accent_soft), self.col(mix(pal["accent"], pal["border"], 0.4)), d.radius or 2, self.col(pal["text"]))),
        ]

    # --- сборка -------------------------------------------------------------
    def _sel(self, sel):
        """Добавляет '.' к токенам-классам: имена из карты намера становятся
        класс-селекторами, элементные селекторы не трогаются."""
        names = set(self.n.map.values())

        def fix_token(tok):
            core = tok.split(":")[0].split("[")[0]
            if core and core in names:
                return "." + tok
            return tok

        parts_out = []
        for part in sel.split(","):
            parts_out.append(" ".join(fix_token(t) for t in part.split()))
        return ",".join(parts_out)

    def build(self):
        blocks = {
            "reset": self.block_reset,
            "layout": self.block_layout,
            "nav": self.block_nav,
            "hero": self.block_hero,
            "buttons": self.block_buttons,
            "cards": self.block_cards,
            "table": self.block_table,
            "pricing": self.block_pricing,
            "faq": self.block_faq,
            "testimonials": self.block_testimonials,
            "forms": self.block_forms,
            "footer": self.block_footer,
            "misc": self.block_misc,
        }
        names = list(blocks.keys())
        self.rng.shuffle(names)
        out = []
        for name in names:
            rules = blocks[name]()
            self.rng.shuffle(rules)
            for sel, body in rules:
                if sel.startswith("@media"):
                    out.append(body)
                else:
                    out.append("%s{%s}" % (self._sel(sel), body))
        return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------
# 11. HTML-рендер: каркас и страницы
# ----------------------------------------------------------------------------

NAV_PAGES = [
    ("Features", "/#features"),
    ("Pricing", "/pricing/"),
    ("FAQ", "/faq/"),
    ("About", "/about/"),
]


class Renderer(object):
    def __init__(self, site, namer, css):
        self.s = site
        self.n = namer
        self.css = css
        self.prng = site.rng.spawn("pages")   # поток выбора вариантов страниц
        self.frng = site.rng.spawn("fragmt")  # поток фрагментов (порядок секций)

    # --- базовые фрагменты ---------------------------------------------------
    def head(self, title, desc, path):
        s = self.s
        n = self.n
        canonical = "https://%s%s" % (s.domain, path)
        return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<meta name="description" content="%s">
<link rel="canonical" href="%s">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/assets/style.css">
<meta property="og:type" content="website">
<meta property="og:site_name" content="%s">
<meta property="og:title" content="%s">
<meta property="og:description" content="%s">
<meta property="og:url" content="%s">
<meta name="twitter:card" content="summary_large_image">
</head>
<body class="%s">""" % (
            esc(title), esc(desc), canonical, esc(s.brand), esc(title), esc(desc), canonical,
            esc(n("body")))

    def nav(self, active=None):
        s, n = self.s, self.n
        links = []
        for label, href in NAV_PAGES:
            cls = n("nav_link") + (" tab-active" if label == active else "")
            links.append('<li><a class="%s" href="%s">%s</a></li>' % (cls, href, label))
        login_cls = n("nav_link")
        return """<header class="%s">
<div class="%s">
<a class="%s" href="/">%s<span>%s</span></a>
<ul class="%s">%s</ul>
<a class="%s %s" href="/login/">Log in</a>
<a class="%s %s" href="/signup/">%s</a>
</div>
</header>""" % (n("nav"), n("nav_inner"), n("nav_brand"), s.logo_svg, esc(s.brand),
                n("nav_links"), "".join(links), login_cls, n("nav_cta"),
                n("btn") + " " + n("btn_primary"), n("nav_cta"), esc(s.cta))

    def footer(self):
        s, n = self.s, self.n
        year = s.year
        cols = [
            ("Product", [("Features", "/#features"), ("Pricing", "/pricing/"),
                         ("FAQ", "/faq/"), ("Changelog", "/#changelog")]),
            ("Company", [("About", "/about/"), ("Status", "/status/"),
                         ("Terms", "/terms/"), ("Privacy", "/privacy/")]),
            ("Resources", [("API docs", "/#api"), ("Support", "mailto:%s" % s.legal["email"]),
                           ("Abuse", "mailto:%s" % s.legal["abuse_email"]),
                           ("Security", "/.well-known/security.txt")]),
        ]
        cols_html = []
        for title, items in cols:
            lis = "".join('<a class="%s" href="%s">%s</a>' % (n("footer_link"), href, esc(t))
                          for t, href in items)
            cols_html.append('<div class="%s"><h4>%s</h4>%s</div>' % (n("footer_col"), esc(title), lis))
        return """<footer class="%s">
<div class="%s">
<div class="%s">
%s
</div>
<div class="%s">
<span>%s</span>
<span class="%s">%s · %s</span>
</div>
</div>
</footer>
<script src="/assets/app.js" defer></script>
</body>
</html>""" % (n("footer"), n("container"), n("footer_cols"), "".join(cols_html),
              n("muted"), esc(s.footer_note.replace("{brand}", s.brand)),
              n("muted"), "© %d %s" % (year, esc(s.legal["company"])),
              esc(s.legal["city"]))

    # --- секции главной ------------------------------------------------------
    def hero(self):
        s, n = self.s, self.n
        return """<section class="%s">
<div class="%s">
<div class="%s">
<span class="%s">%s</span>
<h1 class="%s">%s</h1>
<p class="%s">%s</p>
<div class="%s">
<a class="%s %s" href="/signup/">%s</a>
<a class="%s %s" href="/pricing/">%s</a>
</div>
</div>
<div class="%s">%s</div>
</div>
</section>""" % (n("hero"), n("container"), n("hero_copy"), n("hero_eyebrow"),
                 esc(s.eyebrow), n("hero_title"), esc(s.hero_head), n("hero_sub"),
                 esc(s.hero_sub), n("hero_actions"),
                 n("btn"), n("btn_primary"), esc(s.cta),
                 n("btn"), n("btn_ghost"), esc(s.cta2), n("hero_visual"), s.hero_mock)

    def stats(self):
        s, n = self.s, self.n
        items = "".join('<div class="%s"><div class="%s">%s</div><div class="%s">%s</div></div>' %
                        (n("stat"), n("stat_value"), esc(x["value"]), n("stat_label"), esc(x["label"]))
                        for x in s.stats)
        return '<section class="%s"><div class="%s"><div class="%s">%s</div></div></section>' % (
            n("section"), n("container"), n("grid4"), items)

    def features(self):
        s, n = self.s, self.n
        cards = []
        for f in s.features:
            cards.append("""<div class="%s">
<div class="%s">%s</div>
<h3 class="%s">%s</h3>
<p class="%s">%s</p>
</div>""" % (n("feature"), n("feature_icon"), icon(f["icon"], 22),
             n("feature_title"), esc(f["title"]), n("feature_desc"), esc(f["desc"])))
        grid = n("grid3") if len(s.features) % 3 == 0 else n("grid2")
        return """<section class="%s" id="features">
<div class="%s">
<div class="%s">
<h2 class="%s">Everything %s does</h2>
<p class="%s">%s</p>
</div>
%s
</div>
</section>""" % (n("section"), n("container"), n("section_head"), n("section_title"),
                 esc(s.brand), n("section_sub"),
                 esc("Built for people who %s daily — no bloat, no dark patterns." % s.pack["label"]),
                 ('<div class="%s">%s</div>' % (grid, "".join(cards))))

    def steps(self):
        s, n = self.s, self.n
        items = []
        for i, (t, d) in enumerate(s.steps, 1):
            items.append('<div class="%s"><div class="%s">%d</div><h3>%s</h3><p class="%s">%s</p></div>' %
                         (n("step"), n("step_num"), i, esc(t), n("muted"), esc(d)))
        return """<section class="%s">
<div class="%s">
<div class="%s"><h2 class="%s">How it works</h2></div>
<div class="%s">%s</div>
</div>
</section>""" % (n("section"), n("container"), n("section_head"), n("section_title"),
                 n("steps"), "".join(items))

    def data_table(self):
        s, n = self.s, self.n
        t = s.table
        ths = "".join("<th>%s</th>" % esc(c[0]) for c in t["cols"])
        trs = []
        for row in t["rows"]:
            tds = "".join("<td>%s</td>" % esc(v) for v in row)
            trs.append("<tr>%s</tr>" % tds)
        return """<section class="%s">
<div class="%s">
<div class="%s"><h2 class="%s">%s</h2><p class="%s">%s</p></div>
<div class="%s"><table class="%s">
<thead><tr>%s</tr></thead>
<tbody>%s</tbody>
</table></div>
</div>
</section>""" % (n("section"), n("container"), n("section_head"), n("section_title"),
                 esc(t["title"]), n("section_sub"), esc(t["note"]),
                 n("table_wrap"), n("table"), ths, "".join(trs))

    def pricing_cards(self, yearly=False):
        s, n = self.s, self.n
        cards = []
        for p in s.plans:
            cls = n("plan") + (" " + n("plan_highlight") if p["highlight"] else "")
            price = _money(p["yearly"] if yearly else p["price"])
            suffix = "/mo" if p["price"] else ""
            period = "billed yearly" if yearly else "billed monthly"
            lis = "".join("<li>%s</li>" % esc(f) for f in p["features"])
            btn = n("btn") + " " + (n("btn_primary") if p["highlight"] else n("btn_ghost"))
            label = "Start free" if p["price"] == 0 else "Choose %s" % p["name"]
            cards.append("""<div class="%s">
<h3 class="%s">%s</h3>
<div class="%s">%s<span class="%s">%s</span></div>
<ul class="%s">%s</ul>
<a class="%s" href="/signup/?plan=%s">%s</a>
</div>""" % (cls, n("plan_name"), esc(p["name"]), n("plan_price"), price,
             n("muted"), suffix and (period + " " + suffix or "") or "", n("plan_features"), lis,
             btn, esc(p["name"].lower()), esc(label)))
        return '<div class="%s">%s</div>' % (n("grid3"), "".join(cards))

    def pricing_section(self):
        s, n = self.s, self.n
        yearly = self.prng.maybe(0.4)
        return """<section class="%s" id="pricing">
<div class="%s">
<div class="%s"><h2 class="%s">Simple pricing</h2><p class="%s">No setup fees, cancel anytime, and your data exports in one click.</p></div>
%s
<p class="%s" style="text-align:center;margin-top:24px">All prices in USD. VAT may apply based on your billing country.</p>
</div>
</section>""" % (n("section"), n("container"), n("section_head"), n("section_title"),
                 n("section_sub"), self.pricing_cards(yearly), n("muted"))

    def testimonials(self):
        s, n = self.s, self.n
        cards = []
        for t in s.testimonials:
            av = s.avatars.get(t["person"]["full"], "")
            cards.append("""<div class="%s">
<p class="%s">%s</p>
<div style="display:flex;align-items:center;gap:12px">
%s
<div><div style="font-weight:600;font-size:.92rem">%s</div><div class="%s" style="font-size:.85rem">%s</div></div>
</div>
</div>""" % (n("testimonial"), n("quote"), esc(t["text"]), av,
             esc(t["person"]["full"]), n("muted"), esc(t["person"]["role"])))
        return """<section class="%s">
<div class="%s">
<div class="%s"><h2 class="%s">People like it</h2><p class="%s">Unedited quotes from the in-app feedback widget.</p></div>
<div class="%s">%s</div>
</div>
</section>""" % (n("section"), n("container"), n("section_head"), n("section_title"),
                 n("section_sub"), n("grid3"), "".join(cards))

    def cta_band(self):
        s, n = self.s, self.n
        return """<section class="%s">
<div class="%s" style="text-align:center;max-width:640px">
<h2 class="%s">Ready when you are</h2>
<p class="%s" style="margin-bottom:24px">%s</p>
<a class="%s %s" href="/signup/">%s</a>
</div>
</section>""" % (n("section"), n("container"), n("section_title"),
                 n("section_sub"), esc(s.tagline), n("btn"), n("btn_primary"), esc(s.cta))

    def changelog_section(self):
        s, n = self.s, self.n
        crng = s.rng.spawn("changelog")
        items = []
        versions = ["3.2.1", "3.2.0", "3.1.4", "3.1.0", "3.0.0"]
        descs = [
            "Faster uploads in Europe (up to 30% on large {noun})",
            "Redesigned dashboard with keyboard navigation",
            "New API endpoints for {noun} management",
            "Fixed a rare failure when handling very long filenames",
            "Dark mode improvements and contrast fixes",
            "Performance: page weight reduced by 41 KB",
        ]
        for v in versions[:crng.randint(3, 4)]:
            d = crng.choice(descs).format(noun=s.pack["noun"])
            dt = crng.date_between(2026, 2026).isoformat()
            items.append('<div style="padding:14px 0;border-bottom:1px solid var(--border)"><strong>v%s</strong> <span class="%s">— %s</span><div>%s</div></div>' %
                         (v, n("muted"), dt, d))
        return """<section class="%s" id="changelog">
<div class="%s">
<div class="%s"><h2 class="%s">Changelog</h2><p class="%s">We ship weekly. Highlights below.</p></div>
%s
</div>
</section>""" % (n("section"), n("container"), n("section_head"), n("section_title"),
                 n("section_sub"), "".join(items))

    # --- страницы ------------------------------------------------------------
    def page_index(self):
        n = self.n
        # порядок секций варьируется (кроме hero и cta)
        middle = [self.features, self.steps, self.data_table, self.pricing_section,
                  self.testimonials, self.changelog_section]
        self.frng.shuffle(middle)
        # stats всегда сразу после hero
        parts = [self.hero(), self.stats()] + [fn() for fn in middle] + [self.cta_band()]
        return self.head("%s — %s" % (self.s.brand, self.s.tagline), self.s.meta_desc, "/") + \
            self.nav() + "".join(parts) + self.footer()

    def page_pricing(self):
        s, n = self.s, self.n
        faq_link = '<p class="%s" style="margin-top:20px">Questions about plans? <a href="/faq/">Read the FAQ</a> or write to <a href="mailto:%s">%s</a>.</p>'
        body = """<main class="%s">
<section class="%s">
<div class="%s">
<h1 class="%s" style="font-size:clamp(1.8rem,4vw,2.6rem);margin-bottom:12px">Pricing that scales with you</h1>
<p class="%s">Start free, upgrade when you hit the limits. No hidden fees, no per-seat traps for viewers.</p>
</div>
%s
%s
</section>
</main>""" % (n("container"), n("section"), n("section_head"), n("section_title"),
              n("section_sub"), self.pricing_cards(False), faq_link % (n("muted"), s.legal["email"], s.legal["email"]))
        return self.head("Pricing — %s" % s.brand, "Pricing plans for %s. %s" % (s.brand, s.tagline), "/pricing/") + \
            self.nav("Pricing") + body + self.footer()

    def page_about(self):
        s, n = self.s, self.n
        people_cards = []
        for p in s.people:
            av = s.avatars.get(p["full"], "")
            people_cards.append("""<div style="display:flex;gap:14px;align-items:center;padding:14px 0;border-bottom:1px solid var(--border)">
%s
<div><div style="font-weight:600">%s</div><div class="%s">%s</div></div>
</div>""" % (av, esc(p["full"]), n("muted"), esc(p["role"])))
        body = """<main class="%s">
<section class="%s">
<div class="%s" style="max-width:720px">
<h1 class="%s" style="font-size:clamp(1.8rem,4vw,2.6rem);margin-bottom:20px">About %s</h1>
<p style="margin-bottom:16px">%s</p>
<p style="margin-bottom:16px" class="%s">Today %s serves customers in %d countries from offices in %s. We're %d people, profitable since %d, and answer our own support inbox.</p>
<p class="%s">We build %s tools because we use them ourselves, every single day. If that sounds like a team you'd like to join, check the careers note at the bottom of this page.</p>
</div>
</section>
<section class="%s">
<div class="%s">
<div class="%s"><h2 class="%s">The team</h2><p class="%s">Small on purpose. Everyone ships.</p></div>
<div class="%s">%s</div>
</div>
</section>
</main>""" % (n("container"), n("section"), n("container"), n("section_title"), esc(s.brand),
              esc(s.about_open), n("muted"), esc(s.brand), 40 + s.rng.randrange(150), esc(s.legal["city"]),
              4 + s.rng.randrange(20), s.legal["founded"] + s.rng.randrange(0, 3), n("muted"),
              esc(s.pack["label"]), n("section"), n("container"), n("section_head"),
              n("section_title"), n("section_sub"), n("grid2"),
              "".join('<div class="%s">%s</div>' % (n("feature"), c) for c in people_cards))
        return self.head("About — %s" % s.brand, "About %s: the team behind %s." % (s.brand, s.brand), "/about/") + \
            self.nav("About") + body + self.footer()

    def page_faq(self):
        s, n = self.s, self.n
        items = []
        for q, a in s.faq:
            items.append("""<div class="%s">
<button class="%s" type="button" aria-expanded="false">%s%s</button>
<div class="%s"><p>%s</p></div>
</div>""" % (n("faq_item"), n("faq_q"), esc(q), icon("chevron-d", 18), n("faq_a"), esc(a)))
        body = """<main class="%s">
<section class="%s">
<div class="%s" style="max-width:760px;margin:0 auto">
<h1 class="%s" style="font-size:clamp(1.8rem,4vw,2.6rem);margin-bottom:12px;text-align:center">Frequently asked questions</h1>
<p class="%s" style="text-align:center;margin-bottom:40px">Everything people ask before signing up. Yours not here? <a href="mailto:%s">Write to us</a>.</p>
%s
</div>
</section>
</main>""" % (n("container"), n("section"), n("container"), n("section_title"),
              n("section_sub"), s.legal["email"], "".join(items))
        return self.head("FAQ — %s" % s.brand, "Frequently asked questions about %s." % s.brand, "/faq/") + \
            self.nav("FAQ") + body + self.footer()

    def page_terms(self):
        return self._legal_page("terms", "Terms of Service", [
            ("Acceptance of terms", "By accessing {domain} (the \"Service\") you agree to these Terms. If you do not agree, do not use the Service. We may update these Terms; material changes are announced on this page 30 days in advance."),
            ("Your account", "You are responsible for activity under your account and for keeping credentials safe. One person or entity per account; sharing seats requires a team plan. You must be at least 16 years old, or the age of digital consent in your country if higher."),
            ("Acceptable use", "You may not use the Service to distribute malware, content that infringes copyright, or material unlawful in the hosting jurisdiction ({country}). We disable access to reported content while reviewing. Full policy in the Abuse section below."),
            ("Your content", "You retain all rights to content you upload. You grant us a limited license to store, transfer and process it strictly to operate the Service. The license ends when you delete the content."),
            ("Availability & refunds", "We target 99.9% monthly availability but the Service is provided \"as is\" without warranty of uninterrupted function. Refunds are handled per the policy on the Pricing page; statutory rights are unaffected."),
            ("Termination", "You may close your account anytime from Settings. We may suspend accounts for non-payment or violations of the Acceptable Use clause, with notice where legally possible."),
            ("Liability", "To the maximum extent permitted by law, our aggregate liability is limited to the fees you paid in the 12 months before the claim. Nothing limits liability for intent, gross negligence or statutory duties."),
            ("Governing law", "These Terms are governed by the laws of {country}, without regard to conflict-of-law rules. Disputes go to the competent courts of {city} unless consumer law grants you your local forum."),
        ])

    def page_privacy(self):
        return self._legal_page("privacy", "Privacy Policy", [
            ("What we collect", "Account data (email, hashed password), billing metadata handled by our payment provider, technical logs (IP truncated after 30 days, user agent, timestamps) and the content you store, which is processed only to operate the Service."),
            ("Why we process it", "To provide the Service (contract), to secure it and prevent abuse (legitimate interest), to meet legal obligations, and — with your consent — for product emails. No advertising, no data sales, no third-party trackers."),
            ("Cookies", "One session cookie and one preference cookie (both necessary). No analytics cookies. Where consent banners are required for non-necessary cookies, you'll see them; we run none."),
            ("Retention", "Account data until 30 days after deletion. Logs 90 days (truncated IPs after 30). Backups roll off within 35 days. Legal holds excepted."),
            ("Your rights", "Access, rectification, export, erasure, restriction and objection — email {email} and we respond within 30 days. EU/UK residents may lodge a complaint with their supervisory authority."),
            ("Processors", "Payment processing (PCI-DSS provider), email delivery, and cloud hosting in {city}. All processors are bound by DPAs; the current list is available on request."),
            ("International transfers", "Data may be processed outside your region under SCCs where required. You can pin your primary storage region at signup."),
            ("Children", "The Service is not directed at children under 16. We delete underage accounts and their data on notice."),
        ])

    def _legal_page(self, kind, title, sections):
        s, n = self.s, self.n
        L = s.legal
        values = {
            "domain": esc(s.domain), "country": esc(L["country"]),
            "city": esc(L["city"]), "email": esc(L["email"]),
            "company": esc(L["company"]), "address": esc(L["address"]),
        }

        def sub(text):
            return text.format(**values)

        toc = "".join('<li><a href="#%s">%s</a></li>' % (sec_title_slug(t), esc(t)) for t, _ in sections)
        body_sections = []
        for t, txt in sections:
            body_sections.append('<h2 id="%s" class="legal_h">%s</h2><p>%s</p>' %
                                  (sec_title_slug(t), esc(t), sub(txt)))
        updated = L["updated_terms"] if kind == "terms" else L["updated_privacy"]
        body = """<main class="%s">
<section class="%s">
<div class="%s" style="max-width:760px;margin:0 auto">
<h1 style="font-size:clamp(1.8rem,4vw,2.6rem);margin-bottom:8px">%s</h1>
<p class="%s">Last updated: %s · Operator: %s, %s</p>
<div class="%s"><strong>Contents</strong><ol style="margin-top:8px;padding-left:18px">%s</ol></div>
%s
</div>
</section>
</main>""" % (n("container"), n("section"), n("container"), esc(title), n("muted"),
              updated, esc(L["company"]), esc(L["address"]), n("legal_toc"), toc,
              "".join(body_sections))
        return self.head("%s — %s" % (title, s.brand), "%s for %s." % (title, s.brand),
                         "/%s/" % kind) + self.nav() + body + self.footer()

    def page_login(self):
        s, n = self.s, self.n
        return self._auth_page("login", "Welcome back", "Log in to your %s account." % esc(s.brand),
                               "Log in", True)

    def page_signup(self):
        s, n = self.s, self.n
        return self._auth_page("signup", "Create your account", "Free plan, no credit card. %s" % esc(s.tagline),
                               "Sign up", False)

    def _auth_page(self, kind, title, sub, button, show_forgot):
        s, n = self.s, self.n
        extra = ""
        if kind == "signup":
            extra = """<div>
<label class="%s" for="f-name">Full name</label>
<input class="%s" id="f-name" name="name" type="text" autocomplete="name" required>
</div>""" % (n("label"), n("input"))
        forgot = ""
        if show_forgot:
            forgot = '<div style="text-align:right"><a class="%s" href="#" data-forgot style="font-size:.85rem">Forgot password?</a></div>' % n("footer_link")
        other = ("/login/" if kind == "signup" else "/signup/")
        other_label = "Log in" if kind == "signup" else "Create an account"
        other_text = ("Already have an account?" if kind == "signup" else "New to %s?" % esc(s.brand))
        body = """<main class="%s">
<div class="%s">
<div class="%s" style="text-align:center;margin-bottom:24px">%s</div>
<div class="%s">
<h1 style="font-size:1.5rem;margin-bottom:6px">%s</h1>
<p class="%s">%s</p>
<form class="%s" id="auth-form" data-kind="%s" novalidate>
%s
<div>
<label class="%s" for="f-email">Email</label>
<input class="%s" id="f-email" name="email" type="email" autocomplete="email" required>
</div>
<div>
<div style="display:flex;justify-content:space-between;align-items:baseline">
<label class="%s" for="f-pass">Password</label>
%s
</div>
<input class="%s" id="f-pass" name="password" type="password" autocomplete="%s" minlength="8" required>
</div>
<div class="%s" id="form-alert" role="alert">%s</div>
<button class="%s %s" type="submit" style="justify-content:center;width:100%%">%s</button>
</form>
<p class="%s" style="text-align:center;margin-top:18px;font-size:.9rem">%s <a href="%s">%s</a></p>
</div>
</div>
</main>""" % (n("container"), n("auth_wrap"), n("nav_brand"),
              s.logo_svg, n("auth_card"), esc(title), n("muted"), esc(sub),
              n("form"), kind, extra, n("label"), n("input"), n("label"), forgot,
              n("input"), "new-password" if kind == "signup" else "current-password",
              n("alert"), "Placeholder message — enable JavaScript for a demo response.",
              n("btn"), n("btn_primary"), esc(button), n("muted"), other_text, other, other_label)
        path = "/%s/" % kind
        return self.head("%s — %s" % (title, s.brand), sub, path) + self.nav() + body + self.footer()

    def page_404(self):
        s, n = self.s, self.n
        body = """<main class="%s">
<div class="%s">
<h1>404</h1>
<p style="font-size:1.1rem;margin:16px 0 28px" class="%s">This page took the day off. The link may be old, mistyped, or the %s was deleted.</p>
<a class="%s %s" href="/">Back to %s</a>
</div>
</main>""" % (n("container"), n("notfound"), n("muted"), esc(s.pack["noun"]),
              n("btn"), n("btn_primary"), "the homepage")
        return self.head("Page not found — %s" % s.brand, "404 — this page does not exist at %s." % s.brand, "/404/") + \
            self.nav() + body + self.footer()

    def page_status(self):
        s, n = self.s, self.n
        srng = s.rng.spawn("status")
        comps = []
        comp_names = ["Web app", "API", "Uploads", "Downloads", "Dashboard", "Webhooks"]
        for c in comp_names:
            state = srng.weighted([("ok", 8), ("warn", 1)])
            color = s.design.pal["ok"] if state == "ok" else s.design.pal["warn"]
            label = "Operational" if state == "ok" else "Degraded"
            bar = "".join('<span style="flex:1;height:26px;border-radius:3px;background:%s;opacity:.9"></span>' %
                          (color if srng.maybe(0.93) else s.design.pal["border"]) for _ in range(30))
            comps.append("""<div style="display:flex;justify-content:space-between;align-items:center;gap:16px;padding:12px 0;border-bottom:1px solid var(--border)">
<div><strong>%s</strong><div class="%s" style="font-size:.85rem">%s</div></div>
<div style="display:flex;gap:2px;width:280px;max-width:40%%">%s</div>
</div>""" % (esc(c), n("muted"), label, bar))
        body = """<main class="%s">
<section class="%s">
<div class="%s" style="max-width:760px;margin:0 auto">
<div style="display:flex;align-items:center;gap:10px;margin-bottom:8px">
<span style="width:10px;height:10px;border-radius:50%%;background:%s;display:inline-block"></span>
<h1 style="font-size:1.4rem">All systems operational</h1>
</div>
<p class="%s" style="margin-bottom:32px">Uptime over the last 90 days · %s</p>
%s
<p class="%s" style="margin-top:24px;font-size:.85rem">History updated every 5 minutes. Incidents are announced here and via email to subscribers.</p>
</div>
</section>
</main>""" % (n("container"), n("section"), n("container"), s.design.pal["ok"],
              n("muted"), esc(s.stats[1]["value"] if len(s.stats) > 1 else "99.98%"),
              "".join(comps), n("muted"))
        return self.head("Status — %s" % s.brand, "Live status and uptime history for %s." % s.brand, "/status/") + \
            self.nav() + body + self.footer()

    def app_js(self):
        """Косметический JS: FAQ-аккордеон, форма с локальной валидацией,
        подсветка активной навигации. Никаких сетевых запросов."""
        n = self.n
        s = self.s
        return """(function () {
  'use strict';
  // FAQ accordion
  document.querySelectorAll('.%s').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var item = btn.closest('.%s');
      var open = item.classList.toggle('open');
      btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
  });
  // Fake auth form: local validation only, no network
  var form = document.getElementById('auth-form');
  if (form) {
    var alertBox = document.getElementById('form-alert');
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var email = form.querySelector('[name=email]').value;
      var pass = form.querySelector('[name=password]').value;
      var msg;
      if (!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(email)) {
        msg = 'That email address does not look right.';
      } else if (pass.length < 8) {
        msg = 'Password must be at least 8 characters.';
      } else if (form.dataset.kind === 'signup') {
        msg = 'Demo mode: sign-ups are simulated on this preview build.';
      } else {
        msg = 'Demo mode: credentials are not checked on this preview build.';
      }
      alertBox.textContent = msg;
      alertBox.classList.add('show');
    });
  }
  // Current year in footer
  document.querySelectorAll('[data-year]').forEach(function (el) {
    el.textContent = new Date().getFullYear();
  });
  // Smooth anchor scrolling
  document.querySelectorAll('a[href^="#"]').forEach(function (a) {
    a.addEventListener('click', function (ev) {
      var target = document.querySelector(a.getAttribute('href'));
      if (target) { ev.preventDefault(); target.scrollIntoView({ behavior: 'smooth' }); }
    });
  });
})();
""" % (n("faq_q"), n("faq_item"))

    # --- инфраструктура ------------------------------------------------------
    def robots_txt(self):
        s = self.s
        return "User-agent: *\nAllow: /\nDisallow: /login/\nDisallow: /signup/\n\nSitemap: https://%s/sitemap.xml\n" % s.domain

    def sitemap_xml(self):
        s = self.s
        pages = [("/", "1.0", "weekly"), ("/pricing/", "0.9", "monthly"),
                 ("/faq/", "0.8", "monthly"), ("/about/", "0.7", "monthly"),
                 ("/terms/", "0.3", "yearly"), ("/privacy/", "0.3", "yearly"),
                 ("/status/", "0.5", "daily")]
        urls = []
        for path, prio, freq in pages:
            urls.append("<url><loc>https://%s%s</loc><changefreq>%s</changefreq><priority>%s</priority></url>" %
                        (s.domain, path, freq, prio))
        return '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n%s\n</urlset>\n' % "\n".join(urls)

    def security_txt(self):
        L = self.s.legal
        return ("Contact: mailto:%s\nExpires: 2027-12-31T23:59:00Z\n"
                "Preferred-Languages: en\nCanonical: https://%s/.well-known/security.txt\n"
                "Policy: https://%s/privacy/\n") % (L["email"], self.s.domain, self.s.domain)


def sec_title_slug(t):
    out = []
    for ch in t.lower():
        out.append(ch if ch.isalnum() else "-")
    return "".join(out).strip("-")


# ----------------------------------------------------------------------------
# 12. Сборка сайта в файлы + CLI
# ----------------------------------------------------------------------------

PAGE_FILES = [
    ("index.html", "page_index"),
    ("pricing/index.html", "page_pricing"),
    ("about/index.html", "page_about"),
    ("faq/index.html", "page_faq"),
    ("terms/index.html", "page_terms"),
    ("privacy/index.html", "page_privacy"),
    ("login/index.html", "page_login"),
    ("signup/index.html", "page_signup"),
    ("404.html", "page_404"),
    ("status/index.html", "page_status"),
]


def generate_site(seed, out_dir, quiet=False):
    """Генерирует сайт по сиду в out_dir. Возвращает (Site, список файлов)."""
    s = Site(seed)
    namer = CssNamer(s.rng.spawn("cssnames"))
    css = CssBuilder(s.rng.spawn("css"), s.design, namer, s).build()
    r = Renderer(s, namer, css)

    files = {}
    for rel, method in PAGE_FILES:
        files[os.path.join(rel)] = getattr(r, method)()
    files["assets/style.css"] = css
    files["assets/app.js"] = r.app_js()
    files["favicon.svg"] = s.favicon_svg
    files["robots.txt"] = r.robots_txt()
    files["sitemap.xml"] = r.sitemap_xml()
    files[".well-known/security.txt"] = r.security_txt()
    # SVG-галерея (превью контента) — в assets
    for i, svg in enumerate(s.gallery):
        files["assets/gallery-%d.svg" % i] = svg

    written = []
    for rel, content in files.items():
        path = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        written.append(rel)

    meta = {
        "generator": "sitegen %s" % VERSION,
        "seed": str(seed),
        "seed_sha256": hashlib.sha256(str(seed).encode("utf-8")).hexdigest()[:16],
        "category": s.pack_id,
        "brand": s.brand,
        "domain": s.domain,
        "palette": s.design.pal["name"],
        "mode": s.design.pal["mode"],
        "tone": s.tone,
        "type_pair": s.design.type_pair["name"],
        "founded": s.legal["founded"],
        "files": sorted(written),
        "generated_at_iso": date.today().isoformat(),
    }
    meta_path = os.path.join(out_dir, "meta.json")
    with open(meta_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    if not quiet:
        print("%s -> %s (%s, %s, %s)" % (seed, out_dir, s.brand + s.tld,
                                         s.pack_id, s.design.pal["name"]))
    return s, written


def generate_batch(prefix, count, out_root, start=1, quiet=False):
    """N сайтов: <prefix>-1, <prefix>-2, … в подкаталоги out_root."""
    results = []
    for i in range(start, start + count):
        seed = "%s-%d" % (prefix, i)
        d = os.path.join(out_root, seed)
        generate_site(seed, d, quiet=quiet)
        results.append(d)
    if not quiet:
        print("generated %d sites in %s" % (count, out_root))
    return results


def site_info(seed):
    s = Site(seed)
    return {
        "seed": str(seed),
        "category": s.pack_id,
        "brand": s.brand,
        "domain": s.domain,
        "palette": s.design.pal["name"],
        "mode": s.design.pal["mode"],
        "tone": s.tone,
        "fonts": s.design.type_pair["name"],
        "founded": s.legal["founded"],
        "plans": [(p["name"], p["price"]) for p in s.plans],
        "tagline": s.tagline,
    }


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(
        prog="sitegen",
        description="Deterministic decoy-site generator (seed -> identical site).")
    ap.add_argument("seed", nargs="?", help="seed string; same seed = same site")
    ap.add_argument("-o", "--out", default=None, help="output directory (default: ./<seed>)")
    ap.add_argument("-q", "--quiet", action="store_true", help="suppress per-site output")
    ap.add_argument("--batch", type=int, default=None, metavar="N",
                    help="generate N sites: <seed>-1 .. <seed>-N")
    ap.add_argument("--info", action="store_true", help="print site profile without generating")
    ap.add_argument("--stdout", metavar="PAGE", default=None,
                    help="print one page to stdout (e.g. index.html, style.css, app.js)")
    ap.add_argument("--stats", action="store_true",
                    help="generate nothing; print uniqueness stats over 300 seeds")
    ap.add_argument("--version", action="version", version="sitegen %s" % VERSION)
    args = ap.parse_args(argv)

    if args.stats:
        combos = uniqueness_stats(300)
        print(json.dumps(combos, indent=2, ensure_ascii=False))
        return 0
    if not args.seed:
        ap.print_help()
        return 2
    if args.info:
        print(json.dumps(site_info(args.seed), indent=2, ensure_ascii=False))
        return 0
    if args.stdout:
        s = Site(args.seed)
        namer = CssNamer(s.rng.spawn("cssnames"))
        css = CssBuilder(s.rng.spawn("css"), s.design, namer, s).build()
        r = Renderer(s, namer, css)
        table = dict(PAGE_FILES)
        table["style.css"] = lambda: css
        table["app.js"] = r.app_js
        table["robots.txt"] = r.robots_txt
        table["sitemap.xml"] = r.sitemap_xml
        page = args.stdout.lstrip("/")
        if page not in table:
            sys.stderr.write("unknown page: %s (try one of %s)\n" % (page, ", ".join(sorted(table))))
            return 2
        fn = table[page]
        content = fn() if callable(fn) and page in ("app.js", "robots.txt", "sitemap.xml") or page in PAGE_FILES else fn
        if isinstance(content, str):
            sys.stdout.write(content)
        else:
            sys.stdout.write(content())
        return 0
    if args.batch:
        out_root = args.out or "./batch-%s" % args.seed
        generate_batch(args.seed, args.batch, out_root, quiet=args.quiet)
        return 0
    out = args.out or "./" + _safe_dirname(str(args.seed))
    generate_site(args.seed, out, quiet=args.quiet)
    return 0


def _safe_dirname(seed):
    keep = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    out = "".join(ch if ch in keep else "_" for ch in seed)
    return out[:64] or "site"


def uniqueness_stats(n=300):
    """Сколько уникальных комбинаций (категория, бренд, палитра, тон, шрифты)
    даёт n последовательных сидов."""
    seen = set()
    cats, pals, tones = {}, {}, {}
    for i in range(n):
        s = Site("stat-%d" % i)
        key = (s.pack_id, s.brand, s.design.pal["name"], s.tone, s.design.type_pair["name"])
        seen.add(key)
        cats[s.pack_id] = cats.get(s.pack_id, 0) + 1
        pals[s.design.pal["name"]] = pals.get(s.design.pal["name"], 0) + 1
        tones[s.tone] = tones.get(s.tone, 0) + 1
    return {
        "seeds": n,
        "unique_profiles": len(seen),
        "unique_brand_domains": len(set(k[1] for k in seen)),
        "categories_used": len(cats),
        "category_histogram": dict(sorted(cats.items(), key=lambda kv: -kv[1])),
        "palettes_used": len(pals),
        "tones_histogram": tones,
    }


if __name__ == "__main__":
    sys.exit(main())
