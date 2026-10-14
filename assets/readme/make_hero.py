"""Writes hero-dark.svg and hero-light.svg next to this file.

The README header: the notch with its wing of agent marks (the "Dots" mark style: circle = Claude,
rounded square = Codex). One agent starts waiting, a permission card drops from the notch, a cursor
clicks Allow, and the agent goes back to work. 8 s loop, pure CSS, so GitHub plays it in an <img>.
Run: python3 assets/readme/make_hero.py
"""
from pathlib import Path

W, H = 1640, 560
LOOP = 8  # seconds

THEMES = {
    "dark": dict(bg="#0b0d12", glow="#3b4cff", glow_op=".22", bar="#1a1d24", bar_line="#2a2e37",
                 fg="#f2f4f8", mut="#8b93a1", card="#16181e", card_line="#2c303a", deny="#2a2d35"),
    "light": dict(bg="#f5f6f9", glow="#7d8cff", glow_op=".28", bar="#e6e8ee", bar_line="#d5d9e1",
                  fg="#14171d", mut="#5b6472", card="#16181e", card_line="#2c303a", deny="#2a2d35"),
}
GREEN, YELLOW, GREY = "#34c759", "#ffb31a", "#5a5f69"

CX = W / 2           # notch centre
BAR_Y, BAR_H = 40, 84
NOTCH_W = 360
WING_L = CX - NOTCH_W / 2 - 290  # the wing extends the notch to the left
MY = BAR_Y + BAR_H / 2           # marks' centre line


def mark(kind, x, size, cls, color):
    if kind == "claude":
        return f'<circle class="{cls}" cx="{x}" cy="{MY}" r="{size / 2}" fill="{color}"/>'
    r = size * .27
    return f'<rect class="{cls}" x="{x - size / 2}" y="{MY - size / 2}" width="{size}" height="{size}" rx="{r}" fill="{color}"/>'


def menu(c):
    y, h = MY - 7, 14
    left = [(110, 22), (150, 40), (206, 36), (258, 50)]
    right = [(W - 380, 30), (W - 330, 30), (W - 280, 30), (W - 230, 110)]
    return "".join(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{c['mut']}" opacity=".35"/>' for x, w in left + right)


def svg(c):
    marks = [
        mark("claude", WING_L + 58, 34, "m m1", GREEN),
        mark("claude", WING_L + 95, 19, "m m2", GREEN),          # its subagent
        mark("codex", WING_L + 148, 34, "m m3", GREEN),
        mark("claude", WING_L + 208, 34, "m m4 wait", GREEN),     # the one that will ask
        mark("codex", WING_L + 264, 34, "m m5", GREY),            # done
    ]
    wx = WING_L + 208
    card_x, card_y, card_w, card_h = CX - 250, BAR_Y + BAR_H + 18, 500, 176
    allow_x, allow_y = card_x + 24, card_y + 116
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W // 2}" height="{H // 2}" role="img" aria-label="Agent Notch: agent marks beside the notch; one asks for permission and a click allows it">
<style>
text{{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI",Helvetica,Arial,sans-serif}}
.mono{{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}}
.m{{opacity:0;animation:mk {LOOP}s ease-out infinite}}
.m1{{animation-delay:0s}} .m2{{animation-name:mk2}} .m3{{animation-name:mk3}} .m5{{animation-name:mk5}}
.wait{{animation:mk4 {LOOP}s ease-out infinite,wt {LOOP}s linear infinite}}
@keyframes mk{{0%{{opacity:0}}4%,94%{{opacity:1}}100%{{opacity:0}}}}
@keyframes mk2{{0%,5%{{opacity:0}}9%,94%{{opacity:1}}100%{{opacity:0}}}}
@keyframes mk3{{0%,8%{{opacity:0}}12%,94%{{opacity:1}}100%{{opacity:0}}}}
@keyframes mk4{{0%,11%{{opacity:0}}15%,94%{{opacity:1}}100%{{opacity:0}}}}
@keyframes mk5{{0%,14%{{opacity:0}}18%,94%{{opacity:1}}100%{{opacity:0}}}}
@keyframes wt{{0%,19%{{fill:{GREEN}}}21%,29%{{fill:{YELLOW}}}33%{{fill:#b07a10}}37%{{fill:{YELLOW}}}41%{{fill:#b07a10}}45%,58%{{fill:{YELLOW}}}60%,100%{{fill:{GREEN}}}}}
.ring{{fill:none;stroke:{YELLOW};stroke-width:3;opacity:0;transform-box:fill-box;transform-origin:center;animation:ring {LOOP}s ease-out infinite}}
@keyframes ring{{0%,20%{{opacity:0;transform:scale(1)}}21%{{opacity:.9;transform:scale(1)}}33%{{opacity:0;transform:scale(2.4)}}34%{{opacity:.9;transform:scale(1)}}46%{{opacity:0;transform:scale(2.4)}}100%{{opacity:0}}}}
.card{{opacity:0;animation:card {LOOP}s cubic-bezier(.2,.8,.2,1) infinite}}
@keyframes card{{0%,22%{{opacity:0;transform:translateY(-26px)}}26%,66%{{opacity:1;transform:translateY(0)}}71%,100%{{opacity:0;transform:translateY(-26px)}}}}
.allow{{animation:allow {LOOP}s linear infinite}}
@keyframes allow{{0%,57%{{fill:{GREEN}}}58%,61%{{fill:#7ee29a}}63%,100%{{fill:{GREEN}}}}}
.cur{{opacity:0;animation:cur {LOOP}s cubic-bezier(.4,0,.2,1) infinite}}
@keyframes cur{{0%,36%{{opacity:0;transform:translate(260px,90px)}}39%{{opacity:1;transform:translate(260px,90px)}}55%{{opacity:1;transform:translate(0,0)}}58%{{transform:translate(0,0) scale(.86)}}60%{{transform:translate(0,0) scale(1)}}64%{{opacity:1}}68%,100%{{opacity:0;transform:translate(0,0)}}}}
@media (prefers-reduced-motion:reduce){{.m,.wait{{animation:none;opacity:1}}.card,.cur,.ring{{animation:none}}}}
</style>
<defs>
<radialGradient id="glow" cx="50%" cy="0%" r="60%"><stop offset="0" stop-color="{c['glow']}" stop-opacity="{c['glow_op']}"/><stop offset="1" stop-color="{c['glow']}" stop-opacity="0"/></radialGradient>
<filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity=".35"/></filter>
</defs>
<rect width="{W}" height="{H}" rx="28" fill="{c['bg']}"/>
<rect width="{W}" height="{H}" rx="28" fill="url(#glow)"/>
<rect x="70" y="{BAR_Y}" width="{W - 140}" height="{BAR_H}" rx="16" fill="{c['bar']}"/>
<line x1="70" y1="{BAR_Y + BAR_H}" x2="{W - 70}" y2="{BAR_Y + BAR_H}" stroke="{c['bar_line']}" stroke-width="2"/>
{menu(c)}
<path d="M{WING_L} {BAR_Y} H{CX + NOTCH_W / 2} V{BAR_Y + BAR_H - 24} a24 24 0 0 1 -24 24 H{WING_L + 24} a24 24 0 0 1 -24 -24 Z" fill="#000"/>
<circle cx="{CX + 60}" cy="{MY}" r="7" fill="#11141b"/><circle cx="{CX + 60}" cy="{MY}" r="3" fill="#1d2433"/>
{chr(10).join(marks)}
<circle class="ring" cx="{wx}" cy="{MY}" r="17"/>
<g class="card" filter="url(#sh)">
<rect x="{card_x}" y="{card_y}" width="{card_w}" height="{card_h}" rx="20" fill="{c['card']}" stroke="{c['card_line']}" stroke-width="2"/>
<circle cx="{card_x + 34}" cy="{card_y + 38}" r="9" fill="{YELLOW}"/>
<text x="{card_x + 56}" y="{card_y + 46}" font-size="23" font-weight="600" fill="#f2f4f8">Bash command</text>
<text x="{card_x + card_w - 24}" y="{card_y + 46}" font-size="20" text-anchor="end" fill="#8b93a1">wedding-app</text>
<text class="mono" x="{card_x + 24}" y="{card_y + 90}" font-size="22" fill="#d7dbe3">pnpm --filter api test</text>
<rect class="allow" x="{allow_x}" y="{allow_y}" width="214" height="42" rx="11" fill="{GREEN}"/>
<text x="{allow_x + 107}" y="{allow_y + 28}" font-size="20" font-weight="600" text-anchor="middle" fill="#06210f">Allow  ⌃⌥Y</text>
<rect x="{allow_x + 230}" y="{allow_y}" width="214" height="42" rx="11" fill="{c['deny']}"/>
<text x="{allow_x + 337}" y="{allow_y + 28}" font-size="20" font-weight="600" text-anchor="middle" fill="#d7dbe3">Deny  ⌃⌥N</text>
</g>
<g transform="translate({allow_x + 120},{allow_y + 26})"><g class="cur"><path d="M0 0 L0 30 L8 23 L13 35 L19 32 L14 21 L24 21 Z" fill="#fff" stroke="#000" stroke-width="2" stroke-linejoin="round"/></g></g>
<text x="{CX}" y="{H - 104}" font-size="88" font-weight="700" text-anchor="middle" letter-spacing="-2" fill="{c['fg']}">Agent Notch</text>
<g transform="translate({CX - 210},{H - 58})" font-size="24" fill="{c['mut']}">
<circle cx="0" cy="-8" r="8" fill="{GREEN}"/><text x="16" y="0">working</text>
<circle cx="140" cy="-8" r="8" fill="{YELLOW}"/><text x="156" y="0">waiting for you</text>
<circle cx="355" cy="-8" r="8" fill="{GREY}"/><text x="371" y="0">done</text>
</g>
</svg>
'''


out = Path(__file__).parent
for name, c in THEMES.items():
    (out / f"hero-{name}.svg").write_text(svg(c))
print("wrote", ", ".join(f"hero-{n}.svg" for n in THEMES))
