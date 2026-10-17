"""Generates the Facet logo / app icon as SVG (and PNG when cairosvg is available).

The mark is the product itself: a ring of six glass facets around a hub, one facet lit
with a soft tint — the wheel you see while dragging a file.

    python3 Design/make_logo.py
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

S = 1024
C = S / 2
R_IN, R_OUT = 168, 352
GAP = 22          # px between facets
CORNER = 26       # rounding of facet corners
N = 6
LIT = 0           # index of the highlighted facet (12 o'clock)


def facet_path(i):
    """Annular sector inset by CORNER (rounded later with a round-join stroke)."""
    step = 2 * math.pi / N
    mid = i * step - math.pi / 2
    r_in, r_out = R_IN + CORNER, R_OUT - CORNER
    pad = GAP / 2 + CORNER
    a_in, a_out = pad / r_in, pad / r_out
    s, e = mid - step / 2, mid + step / 2

    def pt(r, a):
        return C + r * math.cos(a), C + r * math.sin(a)

    p1 = pt(r_out, s + a_out)
    p2 = pt(r_out, e - a_out)
    p3 = pt(r_in, e - a_in)
    p4 = pt(r_in, s + a_in)
    return (f"M{p1[0]:.2f},{p1[1]:.2f} "
            f"A{r_out},{r_out} 0 0 1 {p2[0]:.2f},{p2[1]:.2f} "
            f"L{p3[0]:.2f},{p3[1]:.2f} "
            f"A{r_in},{r_in} 0 0 0 {p4[0]:.2f},{p4[1]:.2f} Z")


def svg(size=S, with_background=True):
    # macOS icon grid: an 824px rounded body centred on the 1024 canvas.
    body, margin, radius = 824, 100, 186
    scale = 0.80  # the wheel sits inside the body with breathing room
    masks, facets = [], []
    for i in range(N):
        d = facet_path(i)
        masks.append(
            f'<mask id="m{i}" maskUnits="userSpaceOnUse" x="0" y="0" width="{S}" height="{S}">'
            f'<path d="{d}" fill="#fff" stroke="#fff" stroke-width="{CORNER * 2}" stroke-linejoin="round"/></mask>'
        )
        fill = "url(#lit)" if i == LIT else "url(#glass)"
        facets.append(
            f'<g filter="url(#soft)"><rect width="{S}" height="{S}" fill="{fill}" mask="url(#m{i})"/></g>'
            f'<rect width="{S}" height="{S}" fill="url(#sheen)" mask="url(#m{i})"/>'
        )

    background = ""
    if with_background:
        background = f'''
  <g clip-path="url(#squircle)">
    <rect x="{margin}" y="{margin}" width="{body}" height="{body}" fill="url(#bg)"/>
    <circle cx="330" cy="300" r="330" fill="url(#blobA)"/>
    <circle cx="760" cy="780" r="340" fill="url(#blobB)"/>
  </g>
  <rect x="{margin + 1.5}" y="{margin + 1.5}" width="{body - 3}" height="{body - 3}" rx="{radius - 1.5}" fill="none" stroke="#FFFFFF" stroke-opacity="0.7" stroke-width="3"/>'''

    t = C * (1 - scale)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {S} {S}">
  <defs>
    <clipPath id="squircle"><rect x="{margin}" y="{margin}" width="{body}" height="{body}" rx="{radius}"/></clipPath>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#F6F8FC"/>
      <stop offset="1" stop-color="#C9D4E7"/>
    </linearGradient>
    <radialGradient id="blobA">
      <stop offset="0" stop-color="#D9CCF5" stop-opacity="0.8"/>
      <stop offset="1" stop-color="#D9CCF5" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="blobB">
      <stop offset="0" stop-color="#BDE2DC" stop-opacity="0.85"/>
      <stop offset="1" stop-color="#BDE2DC" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="glass" gradientUnits="userSpaceOnUse" x1="0" y1="{C - R_OUT}" x2="0" y2="{C + R_OUT}">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.97"/>
      <stop offset="1" stop-color="#F1F4FA" stop-opacity="0.82"/>
    </linearGradient>
    <linearGradient id="lit" gradientUnits="userSpaceOnUse" x1="{C}" y1="{C - R_OUT}" x2="{C}" y2="{C - R_IN}">
      <stop offset="0" stop-color="#B3CCF6"/>
      <stop offset="1" stop-color="#86A8E8"/>
    </linearGradient>
    <linearGradient id="sheen" gradientUnits="userSpaceOnUse" x1="0" y1="{C - R_OUT}" x2="0" y2="{C}">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.45"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="hub" cx="0.4" cy="0.35" r="0.75">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#E9EDF6"/>
    </radialGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#33446A" flood-opacity="0.16"/>
    </filter>
    {"".join(masks)}
  </defs>{background}
  <g transform="translate({t} {t}) scale({scale})">
    {"".join(facets)}
    <circle cx="{C}" cy="{C}" r="{R_IN - 30}" fill="url(#hub)" filter="url(#soft)"/>
    <circle cx="{C}" cy="{C}" r="{R_IN - 31.5}" fill="none" stroke="#FFFFFF" stroke-width="3"/>
  </g>
</svg>'''


def menubar_svg():
    """Monochrome template glyph for the menu bar (18pt)."""
    parts = []
    for i in range(N):
        parts.append(f'<path d="{facet_path(i)}" fill="#000" stroke="#000" stroke-width="{CORNER * 2}" stroke-linejoin="round"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="120 120 784 784">'
            + "".join(parts)
            + f'<circle cx="{C}" cy="{C}" r="{R_IN - 40}" fill="#000"/></svg>')


if __name__ == "__main__":
    with open(os.path.join(HERE, "logo.svg"), "w") as f:
        f.write(svg())
    with open(os.path.join(HERE, "mark.svg"), "w") as f:
        f.write(svg(with_background=False))
    with open(os.path.join(HERE, "menubar.svg"), "w") as f:
        f.write(menubar_svg())
    try:
        import cairosvg
        cairosvg.svg2png(bytestring=svg().encode(), write_to=os.path.join(ROOT, "Resources", "AppIcon.png"),
                         output_width=1024, output_height=1024)
        cairosvg.svg2png(bytestring=menubar_svg().encode(), write_to=os.path.join(ROOT, "Resources", "MenuBarIcon.png"),
                         output_width=36, output_height=36)
        print("wrote Resources/AppIcon.png and Resources/MenuBarIcon.png")
    except ImportError:
        print("cairosvg not installed; SVGs only")
