/// HTML parsing helpers for the Cullinan portal.
///
/// Hand-rolled rather than pulled from a package, for two reasons: the portal's
/// markup is small and known, and a dependency-free parser keeps the adapter
/// auditable against the live HTML that produced it. The risk with hand-rolled
/// parsing is silent breakage when the site changes, which is why every parser
/// here is paired with a test against a captured fixture.
library;

/// A parsed `<select>`.
class ParsedSelect {
  const ParsedSelect({
    required this.name,
    required this.options,
    this.selectedValue,
  });

  final String name;
  final List<ParsedOption> options;

  /// The value of the option marked `selected`, when there is one.
  final String? selectedValue;

  /// The option with the given value, or null.
  ParsedOption? optionWithValue(String value) {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  /// The selected option, or the first one.
  ParsedOption? get selected =>
      selectedValue != null ? optionWithValue(selectedValue!) : null;
}

class ParsedOption {
  const ParsedOption({required this.value, required this.text});

  final String value;
  final String text;
}

/// A parsed `<tr>`.
class ParsedRow {
  const ParsedRow({required this.cells, required this.raw});

  final List<String> cells;
  final String raw;

  /// Cell [index], or an empty string when the row is short.
  String cell(int index) => index < cells.length ? cells[index] : '';
}

/// The status the portal renders in a grid row's status cell.
///
/// The grid's last column carries a small icon whose `src` says what the row
/// is. Four are in use, and the distinction matters because a checked
/// checkbox is NOT the same as a held meal: the portal echoes back the
/// checkbox state it was posted, so a row can render `checked` while
/// carrying no reservation at all (F13).
///
/// | icon | meaning | held? |
/// |---|---|---|
/// | `AcceptGreen16` | «رزرو شده» — reserved | yes |
/// | `lockAcceptGreen24` | «رزرو شده، خورده نشده، غیرفعال» — reserved, and locked | yes |
/// | `Token_Eating20` | «خورده شده» — the meal was **eaten** | yes |
/// | `Eating16` | «خورده شده» — the meal was **eaten** | yes |
/// | `lock24` | «غیرفعال» — locked, and not reserved | no |
///
/// An eaten meal **is** held: it was charged, and the money moved. The
/// portal renders it with a different icon, but it is the same commitment.
class RowStatus {
  const RowStatus({
    this.held = false,
    this.locked = false,
    this.consumed = false,
  });

  /// The row carries no status icon, or one that means nothing to us.
  static const RowStatus none = RowStatus();

  /// The row is a genuine reservation.
  final bool held;

  /// The row's date is past its cutoff, so it cannot be changed.
  final bool locked;

  /// The meal has been collected / eaten at the cafeteria turns.
  final bool consumed;
}

/// The status of a grid row, read from its status icon.
///
/// Returns [RowStatus.none] when the row carries no status icon, which is
/// what an ordinary, unbooked row looks like.
final RegExp _imgStatusPattern = RegExp(
  r'<img[^>]*id="[^"]*imgStaus[^"]*"[^>]*>',
  dotAll: true,
);

final RegExp _selectPattern = RegExp(
  r'<select([^>]*)>(.*?)</select>',
  dotAll: true,
);

final RegExp _optionPattern = RegExp(
  r'<option([^>]*)>(.*?)</option>',
  dotAll: true,
);

final RegExp _trPattern = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true);
final RegExp _tdPattern = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true);
final RegExp _inputPattern = RegExp(r'<input([^>]*)>', dotAll: true);

final RegExp _htmlTagPattern = RegExp(r'<[^>]*>');
final RegExp _whitespacePattern = RegExp(r'\s+');

final RegExp _amountPattern = RegExp(r'([\d۰-۹][\d۰-۹\s٬,]*)\s*ریال');
final RegExp _digitsPattern = RegExp(r'[\d۰-۹][\d۰-۹\s٬,]*');
final RegExp _trailingPunctPattern = RegExp(r'[\s٬,]+$');

RowStatus rowStatus(String rowHtml) {
  final match = _imgStatusPattern.firstMatch(rowHtml);
  if (match == null) return RowStatus.none;

  final tag = match.group(0)!;
  if (tag.contains('Token_Eating20') ||
      tag.contains('Eating16') ||
      (tag.contains('خورده شده') && !tag.contains('خورده نشده'))) {
    // Eaten / Consumed — charged, locked, and collected.
    return const RowStatus(held: true, locked: true, consumed: true);
  }
  if (tag.contains('lockAcceptGreen24')) {
    return const RowStatus(held: true, locked: true);
  }
  if (tag.contains('AcceptGreen') || tag.contains('رزرو شده')) {
    return const RowStatus(held: true);
  }
  if (tag.contains('lock24')) {
    return const RowStatus(locked: true);
  }
  return RowStatus.none;
}


/// A parsed `<input>`.
class ParsedInput {
  const ParsedInput({
    required this.name,
    required this.id,
    required this.type,
    required this.value,
    required this.checked,
    required this.disabled,
  });

  final String name;
  final String id;
  final String type;
  final String value;
  final bool checked;
  final bool disabled;
}

/// Extracts the value of a hidden input by id or name.
String hiddenFieldValue(String html, String nameOrId) {
  final byId = RegExp(
    '<input[^>]*id="${RegExp.escape(nameOrId)}"[^>]*value="([^"]*)"',
    dotAll: true,
  ).firstMatch(html);
  if (byId != null) return byId.group(1)!;

  final byName = RegExp(
    '<input[^>]*name="${RegExp.escape(nameOrId)}"[^>]*value="([^"]*)"',
    dotAll: true,
  ).firstMatch(html);
  return byName?.group(1) ?? '';
}

/// Extracts the text of a `<label>` by id.
String? labelText(String html, String id) {
  final match = RegExp(
    '<label[^>]*id="${RegExp.escape(id)}"[^>]*>(.*?)</label>',
    dotAll: true,
  ).firstMatch(html);
  if (match == null) return null;
  final text = stripTags(match.group(1)!);
  return text.isEmpty ? null : text;
}

/// Extracts the text of any element with the given id.
String? elementText(String html, String id) {
  final match = RegExp(
    '<(label|span|div|td)[^>]*id="[^"]*${RegExp.escape(id)}"[^>]*>(.*?)</\\1>',
    dotAll: true,
  ).firstMatch(html);
  if (match == null) return null;
  final text = stripTags(match.group(2)!);
  return text.isEmpty ? null : text;
}

/// Every `<select>` in [html].
List<ParsedSelect> selects(String html) {
  final out = <ParsedSelect>[];
  for (final match in _selectPattern.allMatches(html)) {
    final attributes = match.group(1)!;
    final name = _attribute(attributes, 'name') ?? '';
    final options = <ParsedOption>[];
    String? selected;

    for (final optionMatch in _optionPattern.allMatches(match.group(2)!)) {
      final optionAttributes = optionMatch.group(1)!;
      final value = _attribute(optionAttributes, 'value');
      final text = stripTags(optionMatch.group(2)!);
      final optionValue = value ?? text;
      options.add(ParsedOption(value: optionValue, text: text));
      if (_attribute(optionAttributes, 'selected') != null &&
          selected == null) {
        selected = optionValue;
      }
    }

    out.add(ParsedSelect(
      name: name,
      options: options,
      selectedValue: selected,
    ));
  }
  return out;
}

/// The `<select>` whose name ends with [suffix].
ParsedSelect? selectBySuffix(String html, String suffix) {
  for (final select in selects(html)) {
    if (select.name.endsWith(suffix)) return select;
  }
  return null;
}

/// Every `<select>` whose name ends with [suffix].
List<ParsedSelect> selectsBySuffix(String html, String suffix) =>
    selects(html).where((s) => s.name.endsWith(suffix)).toList();

/// The rows of the `<table>` whose id ends with [tableIdSuffix].
List<ParsedRow> tableRows(String html, String tableIdSuffix) {
  final table = RegExp(
    '<table[^>]*id="[^"]*${RegExp.escape(tableIdSuffix)}"[^>]*>(.*?)</table>',
    dotAll: true,
  ).firstMatch(html);
  if (table == null) return const [];

  final rows = <ParsedRow>[];
  for (final match in _trPattern.allMatches(table.group(1)!)) {
    final raw = match.group(1)!;
    final cells = _tdPattern
        .allMatches(raw)
        .map((m) => stripTags(m.group(1)!))
        .toList();
    rows.add(ParsedRow(cells: cells, raw: raw));
  }
  return rows;
}

/// The `<input>` elements inside [html].
List<ParsedInput> inputs(String html) {
  final out = <ParsedInput>[];
  for (final match in _inputPattern.allMatches(html)) {
    final attributes = match.group(1)!;
    out.add(ParsedInput(
      name: _attribute(attributes, 'name') ?? '',
      id: _attribute(attributes, 'id') ?? '',
      type: (_attribute(attributes, 'type') ?? 'text').toLowerCase(),
      value: _attribute(attributes, 'value') ?? '',
      checked: _attribute(attributes, 'checked') != null,
      disabled: _attribute(attributes, 'disabled') != null,
    ));
  }
  return out;
}

/// The first `<input>` whose name ends with [suffix].
ParsedInput? inputBySuffix(String html, String suffix) {
  for (final input in inputs(html)) {
    if (input.name.endsWith(suffix)) return input;
  }
  return null;
}

/// Strips tags and collapses whitespace.
///
/// Handles the Persian text the portal serves, which is RTL and often padded
/// with non-breaking spaces.
String stripTags(String html) => html
    .replaceAll(_htmlTagPattern, ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(_whitespacePattern, ' ')
    .trim();

/// Reads an attribute from a raw tag's attribute string.
String? _attribute(String attributes, String name) {
  final match = RegExp(
    '${RegExp.escape(name)}\\s*=\\s*"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(attributes);
  return match?.group(1);
}

/// Parses a Rial amount, tolerating separators and Persian digits.
///
/// The portal writes `225,000 ريال`; the value we need is the integer.
///
/// Only the *last* number in the string is the price. A dish name may carry
/// digits of its own — `تخم مرغ2عدد/نان/چای/قند 150000 ریال` — and reading
/// every digit in the string would make that dish cost 2,150,000 Rial instead
/// of 150,000. The currency word marks the amount when it is there; without
/// it, the amount is the last number the string carries.
int? parseRial(String text) {
  final source = _amountIn(text) ?? _lastNumberIn(text);
  if (source == null) return null;

  final buffer = StringBuffer();
  for (final rune in source.runes) {
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      // Persian digit -> ASCII.
      buffer.writeCharCode(rune - 0x06F0 + 0x30);
    } else if (rune >= 0x30 && rune <= 0x39) {
      buffer.writeCharCode(rune);
    }
    // Separators are dropped.
  }
  final digits = buffer.toString();
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}

/// The number immediately before the currency word, if there is one.
///
/// The word the portal writes the price with is matched here, so the amount
/// can be told apart from the digits in a dish's own name. That is parsing
/// portal text, never displaying an amount.
String? _amountIn(String text) => _amountPattern.firstMatch(text)?.group(1);

/// The last run of digits in the string.
String? _lastNumberIn(String text) {
  final matches = _digitsPattern.allMatches(text).toList();
  if (matches.isEmpty) return null;

  final last = matches.last.group(0)!;
  // A trailing separator or space is not part of the number.
  return last.trim().replaceFirst(_trailingPunctPattern, '');
}
