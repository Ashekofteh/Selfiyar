@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bahonar_nut/adapter/captcha/captcha_solver.dart';
import 'package:test/test.dart';

/// Runs the real solver against captured samples.
///
/// The `recon/` directory holds images pulled from the live portal during
/// reconnaissance and is git-ignored (it also contains session artifacts), so
/// this test skips cleanly when it is absent rather than failing on a fresh
/// clone. Run it locally after capturing samples to re-verify the recogniser.
void main() {
  final reconDir = Directory('recon');

  bool hasRecon() => reconDir.existsSync();

  Uint8List read(String path) => File(path).readAsBytesSync();

  group('CaptchaSolver on real samples', () {
    setUpAll(() {
      if (!hasRecon()) {
        // ignore: avoid_print
        print('recon/ absent - skipping live-sample solver tests');
      }
    });

    test('solves every holdout sample correctly (30 unseen images)', () {
      if (!hasRecon()) return;

      // Labels read from the images by a human, then cross-checked against the
      // template match. These 30 were never used to build the templates.
      const expected = {
        'h00': '6138',
        'h01': '3939',
        'h02': '3175',
        'h03': '9741',
        'h04': '5832',
        'h05': '3634',
        'h06': '8489',
        'h07': '4857',
        'h08': '9712',
        'h09': '8948',
        'h10': '5039',
        'h11': '8460',
        'h12': '7696',
        'h13': '7973',
        'h14': '4063',
        'h15': '3299',
        'h16': '8155',
        'h17': '2811',
        'h18': '7667',
        'h19': '3758',
        'h20': '1559',
        'h21': '6415',
        'h22': '2506',
        'h23': '7362',
        'h24': '2018',
        'h25': '1254',
        'h26': '6109',
        'h27': '3911',
        'h28': '8767',
        'h29': '9043',
      };

      final solver = CaptchaSolver();
      final failures = <String>[];

      expected.forEach((name, label) {
        final path = 'recon/$name.png';
        if (!File(path).existsSync()) return;
        final solution = solver.solve(read(path));
        if (solution.text != label) {
          failures.add(
            '$name: expected $label, got ${solution.text} '
            '(confidence ${solution.confidence.toStringAsFixed(3)})',
          );
        }
      });

      // Only assert when samples are actually present.
      final present = expected.keys
          .where((n) => File('recon/$n.png').existsSync())
          .length;
      if (present == 0) return;

      expect(
        failures,
        isEmpty,
        reason: 'solver misreads:\n${failures.join('\n')}',
      );
    });

    test('solves training samples correctly (60 images)', () {
      if (!hasRecon()) return;

      const expected = {
        't00': '8024',
        't01': '2681',
        't02': '1916',
        't03': '5338',
        't04': '3139',
        't05': '7995',
        't06': '7231',
        't07': '5032',
        't08': '2834',
        't09': '7690',
        't10': '2346',
        't11': '1582',
        't12': '8148',
        't13': '4239',
        't14': '9095',
        't15': '5185',
        't16': '8607',
        't17': '7843',
        't18': '4210',
        't19': '3446',
        't20': '6867',
        't21': '9248',
        't22': '3904',
        't23': '3140',
        't24': '6562',
        't25': '5797',
        't26': '9219',
        't27': '8455',
        't28': '3111',
        't29': '7967',
        't30': '5768',
        't31': '5004',
        't32': '8426',
        't33': '9372',
        't34': '7174',
        't35': '1830',
        't36': '2777',
        't37': '9802',
        't38': '9037',
        't39': '6839',
        't40': '6075',
        't41': '3876',
        't42': '7298',
        't43': '3388',
        't44': '8244',
        't45': '2901',
        't46': '5281',
        't47': '3083',
        't48': '6504',
        't49': '4306',
        't50': '3542',
        't51': '8397',
        't52': '3054',
        't53': '9620',
        't54': '8856',
        't55': '6658',
        't56': '1314',
        't57': '2261',
        't58': '1496',
        't59': '4918',
      };

      final solver = CaptchaSolver();
      final failures = <String>[];
      var present = 0;

      expected.forEach((name, label) {
        final path = 'recon/$name.png';
        if (!File(path).existsSync()) return;
        present++;
        final solution = solver.solve(read(path));
        if (solution.text != label) {
          failures.add('$name: expected $label, got ${solution.text}');
        }
      });

      if (present == 0) return;
      expect(
        failures,
        isEmpty,
        reason: 'solver misreads:\n${failures.join('\n')}',
      );
    });

    test('the pixel threshold is not brittle (150..205 all correct)', () {
      if (!hasRecon()) return;

      final solver = CaptchaSolver();
      const sample = 'h00';
      const label = '6138';
      if (!File('recon/$sample.png').existsSync()) return;

      final bytes = read('recon/$sample.png');
      for (final threshold in [150, 165, 175, 185, 195, 205]) {
        final solution = solver.solve(bytes, threshold: threshold);
        expect(
          solution.text,
          label,
          reason: 'threshold $threshold changed the reading',
        );
      }
    });
  });

  group('CaptchaSolver robustness', () {
    test('declines on undecodable input rather than guessing', () {
      final solver = CaptchaSolver();
      final solution = solver.solve(Uint8List.fromList([1, 2, 3, 4]));
      expect(solution.text, isNull);
      expect(solution.isConfident, isFalse);
    });

    test('declines on empty input', () {
      final solver = CaptchaSolver();
      final solution = solver.solve(Uint8List(0));
      expect(solution.text, isNull);
    });
  });
}
