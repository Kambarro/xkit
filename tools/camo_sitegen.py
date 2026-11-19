#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""camo_sitegen.py — обёртка над sitegen для XKIT camo (маскировка кластера).

Единый проект на весь кластер: мастер и ноды используют ОДИН master_seed →
один бренд/категория/палитра. Ноды получают лёгкую вариацию (порядок секций,
датасеты) от своего имени, но остаются тем же проектом. Домен:
  - реальный домен задан (свой) → подменяем бренд-домен на него (мастер apex,
    нода = её поддомен api./dev.);
  - домена нет (IP) → оставляем сгенерированный бренд-домен sitegen.

Вызов:
  camo_sitegen.py --seed <hex64> --out <dir> [--domain <real>] [--node <name>]
  --node задан → лёгкая вариация контента (тот же бренд/дизайн).
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sitegen as sg  # noqa: E402


def _reseed(site, seed, label):
    """Пересоздаёт контент-подсистемы от (master_seed + label), сохраняя
    бренд/категорию/палитру/дизайн мастера. Лёгкая вариация для ноды."""
    rng = sg.Rng(seed + ":" + label)
    site.plans = sg.build_plans(rng.spawn("plans"), site.pack)
    site.testimonials = sg.build_testimonials(rng.spawn("tmon"), site.pack, site.brand)
    site.stats = sg.build_stats(rng.spawn("stats"), site.pack)
    site.table = sg.build_table(rng.spawn("table"), site.pack)
    site.people = [sg.make_person(rng.spawn("p%d" % i)) for i in range(rng.randint(3, 5))]
    site.faq = site._build_faq()
    site.features = site._build_features()


def _swap_domain(tree_dir, old_domain, new_domain):
    """Подменяет бренд-домен на реальный во всех текстовых файлах дерева."""
    if not new_domain or new_domain == old_domain:
        return
    for root, _, files in os.walk(tree_dir):
        for f in files:
            if not f.endswith((".html", ".css", ".js", ".xml", ".txt", ".json", ".svg")):
                continue
            p = os.path.join(root, f)
            try:
                with open(p, encoding="utf-8") as fh:
                    data = fh.read()
            except (UnicodeDecodeError, OSError):
                continue
            if old_domain in data:
                data = data.replace(old_domain, new_domain)
                with open(p, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(data)


def _add_referrer(tree_dir):
    """referrer-политика no-referrer во все HTML (требование маскировки XKIT)."""
    for root, _, files in os.walk(tree_dir):
        for f in files:
            if not f.endswith(".html"):
                continue
            p = os.path.join(root, f)
            with open(p, encoding="utf-8") as fh:
                data = fh.read()
            if 'name="referrer"' not in data:
                data = data.replace('<meta charset="utf-8">',
                                    '<meta charset="utf-8"><meta name="referrer" content="no-referrer">', 1)
                with open(p, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(data)


def generate(seed, out_dir, domain=None, node=None, quiet=True):
    # единый бренд/дизайн от master_seed
    site, written = sg.generate_site(seed, out_dir, quiet=quiet)
    # лёгкая вариация для ноды (тот же бренд, другой контент-порядок)
    if node:
        _reseed(site, seed, "node:" + node)
        namer = sg.CssNamer(site.rng.spawn("cssnames"))
        css = sg.CssBuilder(site.rng.spawn("css"), site.design, namer, site).build()
        r = sg.Renderer(site, namer, css)
        for rel, method in sg.PAGE_FILES:
            path = os.path.join(out_dir, rel)
            os.makedirs(os.path.dirname(path) or out_dir, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(getattr(r, method)())
        with open(os.path.join(out_dir, "assets/style.css"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(css)
        with open(os.path.join(out_dir, "assets/app.js"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(r.app_js())
        with open(os.path.join(out_dir, "robots.txt"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(r.robots_txt())
        with open(os.path.join(out_dir, "sitemap.xml"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(r.sitemap_xml())
    # подмена домена на реальный (свой домен/поддомен ноды)
    _swap_domain(out_dir, site.domain, domain)
    _add_referrer(out_dir)
    return site


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--domain", default=None)
    ap.add_argument("--node", default=None)
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    generate(a.seed, a.out, domain=a.domain, node=a.node, quiet=a.quiet)
    if not a.quiet:
        print("camo: %s -> %s%s" % (a.seed[:12], a.out, (" (" + a.domain + ")") if a.domain else ""))


if __name__ == "__main__":
    main()
