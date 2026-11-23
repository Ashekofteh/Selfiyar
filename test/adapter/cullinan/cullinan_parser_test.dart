import 'dart:io';

import 'package:bahonar_nut/adapter/cullinan/cullinan_parser.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:test/test.dart';

/// Tests for the portal's HTML parsing, run against pages captured from the
/// live portal during recon.
///
/// The `recon/` directory is git-ignored (it holds session cookies and
/// authenticated snapshots), so these tests skip cleanly when it is absent
/// rather than failing on a fresh clone. Re-run them after a recon capture to
/// re-verify the parsers against real markup.
void main() {
  String? fixture(String name) {
    for (final dir in ['scratch/portal_live/out', 'recon', 'captures']) {
      final file = File('$dir/$name');
      if (file.existsSync()) return file.readAsStringSync();
    }
    return null;
  }

  group('composite listing identity', () {
    test('is date|slot|hallId|optionId', () {
      expect(
        Listing.compositeListingId(
          date: DateTime.utc(2026, 10, 18),
          slot: MealSlot.lunch,
          hallId: '1',
          optionId: '62726',
        ),
        '2026-10-18|lunch|1|62726',
      );
    });

    test('zero-pads month and day', () {
      expect(
        Listing.compositeListingId(
          date: DateTime.utc(2026, 1, 5),
          slot: MealSlot.breakfast,
          hallId: '1',
          optionId: '1',
        ),
        '2026-01-05|breakfast|1|1',
      );
    });

    test('ignores the time component, so one meal is one id', () {
      final morning = Listing.compositeListingId(
        date: DateTime.utc(2026, 10, 18, 8),
        slot: MealSlot.lunch,
        hallId: '1',
        optionId: '1',
      );
      final evening = Listing.compositeListingId(
        date: DateTime.utc(2026, 10, 18, 20),
        slot: MealSlot.lunch,
        hallId: '1',
        optionId: '1',
      );
      expect(morning, evening);
    });

    test('different options on the same row are different listings', () {
      final a = Listing.compositeListingId(
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
        hallId: '1',
        optionId: '62726',
      );
      final b = Listing.compositeListingId(
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
        hallId: '1',
        optionId: '62729',
      );
      expect(a, isNot(b));
    });

    test('the same dish in two halls is two listings', () {
      // The hall is part of the identity: a claim POST names a hall *and* a
      // dish, so the two are bought separately and lost separately. One
      // being gone says nothing about the other.
      final central = Listing.compositeListingId(
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
        hallId: '1',
        optionId: '62726',
      );
      final technical = Listing.compositeListingId(
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.lunch,
        hallId: '2',
        optionId: '62726',
      );
      expect(central, isNot(technical));
    });

    test('Listing.composite builds the same id', () {
      final listing = Listing.composite(
        date: DateTime.utc(2026, 10, 18),
        slot: MealSlot.dinner,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: const MenuOption(
          id: '62742',
          name: 'سالاد الویه',
          priceRial: 350000,
        ),
      );
      expect(listing.id, '2026-10-18|dinner|1|62742');
      expect(listing.priceRial, 350000);
    });
  });

  group('dish name extraction', () {
    test('strips the trailing price', () {
      expect(
        CullinanParser.dishName('زرشک پلو با مرغ,سس مرغ, ماست 500000 ریال'),
        'زرشک پلو با مرغ,سس مرغ, ماست',
      );
    });

    test('leaves a name with no price alone', () {
      expect(
        CullinanParser.dishName('شیر/حلواشکری/نان/چای/قند'),
        'شیر/حلواشکری/نان/چای/قند',
      );
    });
  });

  group('against the live basket page', () {
    // Live captures. The `recon/` and `scratch/` directories are git-ignored,
    // so these skip cleanly on a fresh clone.

    test('a closed row produces no listing', () {
      // live_buy_page.html: breakfast 62758 is rendered, but its
      // `chkReserve` is disabled. The old parser emitted two buyable listings
      // for it (one per hall). It is not buyable at all.
      final html = fixture('live_buy_page.html');
      if (html == null) return;

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 10, 19),
      );

      expect(listings, isEmpty);
    });

    test('includeClosed exposes a closed row, but only in its own hall', () {
      final html = fixture('live_buy_page.html');
      if (html == null) return;

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 10, 19),
        includeClosed: true,
      );

      // The row's `drpSelf` also lists hall 2, but the food list was rendered
      // for hall 1. Hall 2 with the same food id is the fabrication C1 fixed.
      expect(listings, hasLength(1));
      final listing = listings.single;
      expect(listing.slot, MealSlot.breakfast);
      expect(listing.hall.id, '1');
      expect(listing.option.id, '62758');
      expect(listing.priceRial, 150000);
      expect(listing.buyable, isFalse);
    });

    test('a second capture on a different day obeys the same gate', () {
      // basket_buy.html: breakfast 62785 is checked but disabled (already
      // held), and hall 2 is selected.
      final html = fixture('basket_buy.html');
      if (html == null) return;

      expect(
        CullinanParser.parseBasket(html, DateTime.utc(2026, 10, 18)),
        isEmpty,
      );

      final closed = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 10, 18),
        includeClosed: true,
      );
      expect(closed, hasLength(1));
      expect(closed.single.option.id, '62785');
      expect(closed.single.hall.id, '2');
      expect(closed.single.buyable, isFalse);
    });

    test('an enabled row yields one listing, not one per hall', () {
      // buy_tomorrow.html: breakfast is enabled, `drpSelf` offers halls 1 and
      // 2, hall 1 is selected, and the food list holds 64549.
      final html = fixture('buy_tomorrow.html');
      if (html == null) return;

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 10, 21),
      );

      expect(listings, hasLength(1));
      final listing = listings.single;
      expect(listing.slot, MealSlot.breakfast);
      expect(listing.hall.id, '1');
      expect(listing.option.id, '64549');
      expect(listing.priceRial, 150000);
      expect(listing.buyable, isTrue);

      // Hall 2 is a postback target, not a listing on this page.
      expect(listings.any((l) => l.hall.id == '2'), isFalse);
    });

    test('only the enabled dinner row is a listing (lab initial)', () {
      // basket_lab_initial.html: breakfast and lunch are disabled; dinner is
      // enabled with 64540.
      final html = fixture('basket_lab_initial.html');
      if (html == null) return;

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 11, 22),
      );

      expect(listings, hasLength(1));
      expect(listings.single.slot, MealSlot.dinner);
      expect(listings.single.option.id, '64540');
      expect(listings.single.hall.id, '1');
      expect(listings.single.buyable, isTrue);
    });

    test('a disabled lunch is omitted while breakfast and dinner survive', () {
      // basket_lab_filtered.html: breakfast 64588 enabled, lunch disabled
      // with the already-held 64574, dinner 64579/64582 enabled.
      final html = fixture('basket_lab_filtered.html');
      if (html == null) return;

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 11, 25),
      );

      final bySlot = <MealSlot, List<String>>{};
      for (final listing in listings) {
        bySlot.putIfAbsent(listing.slot, () => []).add(listing.option.id);
      }

      expect(bySlot[MealSlot.breakfast], ['64588']);
      expect(bySlot[MealSlot.dinner], ['64579', '64582']);
      expect(bySlot.containsKey(MealSlot.lunch), isFalse);
    });

    test('each row uses its own selected hall (hall-2 capture)', () {
      // basket_hall2.html: breakfast is rendered for hall 1, lunch for hall 2.
      // All rows are closed in the capture; stripping the attribute isolates
      // the C1 hall rule from the C2 gate.
      final raw = fixture('basket_hall2.html');
      if (raw == null) return;
      final html = raw.replaceAll('disabled="disabled"', '');

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 11, 22),
      );

      final lunch = listings.where((l) => l.slot == MealSlot.lunch).toList();
      expect(lunch.map((l) => l.option.id), ['64602', '64604']);
      expect(lunch.every((l) => l.hall.id == '2'), isTrue);

      final breakfast = listings
          .where((l) => l.slot == MealSlot.breakfast)
          .toList();
      expect(breakfast, hasLength(1));
      expect(breakfast.single.hall.id, '1');
      expect(breakfast.single.option.id, '64535');

      // The lunch row never names hall 1, even though its `drpSelf` lists it.
      expect(
        listings.any((l) => l.slot == MealSlot.lunch && l.hall.id == '1'),
        isFalse,
      );
    });

    test('the default-hall capture never fabricates the other hall', () {
      // 30_basket_buy.html: every row is closed (captured after the cutoff);
      // stripping disabled isolates C1. Lunch is rendered for hall 1.
      final raw = fixture('30_basket_buy.html');
      if (raw == null) return;
      final html = raw.replaceAll('disabled="disabled"', '');

      final listings = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 11, 22),
      );

      final lunch = listings.where((l) => l.slot == MealSlot.lunch).toList();
      expect(lunch.map((l) => l.option.id), ['64536', '64538']);
      expect(lunch.every((l) => l.hall.id == '1'), isTrue);
      expect(listings.any((l) => l.hall.id == '2'), isFalse);
    });

    test('the dinner options have distinct dish names', () {
      final html = fixture('basket_lab_filtered.html');
      if (html == null) return;

      final dinner = CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 11, 25),
      ).where((l) => l.slot == MealSlot.dinner).toList();

      expect(dinner, hasLength(2));
      expect(dinner[0].option.name, isNot(dinner[1].option.name));
      expect(dinner[0].option.name, isNotEmpty);
      expect(
        dinner[0].option.name,
        isNot(contains('ریال')),
        reason: 'the price must not leak into the dish name',
      );
    });

    test('every listing carries a composite id consistent with its parts', () {
      final html = fixture('basket_lab_filtered.html');
      if (html == null) return;

      for (final listing in CullinanParser.parseBasket(
        html,
        DateTime.utc(2026, 11, 25),
      )) {
        expect(
          listing.id,
          Listing.compositeListingId(
            date: listing.date,
            slot: listing.slot,
            hallId: listing.hall.id,
            optionId: listing.option.id,
          ),
        );
      }
    });
  });

  group('against the live reservation page', () {
    test('parses held reservations', () {
      final html = fixture('reservation.html');
      if (html == null) return;

      final reservations = CullinanParser.parseReservations(html);
      expect(reservations, isNotEmpty);

      for (final reservation in reservations) {
        expect(reservation.option.id, isNot('-1'));
        expect(reservation.option.id, isNotEmpty);
        expect(reservation.option.priceRial, greaterThan(0));
        expect(
          reservation.state,
          anyOf(ReservationState.active, ReservationState.consumed),
        );
        expect(reservation.date.year, greaterThan(2020));
      }

      expect(
        reservations.any((r) => r.state == ReservationState.consumed),
        isTrue,
        reason:
            'the eaten breakfast with Eating16.png should parse as consumed',
      );
    });

    test('the captured page held a breakfast on 1405/07/27', () {
      final html = fixture('reservation.html');
      if (html == null) return;

      final reservations = CullinanParser.parseReservations(html);
      final breakfast = reservations
          .where((r) => r.slot == MealSlot.breakfast)
          .where((r) => r.date == DateTime.utc(2026, 10, 19));
      expect(breakfast, isNotEmpty);
      expect(breakfast.first.option.id, '62725');
    });

    test('the captured page held a lunch on 1405/07/26', () {
      final html = fixture('reservation.html');
      if (html == null) return;

      final reservations = CullinanParser.parseReservations(html);
      final lunch = reservations
          .where((r) => r.slot == MealSlot.lunch)
          .where((r) => r.date == DateTime.utc(2026, 10, 18));
      expect(lunch, isNotEmpty);
      expect(lunch.first.option.id, '62714');
    });

    test('parses offerings for a given date', () {
      final html = fixture('reservation.html');
      if (html == null) return;

      final offerings = CullinanParser.parseOfferings(
        html,
        DateTime.utc(2026, 10, 19),
      );
      expect(offerings, isNotEmpty);
      expect(
        offerings.every((o) => o.date == DateTime.utc(2026, 10, 19)),
        isTrue,
      );
      expect(offerings.every((o) => o.option.id != '-1'), isTrue);
      expect(offerings.every((o) => o.option.priceRial > 0), isTrue);
    });

    test('a locked date is reported as not reservable', () {
      final html = fixture('reservation.html');
      if (html == null) return;

      // The captured page's current-week rows are all locked (the server
      // renders them `disabled`), so nothing on that date is reservable.
      final offerings = CullinanParser.parseOfferings(
        html,
        DateTime.utc(2026, 10, 19),
      );
      if (offerings.isEmpty) return;
      expect(
        offerings.every((o) => !o.reservable),
        isTrue,
        reason: 'current-week rows are locked by the server',
      );
    });

    test('the next week is reservable (its rows are editable)', () {
      final html = fixture('reservation_nextweek.html');
      if (html == null) return;

      final offerings = CullinanParser.parseOfferings(
        html,
        DateTime.utc(2026, 10, 24),
      );
      if (offerings.isEmpty) return;
      expect(
        offerings.every((o) => o.reservable),
        isTrue,
        reason: 'next-week rows are editable',
      );
    });
  });

  group('Jalali date labels in grid rows', () {
    test('the portal label parses to the right Gregorian date', () {
      expect(parseJalaliDate('شنبه 1405/08/02'), DateTime.utc(2026, 10, 24));
      expect(parseJalaliDate('یکشنبه 1405/07/26'), DateTime.utc(2026, 10, 18));
    });

    test('parses student profile name from captures and html structures', () {
      const htmlDiv =
          '<div id="divUsername" class="profileTitle">رضا شريفي</div>';
      expect(CullinanParser.parseProfileName(htmlDiv), 'رضا شريفي');

      const htmlLabel =
          '<label id="cphMain_titleBoxValue">کاربر: علی محمدی - 401000000</label>';
      expect(CullinanParser.parseProfileName(htmlLabel), 'علی محمدی');

      final f04 = File('captures/04_after_login.html');
      if (f04.existsSync()) {
        expect(
          CullinanParser.parseProfileName(f04.readAsStringSync()),
          'رضا شريفي',
        );
      }

      final f30 = File('captures/30_reservation_current.html');
      if (f30.existsSync()) {
        expect(
          CullinanParser.parseProfileName(f30.readAsStringSync()),
          isNotNull,
        );
      }
    });

    test('extracts clean student name from raw title strings', () {
      expect(
        CullinanParser.extractStudentName('کاربر: احمد حسینی - 401000000'),
        'احمد حسینی',
      );
      expect(
        CullinanParser.extractStudentName('کاربر : رضا شريفي - 401157013'),
        'رضا شريفي',
      );
      expect(
        CullinanParser.extractStudentName('کاربر: علی محمدی'),
        'علی محمدی',
      );
    });
  });
}
