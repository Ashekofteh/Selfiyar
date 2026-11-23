import 'package:bahonar_nut/adapter/cullinan/cullinan_parser.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

/// The basket's C1/C2 contract, on synthetic markup shaped like the live
/// `FoodBasketBuy.aspx` grid.
///
/// The live captures under `scratch/` and `recon/` are git-ignored and are
/// exercised by `cullinan_parser_test.dart` when present. These tests carry no
/// personal data and therefore run on every clone.
void main() {
  const halls = [('1', 'مرکزی برادران'), ('2', 'فنی برادران')];
  const breakfastFoods = [('64549', 'شیر/حلواشکری/نان/چای/قند 150000 ریال')];
  const lunchFoods = [
    ('64536', 'چلوخورشت سبزی,ماست 350000 ریال'),
    ('64538', 'استانبولی پلو با گوشت,سالاد فصل 350000 ریال'),
  ];
  final date = DateTime.utc(2026, 11, 25);

  group('basket listings', () {
    test('only the selected hall is a listing', () {
      final html = page([
        row(
          index: 0,
          slot: 'صبحانه',
          halls: halls,
          selectedHall: '1',
          foods: breakfastFoods,
        ),
      ]);

      final listings = CullinanParser.parseBasket(html, date);

      expect(listings, hasLength(1));
      expect(listings.single.hall.id, '1');
      expect(listings.single.option.id, '64549');
      expect(listings.single.priceRial, 150000);
      expect(listings.single.buyable, isTrue);
      expect(listings.any((l) => l.hall.id == '2'), isFalse);
    });

    test('a closed row is not a listing', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
          enabled: false,
        ),
      ]);

      expect(CullinanParser.parseBasket(html, date), isEmpty);

      final closed = CullinanParser.parseBasket(
        html,
        date,
        includeClosed: true,
      );
      expect(closed, hasLength(2));
      expect(closed.every((l) => l.buyable), isFalse);
      expect(closed.every((l) => l.hall.id == '1'), isTrue);
    });

    test('each row names its own selected hall', () {
      final html = page([
        row(
          index: 0,
          slot: 'صبحانه',
          halls: halls,
          selectedHall: '1',
          foods: breakfastFoods,
        ),
        row(
          index: 1,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '2',
          foods: lunchFoods,
        ),
      ]);

      final listings = CullinanParser.parseBasket(html, date);

      final breakfast = listings.where((l) => l.slot == MealSlot.breakfast);
      final lunch = listings.where((l) => l.slot == MealSlot.lunch);

      expect(breakfast.map((l) => l.hall.id), everyElement('1'));
      expect(lunch.map((l) => l.hall.id), everyElement('2'));
      expect(
        listings.any((l) => l.slot == MealSlot.lunch && l.hall.id == '1'),
        isFalse,
      );
    });

    test('a row without a selected hall yields nothing', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '',
          foods: lunchFoods,
        ),
      ]);

      expect(CullinanParser.parseBasket(html, date), isEmpty);
    });
  });

  group('claimFormBody', () {
    test('refuses a closed target row', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
          enabled: false,
        ),
      ]);

      final body = CullinanParser.claimFormBody(
        html,
        listingId: '64536',
        hallId: '1',
      );

      // No form body at all, so no `chkReserve=on` can reach the portal.
      expect(body, isNull);
    });

    test('refuses a hall the food list was not rendered for', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
        ),
      ]);

      final body = CullinanParser.claimFormBody(
        html,
        listingId: '64536',
        hallId: '2',
      );

      expect(body, isNull);
    });

    test('refuses an option the page does not offer', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
        ),
      ]);

      final body = CullinanParser.claimFormBody(
        html,
        listingId: '99999',
        hallId: '1',
      );

      expect(body, isNull);
    });

    test('selects the target and preserves every other row', () {
      final html = page([
        row(
          index: 0,
          slot: 'صبحانه',
          halls: halls,
          selectedHall: '1',
          foods: breakfastFoods,
          checked: true,
        ),
        row(
          index: 1,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
        ),
      ]);

      final body = CullinanParser.claimFormBody(
        html,
        listingId: '64538',
        hallId: '1',
        date: '1405/09/04',
      );

      expect(body, isNotNull);
      final form = body!;

      expect(form[r'ctl00$cphMain$txtDate'], '1405/09/04');
      expect(form[r'ctl00$cphMain$btnSave'], 'ذخیره');

      // The target row is checked and names the chosen dish.
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl03$chkReserve'],
        'on',
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl03$drpSelf'],
        '1',
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl03$drpFood'],
        '64538',
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl03$drpFoodCount'],
        '1',
      );

      // The other row is not released: its checked meal and selections travel
      // exactly as the page rendered them.
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl02$chkReserve'],
        'on',
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl02$drpFood'],
        '64549',
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl02$drpSelf'],
        '1',
      );
    });
  });

  group('hallSwitchBody', () {
    test('targets the row own hall dropdown and carries no save button', () {
      final html = page([
        row(
          index: 0,
          slot: 'صبحانه',
          halls: halls,
          selectedHall: '1',
          foods: breakfastFoods,
          checked: true,
        ),
        row(
          index: 1,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
        ),
      ]);

      final body = CullinanParser.hallSwitchBody(
        html,
        slot: MealSlot.lunch,
        hallId: '2',
        date: '1405/09/04',
      );

      expect(body, isNotNull);
      final form = body!;

      expect(
        form['__EVENTTARGET'],
        r'ctl00$cphMain$grdFoodBasketReservation$ctl03$drpSelf',
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl03$drpSelf'],
        '2',
      );
      expect(form['__EVENTARGUMENT'], '');
      expect(form[r'ctl00$cphMain$txtDate'], '1405/09/04');
      expect(form.containsKey(r'ctl00$cphMain$btnSave'), isFalse);

      // The row's checkbox is unchecked on the page, so the switch post cannot
      // claim it. The other checked row is preserved.
      expect(
        form.containsKey(
          r'ctl00$cphMain$grdFoodBasketReservation$ctl03$chkReserve',
        ),
        isFalse,
      );
      expect(
        form[r'ctl00$cphMain$grdFoodBasketReservation$ctl02$chkReserve'],
        'on',
      );
    });

    test('refuses a closed row', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '1',
          foods: lunchFoods,
          enabled: false,
        ),
      ]);

      expect(
        CullinanParser.hallSwitchBody(html, slot: MealSlot.lunch, hallId: '2'),
        isNull,
      );
    });

    test('refuses a hall the row does not offer', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: [('1', 'مرکزی برادران')],
          selectedHall: '1',
          foods: lunchFoods,
        ),
      ]);

      expect(
        CullinanParser.hallSwitchBody(html, slot: MealSlot.lunch, hallId: '2'),
        isNull,
      );
    });

    test('does not post when the row already names the hall', () {
      final html = page([
        row(
          index: 0,
          slot: 'ناهار',
          halls: halls,
          selectedHall: '2',
          foods: lunchFoods,
        ),
      ]);

      expect(
        CullinanParser.hallSwitchBody(html, slot: MealSlot.lunch, hallId: '2'),
        isNull,
      );
    });
  });
}

/// A minimal `FoodBasketBuy.aspx` page: the hidden WebForms state, the date
/// filter, the reservation grid, and the shared save button.
String page(List<String> rows) =>
    '''
<html><body><form>
<input type="hidden" name="__VIEWSTATE" value="vs" />
<input type="hidden" name="__VIEWSTATEGENERATOR" value="gen" />
<input type="text" name="ctl00\$cphMain\$txtDate" id="cphMain_txtDate" value="1405/09/04" />
<table id="cphMain_grdFoodBasketReservation">
<tr>
  <th>رزرو</th><th>وعده غذایی</th><th>سلف</th><th>غذا</th>
  <th>تعداد</th><th>کالری</th><th>مبلغ خرید</th><th>وضعیت</th>
</tr>
${rows.join('\n')}
</table>
<input type="submit" name="ctl00\$cphMain\$btnSave" id="cphMain_btnSave" value="ذخیره" />
</form></body></html>
''';

/// One grid row. [index] 0 maps to the portal's `ctl02`, as in the live page.
String row({
  required int index,
  required String slot,
  required List<(String, String)> halls,
  required String selectedHall,
  required List<(String, String)> foods,
  bool enabled = true,
  bool checked = false,
}) {
  final ctl = 'ctl${(index + 2).toString().padLeft(2, '0')}';
  final disabled = enabled ? '' : ' disabled="disabled"';

  final hallOptions = halls
      .map(
        (hall) =>
            '<option value="${hall.$1}"'
            '${hall.$1 == selectedHall ? ' selected="selected"' : ''}>'
            '${hall.$2}</option>',
      )
      .join();

  final foodOptions = foods
      .map(
        (food) =>
            '<option value="${food.$1}"'
            '${food.$1 == foods.first.$1 ? ' selected="selected"' : ''}>'
            '${food.$2}</option>',
      )
      .join();

  return '''
<tr${enabled ? '' : ' class="aspNetDisabled"'}>
  <td><input type="checkbox" name="ctl00\$cphMain\$grdFoodBasketReservation\$$ctl\$chkReserve"${checked ? ' checked="checked"' : ''}$disabled /></td>
  <td><span>$slot</span></td>
  <td><select name="ctl00\$cphMain\$grdFoodBasketReservation\$$ctl\$drpSelf"$disabled>$hallOptions</select></td>
  <td><select name="ctl00\$cphMain\$grdFoodBasketReservation\$$ctl\$drpFood"$disabled>$foodOptions</select></td>
  <td><select name="ctl00\$cphMain\$grdFoodBasketReservation\$$ctl\$drpFoodCount"$disabled><option value="1" selected="selected">1</option></select></td>
  <td>0</td><td>0</td><td></td>
</tr>
''';
}
