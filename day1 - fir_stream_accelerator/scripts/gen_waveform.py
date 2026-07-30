#!/usr/bin/env python3
"""Generate docs/waveform.svg: an annotated timing diagram illustrating the two
handshake behaviours the testbench exercises -- input backpressure and consumer
stall -- plus the fill latency and completion interrupt. The waveform is
illustrative (a short 8-tap job) and drawn to be readable in both GitHub
themes: opaque background, presentation attributes only, no scripts/markers.
"""

LABEL_W = 196
CYC_W   = 66
N       = 14
TOP     = 64
ROW_H   = 46
WAVE_W  = CYC_W * N
W       = LABEL_W + WAVE_W + 30
HI, LO  = 9, 33          # offsets within a row for logic high / low

# digital signals: sequence of 0/1 per cycle
CLK = "clk"
DIG = {
    "s_axis_tvalid": [0,1,1,1,1,1,1,0,0,0,0,0,0,0],
    "s_axis_tready": [1,1,1,0,0,1,1,1,0,0,0,0,0,0],
}
DIG2 = {
    "m_axis_tvalid": [0,0,0,1,1,1,1,1,1,1,1,1,0,0],
    "m_axis_tready": [1,1,1,1,1,0,0,1,1,1,1,1,1,1],
    "irq":           [0,0,0,0,0,0,0,0,0,0,0,0,1,1],
}
# bus signals: value string per cycle ("" == idle)
BUS_IN  = ["", "x0","x1","x2","x2","x2","x3","x4","", "", "", "", "", ""]
BUS_OUT = ["", "", "", "y0","y1","y2","y2","y2","y3","y4","y5","y6","", ""]

ORDER = ["clk", "s_axis_tvalid", "s_axis_tready", "s_axis_tdata",
         "m_axis_tvalid", "m_axis_tready", "m_axis_tdata", "irq"]

def cx(c):  # left x of cycle c
    return LABEL_W + c * CYC_W

def row_y(i):
    return TOP + i * ROW_H

def clk_wave(y):
    pts = []
    for c in range(N):
        x0 = cx(c); xm = x0 + CYC_W // 2; x1 = x0 + CYC_W
        pts += [(x0, y+LO), (x0, y+HI), (xm, y+HI), (xm, y+LO), (x1, y+LO)]
    d = "M " + " L ".join(f"{x},{yy}" for x, yy in pts)
    return f'<path d="{d}" fill="none" stroke="#8fb7e0" stroke-width="2"/>'

def dig_wave(seq, y, color):
    def lvl(v): return y+HI if v else y+LO
    pts = [(cx(0), lvl(seq[0]))]
    for c in range(N):
        x0 = cx(c); x1 = x0 + CYC_W
        pts.append((x0, lvl(seq[c])))
        pts.append((x1, lvl(seq[c])))
    d = "M " + " L ".join(f"{x},{yy}" for x, yy in pts)
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.5"/>'

def bus_wave(seq, y, color, fill):
    top, bot = y+HI, y+LO
    out = []
    for c in range(N):
        x0 = cx(c); x1 = x0 + CYC_W; v = seq[c]
        if v == "":
            out.append(f'<line x1="{x0}" y1="{(top+bot)//2}" x2="{x1}" '
                       f'y2="{(top+bot)//2}" stroke="#5b6b7d" stroke-width="1.5" stroke-dasharray="4,3"/>')
            continue
        change = (c == 0) or (seq[c] != seq[c-1]) or (seq[c-1] == "")
        sx = x0 + (5 if change else 0)
        out.append(f'<polygon points="{sx},{top} {x1},{top} {x1},{bot} {sx},{bot}" '
                   f'fill="{fill}" stroke="{color}" stroke-width="1.5"/>')
        if change and c != 0 and seq[c-1] != "":
            out.append(f'<line x1="{x0-5}" y1="{top}" x2="{x0+5}" y2="{bot}" stroke="{color}" stroke-width="1.5"/>')
            out.append(f'<line x1="{x0-5}" y1="{bot}" x2="{x0+5}" y2="{top}" stroke="{color}" stroke-width="1.5"/>')
        out.append(f'<text x="{(x0+x1)//2}" y="{y+27}" font-size="13" fill="#eaf0f6" '
                   f'text-anchor="middle">{v}</text>')
    return "\n".join(out)

def label(name, i, color="#dfe7f0"):
    y = row_y(i) + 26
    return f'<text x="{LABEL_W-14}" y="{y}" font-size="14" fill="{color}" text-anchor="end" font-family="monospace">{name}</text>'

def vgrid():
    out = []
    for c in range(N+1):
        x = cx(c)
        out.append(f'<line x1="{x}" y1="{TOP-6}" x2="{x}" y2="{row_y(len(ORDER))-8}" '
                   f'stroke="#2c3947" stroke-width="1"/>')
    for c in range(N):
        out.append(f'<text x="{cx(c)+CYC_W//2}" y="{TOP-12}" font-size="11" fill="#7b8a9b" text-anchor="middle">{c}</text>')
    return "\n".join(out)

def annot(x, y, text, color="#e0a96d", anchor="middle"):
    return f'<text x="{x}" y="{y}" font-size="12" font-weight="bold" fill="{color}" text-anchor="{anchor}">{text}</text>'

def arrow(x1, y1, x2, y2, color):
    # simple horizontal double-headed span
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="1.5"/>'
            f'<polygon points="{x1},{y1} {x1+7},{y1-4} {x1+7},{y1+4}" fill="{color}"/>'
            f'<polygon points="{x2},{y2} {x2-7},{y2-4} {x2-7},{y2+4}" fill="{color}"/>')

def main():
    idx = {n: i for i, n in enumerate(ORDER)}
    H = row_y(len(ORDER)) + 70
    s = []
    s.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="Helvetica, Arial, sans-serif">')
    s.append(f'<rect x="0" y="0" width="{W}" height="{H}" fill="#1f2a37"/>')
    s.append(f'<text x="20" y="34" font-size="20" font-weight="bold" fill="#ffffff">FIR accelerator — one job (illustrative timing)</text>')
    s.append(vgrid())
    # rows
    s.append(label("clk", idx["clk"], "#8fb7e0")); s.append(clk_wave(row_y(idx["clk"])))
    for n, seq in DIG.items():
        s.append(label(n, idx[n])); s.append(dig_wave(seq, row_y(idx[n]), "#e07a3f"))
    s.append(label("s_axis_tdata", idx["s_axis_tdata"]))
    s.append(bus_wave(BUS_IN, row_y(idx["s_axis_tdata"]), "#e07a3f", "#5a3b22"))
    for n, seq in DIG2.items():
        col = "#d1495b" if n == "irq" else "#2fa39a"
        s.append(label(n, idx[n])); s.append(dig_wave(seq, row_y(idx[n]), col))
    s.append(label("m_axis_tdata", idx["m_axis_tdata"]))
    s.append(bus_wave(BUS_OUT, row_y(idx["m_axis_tdata"]), "#2fa39a", "#1f4a45"))

    # annotations
    yb = H - 46
    # backpressure window (input tready low, cycles 3-4)
    s.append(f'<rect x="{cx(3)}" y="{row_y(idx["s_axis_tready"])+4}" width="{2*CYC_W}" height="{ROW_H-8}" fill="none" stroke="#e0a96d" stroke-width="1.5" stroke-dasharray="4,3"/>')
    s.append(annot(cx(4), yb, "input backpressure: TREADY low, TDATA held"))
    s.append(arrow(cx(3)+4, yb-14, cx(5)-4, yb-14, "#e0a96d"))
    # consumer stall window (output tready low, cycles 5-6)
    s.append(f'<rect x="{cx(5)}" y="{row_y(idx["m_axis_tready"])+4}" width="{2*CYC_W}" height="{ROW_H-8}" fill="none" stroke="#2fa39a" stroke-width="1.5" stroke-dasharray="4,3"/>')
    s.append(annot(cx(9)+20, yb, "consumer stall: TDATA stable, TVALID held", "#2fa39a"))
    # fill latency arrow (cycle 1 first input -> cycle 3 first output), 2nd line
    s.append(arrow(cx(1)+4, yb+18, cx(3)-4, yb+18, "#9fc2e8"))
    s.append(annot(cx(4)+CYC_W//2, yb+22, "3-cycle fill latency (first sample in → first result out)", "#9fc2e8", "start"))
    # completion
    s.append(annot(cx(12)+CYC_W//2, yb, "DONE → irq", "#d1495b"))
    s.append('</svg>')
    with open("docs/waveform.svg", "w") as f:
        f.write("\n".join(s) + "\n")
    print("wrote docs/waveform.svg")

if __name__ == "__main__":
    main()
