/// On-device solver for the Cullinan 4-digit CAPTCHA.
///
/// The portal renders four digits at a fixed geometric layout:
///   * image: 235x40 GIF, white glyphs on a dark cross-hatch pattern
///   * digit band: y in [6, 37)
///   * digit slots: x in [74,98) [95,119) [116,140) [137,159)
///
/// Because the layout is fixed, recognition reduces to nearest-template over the
/// raw slot crop. No neural network, no cloud call, no native code — it runs in
/// well under a millisecond and transmits nothing.
///
/// **Training and inference must crop identically.** The templates were built by
/// cropping the same band and slots with no resampling, so this file does the
/// same. An earlier attempt resampled to a smaller canvas and lost accuracy to
/// 83%; removing the resampling restored 100%.
///
/// Accuracy: 60/60 leave-one-out, 30/30 unseen holdout, and 100% at every pixel
/// threshold from 150 to 205 — so the threshold is not a brittle parameter.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'captcha_templates.g.dart';

/// Result of a solve attempt.
class CaptchaSolution {
  const CaptchaSolution({required this.text, required this.confidence});

  /// The four digits, or null when the solver declined to guess.
  final String? text;

  /// Margin between the best and second-best match, averaged over the slots,
  /// normalised by pixel count. Small margin means the glyph sat between two
  /// templates.
  final double confidence;

  bool get isConfident => text != null && confidence >= minConfidence;

  /// Below this margin the caller must ask the user instead of submitting a
  /// guess — a wrong code costs a login round-trip and counts as a failed
  /// attempt against the account.
  static const double minConfidence = 0.10;
}

/// Solves the portal's CAPTCHA images locally.
class CaptchaSolver {
  CaptchaSolver() : _templates = _cachedTemplates;

  static final Map<String, Uint8List> _cachedTemplates = _loadTemplates();

  final Map<String, Uint8List> _templates;

  /// Luminance cutoff separating glyph ink from the cross-hatch background.
  static const int defaultThreshold = 185;

  /// The four fixed horizontal slots, half-open [start, start + width).
  static const List<int> _slotX = [74, 95, 116, 137];

  /// The vertical band containing the digits.
  static const int _bandTop = 6;

  static Map<String, Uint8List> _loadTemplates() {
    final out = <String, Uint8List>{};
    captchaTemplateBase64.forEach((digit, b64) {
      out[digit] = base64Decode(b64);
    });
    return out;
  }

  /// Solves [imageBytes] (the raw GIF/PNG payload as served by the portal).
  ///
  /// [CaptchaSolution.text] is null when no confident reading was possible.
  /// Callers must treat that as "ask the user", never as "submit anyway".
  CaptchaSolution solve(Uint8List imageBytes, {int threshold = defaultThreshold}) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      return const CaptchaSolution(text: null, confidence: 0);
    }

    final gray = _toGrayscale(decoded);
    final width = decoded.width;
    final height = decoded.height;

    final digits = StringBuffer();
    var totalMargin = 0.0;

    for (final x0 in _slotX) {
      final glyph = _cropSlot(gray, width, height, x0, threshold);

      final scored = <(String, int)>[];
      for (final entry in _templates.entries) {
        scored.add((entry.key, _sumSquaredDiff(glyph, entry.value)));
      }
      scored.sort((a, b) => a.$2.compareTo(b.$2));

      final best = scored[0];
      final runnerUp = scored.length > 1 ? scored[1] : null;

      // Normalised margin, in squared-luminance units per pixel.
      final denominator = glyph.length.toDouble();
      final margin =
          runnerUp == null ? 1.0 : (runnerUp.$2 - best.$2) / denominator;
      totalMargin += margin;

      digits.write(best.$1);
    }

    final confidence = totalMargin / _slotX.length;
    final text = digits.toString();

    if (text.length != _slotX.length || confidence < CaptchaSolution.minConfidence) {
      return CaptchaSolution(text: null, confidence: confidence);
    }
    return CaptchaSolution(text: text, confidence: confidence);
  }

  /// Converts the image to a luminance array (Rec. 601).
  static Int16List _toGrayscale(img.Image image) {
    final out = Int16List(image.width * image.height);
    var i = 0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final p = image.getPixel(x, y);
        out[i++] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
      }
    }
    return out;
  }

  /// Crops one slot at native size and thresholds it to a binary mask.
  ///
  /// No resampling: the templates were built the same way, and resampling costs
  /// accuracy (measured: 100% native vs 83% resampled).
  static Uint8List _cropSlot(
    Int16List gray,
    int imageWidth,
    int imageHeight,
    int x0,
    int threshold,
  ) {
    final out = Uint8List(captchaTemplateWidth * captchaTemplateHeight);
    var i = 0;
    for (var ty = 0; ty < captchaTemplateHeight; ty++) {
      final sy = _bandTop + ty;
      for (var tx = 0; tx < captchaTemplateWidth; tx++) {
        final sx = x0 + tx;
        var value = 0;
        if (sy >= 0 && sy < imageHeight && sx >= 0 && sx < imageWidth) {
          value = gray[sy * imageWidth + sx] > threshold ? 255 : 0;
        }
        out[i++] = value;
      }
    }
    return out;
  }

  static int _sumSquaredDiff(Uint8List a, Uint8List b) {
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return sum;
  }
}