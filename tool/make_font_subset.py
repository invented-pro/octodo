#!/usr/bin/env python3
"""Regenerate the bundled terminal fallback font (JetBrainsMono NFM subset).

The app ships one guaranteed monospace font that serves as (a) the
last-resort primary when the configured family is not installed and
(b) the last entry of the render fallback chain, where its Nerd Font
icon codepoints give powerline/starship/p10k/eza glyphs to users whose
own font is not a Nerd Font.

Source: JetBrainsMono Nerd Font Mono (NFM) v3.4.0 release
  https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.zip
  file: JetBrainsMonoNerdFontMono-Regular.ttf  (internal family
  "JetBrainsMono NFM", OFL-licensed upstream with the Nerd Fonts
  rename already applied)

We subset to:
  * Latin text: ASCII + Latin-1 + general punctuation + currency +
    arrows + math operators + control pictures + box drawing +
    block elements + geometric shapes
  * Greek + Cyrillic
  * a conservative set of Nerd Font icon blocks (single-plane):
      E000-E00F  Seti-UI core
      E0A0-E0D4  Powerline symbols
      E5FA-E62B  Custom (seti-extended / file icons)
      E700-E7C5  Devicons
      EA60-EBEB  Font Awesome
      ED00-ED5F  Octicons (legacy block)
      F400-F4FC  Octicons
The 6.9k supplementary-plane Material Design icons (U+F0001..U+1BFFF)
are deliberately excluded: prompts rarely use them and they dominate
the file size (2.4 MB full vs ~360 KB subset).

Usage:
  pip install fonttools
  python3 tool/make_font_subset.py <path-to-JetBrainsMonoNerdFontMono-Regular.ttf> \
      assets/fonts/JetBrainsMono-NFM-subset.ttf

The generated artifact is committed; CI does not run this script.
"""
import sys
from pathlib import Path

from fontTools.subset import Subsetter, Options
from fontTools.ttLib import TTFont

TEXT_RANGES = [
    (0x0020, 0x007E),  # ASCII
    (0x00A0, 0x00FF),  # Latin-1 Supplement
    (0x0370, 0x03FF),  # Greek
    (0x0400, 0x045F),  # Cyrillic
    (0x0460, 0x052F),  # Cyrillic Supplement
    (0x2000, 0x206F),  # General Punctuation
    (0x20A0, 0x20BF),  # Currency Symbols
    (0x2190, 0x22FF),  # Arrows + Math Operators
    (0x2300, 0x2386),  # Misc Technical (incl. apostrophes for rulers)
    (0x2400, 0x243F),  # Control Pictures
    (0x2500, 0x257F),  # Box Drawing
    (0x2580, 0x259F),  # Block Elements
    (0x25A0, 0x25FF),  # Geometric Shapes
]

ICON_RANGES = [
    (0xE000, 0xE00F),  # Seti-UI core
    (0xE0A0, 0xE0D4),  # Powerline
    (0xE5FA, 0xE62B),  # Custom file icons
    (0xE700, 0xE7C5),  # Devicons
    (0xEA60, 0xEBEB),  # Font Awesome
    (0xED00, 0xED5F),  # Octicons (legacy)
    (0xF400, 0xF4FC),  # Octicons
]

FAMILY_NAME = "JetBrainsMono NFM"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])

    font = TTFont(src)
    family = font["name"].getDebugName(1)
    if family != FAMILY_NAME:
        print(f"ERROR: expected family {FAMILY_NAME!r}, got {family!r}")
        return 1

    # Sanity: the Mono Nerd Font variant must keep a uniform ASCII advance.
    upm = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    advances = {
        round(hmtx[cmap[ord(c)]][0] / upm, 3)
        for c in "Wa.@i-1m|"
        if cmap.get(ord(c))
    }
    if len(advances) != 1:
        print(f"ERROR: source is not monospace: {sorted(advances)}")
        return 1

    opts = Options()
    opts.hinting = False  # hinting tables dominate size; UI renders AA anyway
    opts.layout_features = ["kern", "liga", "calt", "ccmp", "mark"]
    opts.name_IDs = [1, 2, 3, 4, 6]  # keep identity names, drop huge vendor tables
    opts.notdef_outline = True
    opts.drop_tables += ["DSIG"]
    subsetter = Subsetter(options=opts)
    subsetter.populate(
        unicodes=[cp for lo, hi in TEXT_RANGES + ICON_RANGES for cp in range(lo, hi + 1)]
    )
    subsetter.subset(font)
    dst.parent.mkdir(parents=True, exist_ok=True)
    font.save(dst)

    # Verify the artifact: family, mono advance, essential glyphs present.
    out = TTFont(dst)
    assert out["name"].getDebugName(1) == FAMILY_NAME
    ocmap = out.getBestCmap()
    ohmtx = out["hmtx"]
    oupm = out["head"].unitsPerEm
    out_adv = {
        round(ohmtx[ocmap[ord(c)]][0] / oupm, 3) for c in "Wa.@i-1m|" if ocmap.get(ord(c))
    }
    assert len(out_adv) == 1, f"subset lost monospace advance: {out_adv}"
    for cp, label in [(0xE0B0, "powerline triangle"), (0xE0B1, "powerline slant"), (0x2500, "box drawing"), (0x4E2D, "CJK")]:
        # CJK is NOT expected (out of scope) — assert presence only for icon/box.
        if label == "CJK":
            assert ocmap.get(cp) is None, "CJK unexpectedly present (subset bug)"
        else:
            assert ocmap.get(cp) is not None, f"missing {label}"
    n_codepoints = len(ocmap)
    n_icons = sum(1 for cp in ocmap if cp >= 0xE000)
    print(
        f"OK {dst} ({dst.stat().st_size / 1024:.0f} KB, "
        f"{n_codepoints} codepoints, {n_icons} icons, advance {next(iter(out_adv))}em)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
