#!/usr/bin/env python3
"""Show a board inference result the way a person reads it.

Inputs come from the model ELF (model_input*_data / _shape), outputs from the
board's own UART dump (out/results/<model>-<time>.uart.txt, every line already
checked against its =sum by ddr_run.py).  Nothing here talks to the board.

  render_result.py --elf ~/models/lenet5 --uart out/results/lenet5-....uart.txt
      [--color auto|always|never] [--summary $GITHUB_STEP_SUMMARY] [--png out.png]

Prints: the input image (ANSI 256-colour half blocks), top-5 with bars and labels
(MNIST digits / CIFAR-100 / COCO), YOLO detections, or the CharRNN token stream.
Labels follow the output shape (10 -> digits, 100 -> CIFAR-100,
13x13+26x26x255 -> YOLOv3-tiny on COCO; checked against the input images on
11/10: 7, tulip, person x3 + bus). The model ELFs carry no label table.
"""
import argparse
import math
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from elfsym import Elf  # noqa: E402

CIFAR100 = (
    "apple aquarium_fish baby bear beaver bed bee beetle bicycle bottle bowl boy bridge bus "
    "butterfly camel can castle caterpillar cattle chair chimpanzee clock cloud cockroach couch "
    "crab crocodile cup dinosaur dolphin elephant flatfish forest fox girl hamster house kangaroo "
    "keyboard lamp lawn_mower leopard lion lizard lobster man maple_tree motorcycle mountain mouse "
    "mushroom oak_tree orange orchid otter palm_tree pear pickup_truck pine_tree plain plate poppy "
    "porcupine possum rabbit raccoon ray road rocket rose sea seal shark shrew skunk skyscraper "
    "snail snake spider squirrel streetcar sunflower sweet_pepper table tank telephone television "
    "tiger tractor train trout tulip turtle wardrobe whale willow_tree wolf woman worm").split()
COCO = (
    "person bicycle car motorcycle airplane bus train truck boat traffic_light fire_hydrant "
    "stop_sign parking_meter bench bird cat dog horse sheep cow elephant bear zebra giraffe "
    "backpack umbrella handbag tie suitcase frisbee skis snowboard sports_ball kite baseball_bat "
    "baseball_glove skateboard surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl "
    "banana apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch potted_plant "
    "bed dining_table toilet tv laptop mouse remote keyboard cell_phone microwave oven toaster sink "
    "refrigerator book clock vase scissors teddy_bear hair_drier toothbrush").split()
# YOLOv3-tiny: 13x13 head uses anchors 3,4,5; 26x26 head uses 0,1,2 (416 input).
# (darknet cfg says 1,2,3 for the second head; this model matches 0,1,2: with 1,2,3
# the small person at the right edge decodes too big and NMS removes it.)
ANCHORS = [(10, 14), (23, 27), (37, 58), (81, 82), (135, 169), (344, 319)]
HEADS = {13: (3, 4, 5), 26: (0, 1, 2)}
BOX_COLORS = [(255, 64, 64), (64, 255, 64), (64, 160, 255), (255, 220, 0), (255, 0, 255),
              (0, 255, 255)]


# ---------------------------------------------------------------- inputs/outputs
def read_uart(path):
    vals, model = {}, None
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "@@BEGIN":
                model = parts[1]
                continue
            words = [p for p in parts[1:] if not p.startswith("=")]
            try:
                vals[parts[0]] = [int(w, 16) for w in words]
            except ValueError:
                pass
    return model, vals


def words_f32(words):
    return np.frombuffer(struct.pack("<%dI" % len(words), *words), "<f4")


def model_inputs(elf):
    out, i = [], 0
    while ("model_input%d_data" % i) in elf.syms:
        data = elf.sym("model_input%d_data" % i)
        shp = elf.sym("model_input%d_shape" % i)
        shape = struct.unpack("<%di" % (len(shp) // 4), shp) if shp else None
        out.append((data, shape))
        i += 1
    return out


def output_elems(elf, total):
    b = elf.sym("model_output_elems")
    return list(struct.unpack("<%di" % (len(b) // 4), b)) if b else [total]


# ---------------------------------------------------------------- terminal drawing
class Term:
    def __init__(self, color):
        self.color = color

    def c256(self, rgb):
        r, g, b = (int(max(0, min(255, v))) for v in rgb)
        if abs(r - g) < 10 and abs(g - b) < 10:  # grey ramp is finer
            if r < 8:
                return 16
            if r > 238:
                return 231
            return 232 + (r - 8) * 24 // 231
        return 16 + 36 * (r * 6 // 256) + 6 * (g * 6 // 256) + (b * 6 // 256)

    def image(self, rgb):
        """rgb: HxWx3 uint8. Two pixel rows per text line (upper half block)."""
        h, w, _ = rgb.shape
        lines = []
        if not self.color:
            ramp = " .:-=+*#%@"
            grey = rgb.mean(axis=2)
            for y in range(0, h, 2):
                lines.append("  " + "".join(ramp[int(v) * (len(ramp) - 1) // 255]
                                            for v in grey[y]))
            return lines
        for y in range(0, h, 2):
            s, last = [], None
            for x in range(w):
                top = self.c256(rgb[y, x])
                bot = self.c256(rgb[y + 1, x]) if y + 1 < h else 16
                if (top, bot) != last:  # only emit a colour change
                    s.append("\x1b[38;5;%d;48;5;%dm" % (top, bot))
                    last = (top, bot)
                s.append("▀")
            lines.append("  " + "".join(s) + "\x1b[0m")
        return lines

    def bold(self, s):
        return "\x1b[1m%s\x1b[0m" % s if self.color else s


def to_rgb(chw):
    """CxHxW float -> HxWx3 uint8, scaled to its own min..max."""
    a = np.asarray(chw, dtype=np.float32)
    if a.shape[0] == 1:
        a = np.repeat(a, 3, axis=0)
    lo, hi = float(a.min()), float(a.max())
    a = (a - lo) / (hi - lo if hi > lo else 1.0)
    return (a.transpose(1, 2, 0) * 255 + 0.5).astype(np.uint8)


def resize(rgb, w, h):
    ys = (np.arange(h) * rgb.shape[0] / h).astype(int)
    xs = (np.arange(w) * rgb.shape[1] / w).astype(int)
    return rgb[ys][:, xs]


def bar(p, width=30):
    n = p * width
    full = int(n)
    return "█" * full + ("▌" if n - full >= 0.5 else "")


def softmax(x):
    e = np.exp(x - x.max())
    return e / e.sum()


def topk_lines(logits, labels, k=5):
    p = softmax(logits.astype(np.float64))
    order = np.argsort(-p)[:k]
    rows = []
    for rank, i in enumerate(order, 1):
        name = labels[i] if labels and i < len(labels) else "#%d" % i
        rows.append((rank, int(i), name, float(logits[i]), float(p[i])))
    return rows


# ---------------------------------------------------------------- YOLO
def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def yolo_decode(outs, size=416, conf=0.3, nms=0.45):
    boxes = []
    for o in outs:
        g = int(round(math.sqrt(o.size / 255)))
        if g not in HEADS:
            continue
        t = o.reshape(3, 85, g, g)  # NCHW: channel = anchor*85 + field
        for a, ai in enumerate(HEADS[g]):
            obj = sigmoid(t[a, 4])
            cls = sigmoid(t[a, 5:])
            score = obj[None] * cls
            for c, y, x in zip(*np.nonzero(score > conf)):
                bx = (x + sigmoid(t[a, 0, y, x])) / g * size
                by = (y + sigmoid(t[a, 1, y, x])) / g * size
                bw = math.exp(min(t[a, 2, y, x], 10)) * ANCHORS[ai][0]
                bh = math.exp(min(t[a, 3, y, x], 10)) * ANCHORS[ai][1]
                boxes.append([float(score[c, y, x]), int(c), bx - bw / 2, by - bh / 2,
                              bx + bw / 2, by + bh / 2])
    boxes.sort(key=lambda b: -b[0])
    keep = []
    for b in boxes:
        if all(k[1] != b[1] or iou(k, b) < nms for k in keep):
            keep.append(b)
    return keep


def iou(a, b):
    ix = max(0.0, min(a[4], b[4]) - max(a[2], b[2]))
    iy = max(0.0, min(a[5], b[5]) - max(a[3], b[3]))
    inter = ix * iy
    ua = (a[4] - a[2]) * (a[5] - a[3]) + (b[4] - b[2]) * (b[5] - b[3]) - inter
    return inter / ua if ua > 0 else 0.0


def draw_boxes(rgb, boxes, thick):
    img = rgb.copy()
    h, w, _ = img.shape
    for n, b in enumerate(boxes):
        col = BOX_COLORS[n % len(BOX_COLORS)]
        x0, y0, x1, y1 = (int(round(v)) for v in b[2:])
        x0, x1 = max(0, x0), min(w - 1, x1)
        y0, y1 = max(0, y0), min(h - 1, y1)
        if x1 <= x0 or y1 <= y0:
            continue
        img[y0:y0 + thick, x0:x1 + 1] = col
        img[max(y0, y1 - thick + 1):y1 + 1, x0:x1 + 1] = col
        img[y0:y1 + 1, x0:x0 + thick] = col
        img[y0:y1 + 1, max(x0, x1 - thick + 1):x1 + 1] = col
    return img


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--elf", required=True)
    ap.add_argument("--uart", required=True)
    ap.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    ap.add_argument("--summary", help="append a markdown section (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--png", help="also write the input image (with boxes) as PNG")
    a = ap.parse_args()

    color = a.color == "always" or (a.color == "auto" and (
        sys.stdout.isatty() or os.environ.get("GITHUB_ACTIONS") == "true"))
    term = Term(color)
    elf = Elf(a.elf)
    name, vals = read_uart(a.uart)
    name = name or os.path.basename(a.elf)
    out = words_f32(vals.get("inference_output", []))
    sizes = output_elems(elf, out.size)
    outs, pos = [], 0
    for n in sizes:
        outs.append(out[pos:pos + n])
        pos += n
    ins = model_inputs(elf)
    ret = vals.get("_ret", [None])[0]
    cyc = vals.get("cyc_invoke", [0])[0]

    p = print
    md = ["### %s" % name, ""]
    p(term.bold("== %s ==" % name))
    p("  _ret %s   추론 %d cycles = %.1f ms @ 50 MHz   출력 %s"
      % (ret, cyc, cyc / 50e3, " + ".join(str(n) for n in sizes)))
    md.append("`_ret` %s · 추론 **%.1f ms** (%d cycles @ 50 MHz) · 출력 %s"
              % (ret, cyc / 50e3, cyc, " + ".join(str(n) for n in sizes)))
    md.append("")

    img = None
    if ins and ins[0][1] and len(ins[0][1]) == 4 and ins[0][0] is not None:
        _, c, h, w = ins[0][1]
        img = to_rgb(np.frombuffer(ins[0][0], "<f4").reshape(c, h, w))

    if len(sizes) == 2 and set(int(round(math.sqrt(n / 255))) for n in sizes) == {13, 26}:
        boxes = yolo_decode(outs, size=img.shape[0] if img is not None else 416)
        if img is not None:
            boxed = draw_boxes(img, boxes, 3)
            p("\n  입력 %dx%d (박스 = 검출, 64x32 축소)" % (img.shape[1], img.shape[0]))
            for line in term.image(resize(boxed, 64, 64)):
                p(line)
            if a.png:
                save_png(boxed, a.png)
        p("\n  검출 %d개 (YOLOv3-tiny, COCO, score>0.3, NMS 0.45)" % len(boxes))
        md += ["| # | 클래스 | score | 박스 (x0,y0)-(x1,y1) |", "|---|---|---|---|"]
        for n, b in enumerate(boxes[:20], 1):
            lab = COCO[b[1]] if b[1] < len(COCO) else "#%d" % b[1]
            p("  %2d  %-14s %.4f  %s  (%4d,%4d)-(%4d,%4d)"
              % (n, lab, b[0], bar(b[0], 20), b[2], b[3], b[4], b[5]))
            md.append("| %d | %s | %.4f | (%d,%d)-(%d,%d) |" % (n, lab, b[0], *b[2:]))
        if not boxes:
            md.append("| - | (없음) | | |")
    elif len(ins) == 3 and len(sizes) == 3:  # CharRNN: tokens, h, c -> logits, h, c
        toks = np.frombuffer(ins[0][0], "<i8") if ins[0][0] else []
        p("\n  입력 문자 번호 %d개: %s" % (len(toks), " ".join(str(int(t)) for t in toks)))
        p("  (모델 ELF에 vocab 표가 없어 문자 번호로 표시)")
        rows = topk_lines(outs[0], None)
        p("\n  다음 문자 top-5 (vocab %d)" % sizes[0])
        md.append("입력 문자 번호: `%s`" % " ".join(str(int(t)) for t in toks))
        md.append("")
        md += topk_md(rows)
        for r in rows:
            p("  %d. #%-3d  logit %8.4f  p %.4f  %s" % (r[0], r[1], r[3], r[4], bar(r[4])))
        p("  h: min %.3f max %.3f   c: min %.3f max %.3f"
          % (outs[1].min(), outs[1].max(), outs[2].min(), outs[2].max()))
    else:
        labels = (list("0123456789") if sizes[0] == 10 else
                  CIFAR100 if sizes[0] == 100 else None)
        tag = {10: "MNIST 숫자", 100: "CIFAR-100"}.get(sizes[0], "번호")
        if img is not None:
            scale = max(1, 64 // img.shape[1])
            big = resize(img, img.shape[1] * scale, img.shape[0] * scale)
            p("\n  입력 %dx%dx%d" % (img.shape[1], img.shape[0], ins[0][1][1]))
            for line in term.image(big):
                p(line)
            if a.png:
                save_png(big, a.png)
        rows = topk_lines(outs[0], labels)
        p("\n  top-5 (%s)" % tag)
        for r in rows:
            p("  %d. %-14s logit %8.4f  p %.4f  %s" % (r[0], r[2], r[3], r[4], bar(r[4])))
        p("\n  결과: %s (#%d, p %.3f)" % (term.bold(rows[0][2]), rows[0][1], rows[0][4]))
        md += topk_md(rows)
    p("== end %s ==" % name)
    md.append("")
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("\n".join(md) + "\n")


def topk_md(rows):
    md = ["| 순위 | 클래스 | logit | 확률 |", "|---|---|---|---|"]
    for r in rows:
        md.append("| %d | %s (#%d) | %.4f | %.4f |" % (r[0], r[2], r[1], r[3], r[4]))
    return md


def save_png(rgb, path):
    try:
        from PIL import Image
    except ImportError:
        return
    k = max(1, 256 // rgb.shape[1])  # small inputs: nearest-neighbour up to >= 256 px
    Image.fromarray(rgb.repeat(k, axis=0).repeat(k, axis=1)).save(path)


if __name__ == "__main__":
    main()
