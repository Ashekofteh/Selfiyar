#!/usr/bin/env python
"""Regenerate lib/adapter/captcha/captcha_templates.g.dart from labelled samples.

Usage (from the repository root):
    python scripts/gen_captcha_templates.py

Reads:
    recon/t<N>.png                                training samples
    scripts/captcha_labels.json                   hand-read labels

Writes:
    lib/adapter/captcha/captcha_templates.g.dart

The training PNGs are git-ignored on purpose: they are live portal captures and
may sit beside session cookies. A fresh clone therefore needs the samples
re-captured (or obtained from a maintainer) before this script can run. See
docs/captcha-templates.md for the full capture and regeneration procedure.

The generated file embeds, per digit, the mean binary slot crop at native
resolution (24x31). captcha_solver.dart matches live crops against these with
sum-of-squared-differences, so this script and the solver MUST crop identically:
same band, same slots, no resampling. Resampling was measured to drop accuracy
from 100% to 83%, so do not reintroduce it.

The script self-checks: it runs leave-one-out and refuses to write output if any
sample fails to match its own label, which is how a mislabelled sample gets
caught rather than silently poisoning a template.
"""

import base64
import json
import os

from PIL import Image
import numpy as np

# Geometry measured across 20 live samples. The portal renders digits in a fixed
# layout, which is what makes template matching viable at all.
BAND_TOP, BAND_BOTTOM = 6, 37        # vertical band containing the digits
SLOT_X = [74, 95, 116, 137]          # left edge of each of the four slots
SLOT_W = 24                          # uniform crop width for all four slots
TEMPLATE_H = BAND_BOTTOM - BAND_TOP  # 31
THRESHOLD = 185                      # luminance cutoff; 150..205 all gave 100%

TRAIN_DIR = "recon"
LABELS_PATH = os.path.join("scripts", "captcha_labels.json")
OUT_PATH = os.path.join("lib", "adapter", "captcha", "captcha_templates.g.dart")


def extract_slots(path, threshold=THRESHOLD):
    """Crop the four digit slots from one sample as binary masks."""
    arr = np.array(Image.open(path).convert("L"))
    mask = (arr > threshold).astype(np.float32)
    slots = []
    for x0 in SLOT_X:
        sub = mask[BAND_TOP:BAND_BOTTOM, x0:x0 + SLOT_W]
        if sub.shape != (TEMPLATE_H, SLOT_W):
            padded = np.zeros((TEMPLATE_H, SLOT_W), dtype=np.float32)
            h = min(sub.shape[0], TEMPLATE_H)
            w = min(sub.shape[1], SLOT_W)
            padded[:h, :w] = sub[:h, :w]
            sub = padded
        slots.append(sub)
    return slots


def build_templates(entries):
    """Mean slot crop per digit, where entries is [(path, label), ...]."""
    buckets = {d: [] for d in "0123456789"}
    for path, label in entries:
        for pos, slot in enumerate(extract_slots(path)):
            buckets[label[pos]].append(slot)
    templates = {}
    for digit, slots in buckets.items():
        if not slots:
            raise SystemExit(f"no training samples for digit {digit}")
        templates[digit] = np.mean(np.stack(slots, axis=0), axis=0)
    return templates


def classify(slot, templates):
    best, best_dist = None, float("inf")
    for digit, template in templates.items():
        dist = float(np.sum((slot - template) ** 2))
        if dist < best_dist:
            best, best_dist = digit, dist
    return best


def main():
    if not os.path.exists(LABELS_PATH):
        raise SystemExit(f"missing {LABELS_PATH}")
    with open(LABELS_PATH, encoding="utf-8") as handle:
        labels = json.load(handle)

    train = []
    for name, label in labels["train"].items():
        path = os.path.join(TRAIN_DIR, f"{name}.png")
        if os.path.exists(path):
            train.append((path, label))
    if not train:
        raise SystemExit(
            f"no training samples found in {TRAIN_DIR}/. Re-capture them first "
            "(they are git-ignored as they sit alongside session artifacts)."
        )

    # Refuse to generate from data that disagrees with itself.
    failures = []
    for path, label in train:
        reduced = [(p, l) for p, l in train if p != path]
        predicted = "".join(
            classify(slot, build_templates(reduced)) for slot in extract_slots(path)
        )
        if predicted != label:
            failures.append(
                f"{os.path.basename(path)}: label={label} predicted={predicted}"
            )
    if failures:
        raise SystemExit(
            "leave-one-out mismatch - a label is wrong, fix it before regenerating:\n  "
            + "\n  ".join(failures)
        )

    templates = build_templates(train)
    quantised = {
        digit: (template * 255).round().astype(np.uint8)
        for digit, template in templates.items()
    }

    lines = []
    for digit in sorted(quantised):
        encoded = base64.b64encode(quantised[digit].tobytes()).decode()
        lines.append(f"  '{digit}': r\"{encoded}\",")
    body = "\n".join(lines)

    source = f'''// GENERATED FILE - do not edit by hand.
//
// Glyph templates for the Cullinan 4-digit CAPTCHA.
//
// Regenerate with: python scripts/gen_captcha_templates.py
// Labels: scripts/captcha_labels.json ({len(train)} samples)
//
// Each value is base64 of a raw {SLOT_W}x{TEMPLATE_H} uint8 luminance map
// (row-major), being the mean binary slot crop for that digit. Slots are cropped
// at native size with no resampling so training and inference agree exactly.
library;

/// Slot crop width in pixels.
const int captchaTemplateWidth = {SLOT_W};

/// Slot crop height in pixels.
const int captchaTemplateHeight = {TEMPLATE_H};

/// Digit (as a string) -> base64 of the {SLOT_W}x{TEMPLATE_H} uint8 template.
const Map<String, String> captchaTemplateBase64 = {{
{body}
}};
'''

    with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(source)
    print(f"wrote {OUT_PATH} from {len(train)} samples")


if __name__ == "__main__":
    main()
