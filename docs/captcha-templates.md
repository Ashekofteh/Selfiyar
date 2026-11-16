# CAPTCHA glyph templates

`lib/adapter/captcha/captcha_templates.g.dart` is a **generated, checked-in**
file. The app cannot log in without it: `CaptchaSolver` recognises the portal's
four-digit CAPTCHA entirely on-device by comparing the live glyph crops against
the per-digit templates in that file.

It is generated outside the app because the source material is live CAPTCHA
images, which must not be committed. This page is the complete procedure for
recreating the file locally.

- Generator: [`scripts/gen_captcha_templates.py`](../scripts/gen_captcha_templates.py)
- Labels: [`scripts/captcha_labels.json`](../scripts/captcha_labels.json)
- Generated output: [`lib/adapter/captcha/captcha_templates.g.dart`](../lib/adapter/captcha/captcha_templates.g.dart)
- Solver: [`lib/adapter/captcha/captcha_solver.dart`](../lib/adapter/captcha/captcha_solver.dart)
- Solver tests: [`test/adapter/captcha/captcha_solver_test.dart`](../test/adapter/captcha/captcha_solver_test.dart)

## Prerequisites

- Python 3.10 or newer.
- Pillow and NumPy:

  ```bash
  python -m pip install --upgrade Pillow numpy
  ```

- The command must run from the repository root, because the script's paths are
  relative to the current directory.
- The training images described below. A fresh clone does **not** contain them.

## What `recon/` is, and why it is not in git

`recon/` is the local reconnaissance workspace used while reverse-engineering
the portal. It holds page captures, logs, CAPTCHA images, and sometimes session
cookies or other authenticated artifacts. **The whole directory is git-ignored**
(see `.gitignore`), both because the files are large and because they may
contain personal data. Never commit it, and do not share raw captures
publicly.

For CAPTCHA generation, only these files matter:

| File | Purpose |
|---|---|
| `recon/t00.png` … `recon/t59.png` | Training samples. These build the templates. |
| `recon/h00.png` … `recon/h29.png` | Holdout samples. Never used for training; they measure generalisation. |
| `scripts/captcha_labels.json` | Hand-read labels for both sets. Committed, because labels are not personal data. |

The PNGs are small crops of the CAPTCHA image as the portal serves it. Prefer
saving the image bytes without resizing, re-cropping, or re-compressing them:
training and inference use the same native geometry, and that is what keeps
accuracy at 100%.

## Collecting samples

1. Open the Shahid Bahonar dining portal login page
   (`https://nut.uk.ac.ir/`) in a browser. Refresh until a CAPTCHA is shown.
2. Save the CAPTCHA image itself (the small GIF/PNG, not a screenshot of the
   page) into `recon/`. A screenshot is acceptable only if the image is cropped
   back to the portal's native 235×40 layout; resizing it will break the slot
   geometry.
3. Name the file `tNN.png` for a training sample or `hNN.png` for a holdout
   sample, where `NN` is a two-digit number with no gaps. Keep the next free
   number so existing labels stay valid.
4. Read the four digits yourself and add the label to
   `scripts/captcha_labels.json`:

   ```json
   {
     "train": {
       "t60": "1234"
     },
     "holdout": {
       "h30": "5678"
     }
   }
   ```

   The key must match the file name exactly. Holdout labels are not read by the
   generator, but they are used by the solver test and are needed to measure
   generalisation.
5. Add the same holdout/training expectations to the `expected` maps in
   `test/adapter/captcha/captcha_solver_test.dart` when adding new samples that
   the test should verify. (The labels are duplicated there today; keep the two
   copies in sync.)

Do not mix other artifacts into the training set. The generator reads only
`t*.png`, so a stray `login.html`, `cookies.txt`, or `p*.png` screenshot in
`recon/` is harmless to it — but it is still personal data and still must not
be committed.

## Regenerating the templates

From the repository root:

```bash
python scripts/gen_captcha_templates.py
```

The script:

1. Loads `scripts/captcha_labels.json` and finds the named files in `recon/`.
2. Crops the fixed vertical band and four digit slots from every training
   image, with no resampling.
3. Builds the mean binary crop per digit.
4. Runs **leave-one-out** validation: it rebuilds the templates without each
   sample and checks that the sample still matches its own label. If any sample
   fails, the script exits with a mismatch list instead of writing a poisoned
   template file.
5. Writes `lib/adapter/captcha/captcha_templates.g.dart`.

Expected output with the current 60 training samples:

```text
wrote lib/adapter/captcha/captcha_templates.g.dart from 60 samples
```

If the samples and labels are unchanged, regenerating should leave the
checked-in file byte-identical. A diff means the inputs, the crop geometry, or
the label set changed — inspect it before committing.

## Verifying a regeneration

```bash
# The solver against the live samples in recon/ (skips cleanly if absent).
flutter test test/adapter/captcha/captcha_solver_test.dart

# The full suite and the analyzer.
flutter test
flutter analyze
```

The solver test checks all 60 training samples and all 30 holdout samples when
`recon/` is present. On a machine without the captures it skips rather than
failing, which is why the generated file is checked in.

Commit these together:

- `lib/adapter/captcha/captcha_templates.g.dart`
- `scripts/captcha_labels.json` (if labels changed)
- `lib/adapter/captcha/captcha_solver.dart` and/or the generator (only if the
  geometry changed)
- `test/adapter/captcha/captcha_solver_test.dart` (if new samples were added)

Never commit `recon/` or `captures/`.

## The geometry contract

The generator and the solver must crop **identically**. The current constants
are duplicated deliberately in both places:

| Constant | Value |
|---|---|
| Image size | 235×40 (portal GIF) |
| Digit band | `y` in `[6, 37)` — height 31 |
| Slot left edges | `x = 74, 95, 116, 137` |
| Slot width | 24 |
| Luminance threshold | 185 (training was 100% from 150 to 205) |

If the portal changes its CAPTCHA layout:

1. Re-measure the band and slots from fresh captures.
2. Update `BAND_TOP`, `BAND_BOTTOM`, `SLOT_X`, `SLOT_W`, and `THRESHOLD` in
   `scripts/gen_captcha_templates.py`.
3. Update the matching constants in `lib/adapter/captcha/captcha_solver.dart`.
4. Re-capture the training and holdout sets, regenerate, and run the solver
   tests.
5. Update this table and the geometry comment in the solver.

Do not add resampling to either side to make an old sample fit. It was measured
to drop accuracy from 100% to 83%; re-capture instead.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ModuleNotFoundError: No module named 'PIL'` (or `numpy`) | Install the prerequisites: `python -m pip install Pillow numpy`. |
| `missing scripts/captcha_labels.json` | Run the script from the repository root. |
| `no training samples found in recon/` | `recon/` is absent or the images are not named `tNN.png`. Re-capture or obtain the samples. |
| `no training samples for digit 3` | The training set has no sample containing that digit. Add one to every digit bucket (all ten digits need at least one sample). |
| `leave-one-out mismatch - a label is wrong` | A label does not match its image, or an image was resized/corrupted. Re-read the digits, fix `captcha_labels.json`, and rerun. Do not bypass the check. |
| Generated file changed with no sample changes | Check that Pillow/NumPy did not change crop behaviour and that the images were not resampled. Inspect the diff before committing. |

## Automated coverage

CI runs `flutter analyze`, `dart test test/core`, `flutter test`, an Android
build, and the native Android unit tests. The CAPTCHA solver is covered by
`test/adapter/captcha/captcha_solver_test.dart`; its live-sample assertions are
conditional on `recon/` being present, so CI verifies the generated templates
load and the solver's pure logic runs, while a maintainer with captures verifies
the 100% recognition claim locally.
