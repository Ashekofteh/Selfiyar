import 'package:test/test.dart';
import 'package:bahonar_nut/adapter/cullinan/cullinan_parser.dart';
import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/hunt/hunt_ranker.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/reminder/reminder_compose.dart';
import 'package:bahonar_nut/ui/features/reservations/reservation_table_model.dart';

void main() {
  const centralSisters = Hall(id: '3', name: 'مرکزی خواهران');
  const technicalSisters = Hall(id: '4', name: 'فنی خواهران');

  const centralBrothers = Hall(id: '1', name: 'مرکزی برادران');

  group('Female student account: HTML and Portal parsing', () {
    test('parses female dining halls (مرکزی خواهران و فنی خواهران) from Reservation.aspx', () {
      const femaleHtml = '''
<!DOCTYPE html>
<html><body>
<table id="ctl00_cphMain_grdReservationLunch">
  <tr><th>روز</th><th>تاریخ</th><th>سلف</th><th>غذا</th><th>تعداد</th><th>رزرو</th><th>مبلغ خرید</th><th>وضعیت</th></tr>
  <tr>
    <td><span>شنبه</span></td>
    <td><span>1405/08/09</span></td>
    <td>
      <select name="ctl00\$cphMain\$grdReservationLunch\$ctl02\$drpSelf" id="ctl00_cphMain_grdReservationLunch_ctl02_drpSelf">
        <option selected="selected" value="3">مرکزی خواهران</option>
        <option value="4">فنی خواهران</option>
      </select>
    </td>
    <td>
      <select name="ctl00\$cphMain\$grdReservationLunch\$ctl02\$drpFood" id="ctl00_cphMain_grdReservationLunch_ctl02_drpFood">
        <option selected="selected" value="7101">زرشک پلو با مرغ 350000 ریال</option>
        <option value="7102">چلو قرمه سبزی 350000 ریال</option>
      </select>
    </td>
    <td>
      <select name="ctl00\$cphMain\$grdReservationLunch\$ctl02\$drpFoodCount">
        <option selected="selected" value="1">1</option>
      </select>
    </td>
    <td><input type="checkbox" name="ctl00\$cphMain\$grdReservationLunch\$ctl02\$chkReserve" id="chkReserve" checked="checked" /></td>
    <td>350000 ریال</td>
    <td><img id="ctl00_cphMain_grdReservationLunch_ctl02_imgStaus" src="/Images/AcceptGreen16.png" /></td>
  </tr>
</table>
</body></html>
''';

      // 1. Parse menu
      final menus = CullinanParser.parseMenu(
        femaleHtml,
        DateTime.utc(2026, 10, 31),
      );
      expect(menus, hasLength(1));
      final menu = menus.first;

      expect(menu.slot, MealSlot.lunch);
      expect(menu.halls, hasLength(2));
      expect(menu.halls[0].id, '3');
      expect(menu.halls[0].name, 'مرکزی خواهران');
      expect(menu.halls[1].id, '4');
      expect(menu.halls[1].name, 'فنی خواهران');

      // 2. Parse reservations
      final reservations = CullinanParser.parseReservations(femaleHtml);
      expect(reservations, hasLength(1));
      final res = reservations.first;
      expect(res.hall.id, '3');
      expect(res.hall.name, 'مرکزی خواهران');
      expect(res.option.name, 'زرشک پلو با مرغ');
      expect(res.option.priceRial, 350000);
    });

    test('generates reservation form body containing female hall ID', () {
      final offering = MealOffering(
        date: DateTime.utc(2026, 10, 31),
        slot: MealSlot.lunch,
        hall: technicalSisters,
        option: const MenuOption(
          id: '7102',
          name: 'چلو قرمه سبزی',
          priceRial: 350000,
        ),
        reservable: true,
      );

      expect(offering.hall.id, '4');
      expect(offering.hall.name, 'فنی خواهران');
    });

    test('FoodBasket claimFormBody posts female hall ID to portal', () {
      const basketHtml = '''
<html><body>
<input type="hidden" name="__VIEWSTATE" value="vs123" />
<input type="hidden" name="__VIEWSTATEGENERATOR" value="gen123" />
<table id="grdFoodBasketReservation">
  <tr>
    <td>1</td><td>1405/08/09</td><td>ناهار</td><td>مرکزی خواهران</td>
    <td>
      <select name="ctl00\$cphMain\$drpSelf">
        <option selected="selected" value="3">مرکزی خواهران</option>
        <option value="4">فنی خواهران</option>
      </select>
    </td>
    <td>
      <select name="ctl00\$cphMain\$drpFood">
        <option selected="selected" value="7101">زرشک پلو 350000 ریال</option>
      </select>
    </td>
    <td>350,000</td>
    <td><input type="checkbox" name="ctl00\$cphMain\$chkReserve" /></td>
  </tr>
</table>
</body></html>
''';

      final form = CullinanParser.claimFormBody(
        basketHtml,
        listingId: '7101',
        hallId: '4', // User selects فنی خواهران
      );

      expect(form[r'ctl00$cphMain$drpSelf'], '4');
      expect(form[r'ctl00$cphMain$drpFood'], '7101');
    });
  });

  group('Female student account: Table model and UI representation', () {
    test('buildMealRows correctly displays female hall names', () {
      final date = DateTime.utc(2026, 10, 31);
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [centralSisters, technicalSisters],
        dishes: const [
          MenuOption(id: '7101', name: 'زرشک پلو با مرغ', priceRial: 350000),
        ],
        reservable: true,
      );

      final held = StoredMeal(
        accountId: 'female_student_1',
        date: date,
        slot: MealSlot.lunch,
        hallName: 'مرکزی خواهران',
        dishName: 'زرشک پلو با مرغ',
        priceRial: 350000,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.now().toUtc(),
      );

      final rows = buildMealRows(menus: [menu], held: [held], clock: null);

      expect(rows, hasLength(1));
      expect(rows.first.hallName, 'مرکزی خواهران');
      expect(rows.first.status, MealRowStatus.held);
      expect(rows.first.priceRial, 350000);
    });
  });

  group('Female student account: Food Hunt (شکار)', () {
    test('MenuChoice extracts female halls from menu', () {
      final date = DateTime.utc(2026, 10, 31);
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [centralSisters, technicalSisters],
        dishes: const [
          MenuOption(id: '7101', name: 'زرشک پلو', priceRial: 350000),
          MenuOption(id: '7102', name: 'قرمه سبزی', priceRial: 400000),
        ],
        reservable: true,
      );

      final choice = MenuChoice.from([menu], MealSlot.lunch);
      expect(choice, isNotNull);
      expect(choice!.halls, hasLength(2));
      expect(choice.halls[0].id, '3');
      expect(choice.halls[0].name, 'مرکزی خواهران');
      expect(choice.halls[1].id, '4');
      expect(choice.halls[1].name, 'فنی خواهران');
    });

    test(
      'HuntRanker matches listings for female halls and ignores male halls',
      () {
        final ranker = HuntRanker();
        final config = HuntConfig(
          targetSlot: MealSlot.lunch,
          dishPriority: [
            HuntDish(optionId: '7101', name: 'زرشک پلو', priceRial: 350000),
          ],
          hallPriority: const [HuntHall(id: '3', name: 'مرکزی خواهران')],
        );

        // Listing 1: Male hall (مرکزی برادران, id: 1) -> must be rejected
        final maleListing = Listing.composite(
          date: DateTime.utc(2026, 10, 31),
          slot: MealSlot.lunch,
          hall: centralBrothers,
          option: const MenuOption(
            id: '7101',
            name: 'زرشک پلو',
            priceRial: 350000,
          ),
        );

        // Listing 2: Female hall (مرکزی خواهران, id: 3) -> must be matched
        final femaleListing = Listing.composite(
          date: DateTime.utc(2026, 10, 31),
          slot: MealSlot.lunch,
          hall: centralSisters,
          option: const MenuOption(
            id: '7101',
            name: 'زرشک پلو',
            priceRial: 350000,
          ),
        );

        final maleResult = ranker.selectBest(
          config: config,
          listings: [maleListing],
        );
        expect(
          maleResult.hasMatch,
          isFalse,
          reason: 'Male hall must not match female preference',
        );
        expect(
          maleResult.considered.first.skipReason,
          HuntSkipReason.hallNotWanted,
        );

        final femaleResult = ranker.selectBest(
          config: config,
          listings: [femaleListing],
        );
        expect(femaleResult.hasMatch, isTrue, reason: 'Female hall must match');
        expect(femaleResult.best!.hall.id, '3');
        expect(femaleResult.best!.hall.name, 'مرکزی خواهران');
      },
    );

    test('Hunt fallback to secondary female hall (فنی خواهران)', () {
      final ranker = HuntRanker();
      final config = HuntConfig(
        targetSlot: MealSlot.lunch,
        dishPriority: [
          HuntDish(optionId: '7101', name: 'زرشک پلو', priceRial: 350000),
        ],
        hallPriority: const [
          HuntHall(id: '3', name: 'مرکزی خواهران'),
          HuntHall(id: '4', name: 'فنی خواهران'),
        ],
      );

      // Only technical sisters is available in the marketplace
      final techListing = Listing.composite(
        date: DateTime.utc(2026, 10, 31),
        slot: MealSlot.lunch,
        hall: technicalSisters,
        option: const MenuOption(
          id: '7101',
          name: 'زرشک پلو',
          priceRial: 350000,
        ),
      );

      final result = ranker.selectBest(config: config, listings: [techListing]);
      expect(result.hasMatch, isTrue);
      expect(result.best!.hall.id, '4');
      expect(result.best!.hall.name, 'فنی خواهران');
    });
  });

  group('Multi-account: Male and Female accounts coexisting', () {
    test(
      'Reminder formatting distinguishes male and female dining halls cleanly',
      () {
        final now = DateTime.utc(2026, 10, 31, 8, 0);
        final digests = [
          HeldMealDigest(
            accountId: 'acc_ali',
            displayName: 'علی',
            date: DateTime.utc(2026, 10, 31),
            slot: MealSlot.lunch,
            dishName: 'چلو کباب',
            hallName: 'مرکزی برادران',
          ),
          HeldMealDigest(
            accountId: 'acc_fatemeh',
            displayName: 'فاطمه',
            date: DateTime.utc(2026, 10, 31),
            slot: MealSlot.lunch,
            dishName: 'قرمه سبزی',
            hallName: 'مرکزی خواهران',
          ),
        ];

        final text = composeReminderText(
          slot: ReminderSlot.lunch,
          meals: digests,
          now: now,
        );

        expect(text.body, contains('علی — چلو کباب — مرکزی برادران'));
        expect(text.body, contains('فاطمه — قرمه سبزی — مرکزی خواهران'));
      },
    );
  });
}
