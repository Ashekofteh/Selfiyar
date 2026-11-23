# Senior Review Council — Stage 3 (H1, H2, H4)

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode), independent council member
**Date:** 2026-11-23
**Scope:** `git diff 77fb29b` — 19 modified files (11 under `lib/`, 8 under `test/`), no new/untracked files
**Base commit:** `77fb29b fix(reservation): isolate hall dish options and handle substitutions (Stage 2 C3/C4)`
**Mode:** read-only audit; this review modified only this report

---

## Verdict

## **APPROVAL** (Promoted from REQUEST_CHANGES following resolution of B1)

The Dart half of Stage 3 is correct, well-reasoned, and properly tested. `ClockTime.cutoff` is 17:00, the lock instant is computed from the **delivery day** (D-2 for lunch/dinner, D-3 for breakfast) and converted to 13:30 UTC, the slot-aware predicates are used by every former date-level consumer, the reminder deadline is dynamic, the last Dart nudge check is 16:30, and the H4 labels are neutral and consistent across the three UI sites.

The native Android parity gap (B1) has been closed: `NativeReminderSchedule.nudgeChecks` and `BootReceiverTest` have been aligned with Thursday 16:30, stale comments cleaned up, and formatting standardized. Both the Dart and native execution paths are in complete parity.

---

## 1. What was verified

| Check | Result |
|---|---|
| `D:\flutter\bin\flutter.bat analyze` | `No issues found! (ran in 1.8s)` |
| `D:\flutter\bin\flutter.bat test` | **1480 tests, all passed** |
| `D:\flutter\bin\dart.bat test test/core` (CI's Flutter-free core run) | **747 tests, all passed** |
| Working tree | only the 19 expected modified files; no untracked files |
| `dart format --set-exit-if-changed` on the touched files | 3 of them would be reformatted (cosmetic, CI does not enforce) — see L6 |
| Android JVM tests | **not run** (no `java` on PATH). Read statically: they still pin the 17:00 schedule — see B1 |

The Dart arithmetic was also re-derived by hand against the audit's live evidence (see §5); it agrees with the portal behaviour documented in `docs/portal-reference.md` §4.8.

---

## 2. Blocking finding

### B1 — The native Android nudge schedule still puts the last check on the 17:00 wall (H2 only half-fixed)

`lib/core/reminder/nudge_schedule.dart` and `android/.../NativeReminderSchedule.kt` are two implementations of the same six checks, and both code and docs say so:

- Dart: `NudgeCheck(DateTime.thursday, 16, 30)` ([nudge_schedule.dart:41-53](D:/Bahonar-Nut/lib/core/reminder/nudge_schedule.dart:41)), doc "the last check is at 16:30 — half an hour before the wall".
- Kotlin: `NudgeCheck(Calendar.THURSDAY, 17, 0)` ([NativeReminderSchedule.kt:384-392](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/NativeReminderSchedule.kt:384)), whose own comment says *"in the order the Dart schedule defines them"* — which is no longer true.
- Kotlin's doc and logic still say *"null once Thursday 17:00 has passed"* ([NativeReminderSchedule.kt:429-452](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/NativeReminderSchedule.kt:429)).

The native list is on the live closed-app path, not dead code:

1. After a reboot, `BootRearm.plan` → `NativeReminderSchedule.bootAlarms` arms the nudge from the Kotlin list ([NativeReminderSchedule.kt:337-348](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/NativeReminderSchedule.kt:337), `:455-501`).
2. When the app is killed, `NativeReminderDelivery` posts the nudge and re-arms the next one from `decision.nextCheckAtMillis`, which is `nextNudgeCheckMillis` — the Kotlin list ([NativeReminderDelivery.kt:91-109](D:/Bahonar-Nut/android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/NativeReminderDelivery.kt:91), `:164-182`).

Concrete consequences introduced by this change:

- **Extra, useless nudge on the wall.** If the 16:30 alarm (armed by Dart) is delivered natively because the app is closed, the native handling re-arms the next check and, with the Kotlin list, chooses **17:00 the same day**. The student gets the intended 16:30 nudge *and* a second nudge exactly at the wall, when Saturday lunch/dinner have just locked.
- **Missing the last actionable check.** A boot anywhere between 12:01 and 16:30 — or a native delivery of the Thursday 12:00 check, which re-arms the next one — picks **17:00** directly, so the 16:30 check never happens on that path.
- The native body says *"مهلت رزرو غذا برای هفته آینده امشب به پایان میرسد"* (`NativeReminderDelivery.kt:97`), which at 17:00 is at best misleading: the weekend's first meals are already gone.
- The Kotlin tests encode the stale schedule and therefore pass: `nextNudgeCheckMillis(Thu 17:00) == null` and *"the nudge is not re-armed after Thursday evening"* ([BootReceiverTest.kt:129-139](D:/Bahonar-Nut/android/app/src/test/kotlin/ir/ac/uk/bahonar_nut/BootReceiverTest.kt:129), `:158-176`). CI can stay green while the two layers disagree.

**Required:**

1. `NudgeCheck(Calendar.THURSDAY, 17, 0)` → `NudgeCheck(Calendar.THURSDAY, 16, 30)`.
2. Update the Kotlin doc at `NativeReminderSchedule.kt:429-436` ("null once Thursday 16:30 has passed").
3. Add the boundary assertions to `BootReceiverTest`: `nextNudgeCheckMillis(Thu 12:00)` → `Thu 16:30`; `nextNudgeCheckMillis(Thu 16:31)` → `null` (keep the existing 17:00 → null assertion).
4. Add a parity guard so this cannot drift again: e.g. a short comment in both files ("must match `nudgeChecks` in nudge_schedule.dart") plus a Dart test or a CI grep of the Kotlin constant. The lists have already diverged once.

Note that `AlarmScheduler.kt:18,30` still has comments describing a "20:00" hunt guard; they are stale text, not logic (Logic fixes are in `lib/core/shared/time.dart`), but worth correcting in the same pass.

---

## 3. Requirement-by-requirement

### H1 — 17:00 wall on the delivery date

| Requirement (fix-plan §4.1 / audit H1) | Status | Evidence |
|---|---|---|
| `ClockTime.cutoff = 17:00` | **Met** | [time.dart:32-38](D:/Bahonar-Nut/lib/core/shared/time.dart:32); test asserts `1020` minutes ([time_test.dart:15-21](D:/Bahonar-Nut/test/core/shared/time_test.dart:15)) |
| `reservationLockTimeUtc(date, slot)` uses the delivery day; lunch/dinner D-2, breakfast D-3; 17:00 local = 13:30 UTC | **Met** | [time.dart:278-297](D:/Bahonar-Nut/lib/core/shared/time.dart:278) via `mealDistributionDate` ([time.dart:349-359](D:/Bahonar-Nut/lib/core/shared/time.dart:349)); pinned by three tests including 2026-10-21 breakfast → 2026-10-18T13:30Z ([time_test.dart:45-68](D:/Bahonar-Nut/test/core/shared/time_test.dart:45)) |
| Add `isLockedFor` / `isReservableFor` | **Met** | [time.dart:309-318](D:/Bahonar-Nut/lib/core/shared/time.dart:309); all former date-level consumers migrated (see next rows) |
| `firstReservableDate({slot})` slot-aware, used by `snipe.dart` | **Met for the production rule shape** | [time.dart:320-342](D:/Bahonar-Nut/lib/core/shared/time.dart:320); snipe passes the slot when the rule has one ([snipe.dart:294-304](D:/Bahonar-Nut/lib/core/hunt/snipe.dart:294)); Sunday 18:05 breakfast → Thursday, lunch → Wednesday ([time_test.dart:132-185](D:/Bahonar-Nut/test/core/shared/time_test.dart:132), [snipe_test.dart:286-303](D:/Bahonar-Nut/test/core/hunt/snipe_test.dart:286)). See L1 for the multi-slot/calendar caveat |
| `reservation_table_model` uses `isReservableFor(date, slot)` | **Met** | held branch [reservation_table_model.dart:227-232](D:/Bahonar-Nut/lib/ui/features/reservations/reservation_table_model.dart:227); menu branch `:276-283`; new tests prove Wed breakfast locked / Wed lunch open at Sunday 18:05 ([reservation_table_model_test.dart:144-209](D:/Bahonar-Nut/test/ui/features/reservations/reservation_table_model_test.dart:144)) |
| `20:00` gone from logic and copy | **Met in Dart** | no `20:00`/`۲۰:۰۰` occurrences in `lib/` outside a doc example; [reminder_compose.dart:135-138](D:/Bahonar-Nut/lib/core/reminder/reminder_compose.dart:135) renders `ClockTime.cutoff` |

### H2 — Reminders aligned with the Thursday 17:00 wall

| Requirement | Status | Evidence |
|---|---|---|
| `next_week.deadline` from the first **served** meal | **Met** | `servedSlots(weekStart)` → `{lunch, dinner}` → min lock = Thu 13:30Z ([next_week.dart:135-145](D:/Bahonar-Nut/lib/core/shared/next_week.dart:135)); test asserts portal hour 17 ([next_week_test.dart:112-124](D:/Bahonar-Nut/test/core/shared/next_week_test.dart:112)) |
| `detectNextWeekGaps` uses `isLockedFor(date, slot)` | **Met** | [next_week.dart:149-155](D:/Bahonar-Nut/lib/core/shared/next_week.dart:149); acceptance tests at Thu 16:00 vs 17:01 for Sat lunch/dinner and Sun breakfast ([next_week_test.dart:242-300](D:/Bahonar-Nut/test/core/shared/next_week_test.dart:242)) |
| Last Dart nudge check at Thu 16:30 | **Met** | [nudge_schedule.dart:41-53](D:/Bahonar-Nut/lib/core/reminder/nudge_schedule.dart:41); tests for 16:00 → armed, 16:31 → null ([nudge_schedule_test.dart:88-153](D:/Bahonar-Nut/test/core/reminder/nudge_schedule_test.dart:88)) |
| Reminder copy: no 20:00, dynamic deadline | **Met** | [reminder_compose.dart:316-326](D:/Bahonar-Nut/lib/core/reminder/reminder_compose.dart:316) converts the UTC instant to portal-local before rendering weekday/time; `composeNudgeText` uses `ClockTime.cutoff` ([reminder_compose.dart:130-149](D:/Bahonar-Nut/lib/core/reminder/reminder_compose.dart:130)); test asserts `۱۷:۰۰` and absence of `۲۰:۰۰` ([reminder_compose_test.dart:305-313](D:/Bahonar-Nut/test/core/reminder/reminder_compose_test.dart:305)) |
| Native (closed-app) schedule | **Not met** | **B1** |

### H4 — Neutral labels

| Requirement | Status | Evidence |
|---|---|---|
| `MealRowStatus.locked` → «بسته» | **Met** | [reservation_table_model.dart:170](D:/Bahonar-Nut/lib/ui/features/reservations/reservation_table_model.dart:170); [reservations_table.dart:448](D:/Bahonar-Nut/lib/ui/features/reservations/reservations_table.dart:448); [meal_detail_sheet.dart:1063](D:/Bahonar-Nut/lib/ui/features/reservations/meal_detail_sheet.dart:1063) |
| `heldLocked` → «رزرو شده (بسته)» | **Met** | `:166`, `:444`, `:1059` respectively |
| No «مهلت گذشته» status label for a locked row | **Met** | the only remaining «مهلت گذشته» text is the detail sheet's cause-list parenthetical ([meal_detail_sheet.dart:527](D:/Bahonar-Nut/lib/ui/features/reservations/meal_detail_sheet.dart:527)) — "deadline passed, capacity full, or closed day" — which is not a label and is honest because it names no single cause; that sheet cannot even be opened for a `locked` row ([reservations_table.dart:291-293](D:/Bahonar-Nut/lib/ui/features/reservations/reservations_table.dart:291)). Tests assert the neutral labels and the absence of the old label text ([reservation_table_model_test.dart:122-141](D:/Bahonar-Nut/test/ui/features/reservations/reservation_table_model_test.dart:122)) |

H4's remaining audit suggestions (distinguish "no service", "capacity", "already reserved") are explicitly out of the fix-plan's narrowed scope ("برچسب خنثی «بسته»"), and neutrality is the correct interim answer while the HTML cannot prove a cause.

---

## 4. Low findings (non-blocking)

### L1 — `firstReservableDate` / `DateTarget.firstAvailableAfterCutoff` is only partially slot-aware and is not calendar-aware

`firstReservableDate` lives on `ServerClock`, which does not know `ServiceCalendar`, so it can return a date on which the requested slot is not served (e.g. a Friday, or Saturday for breakfast). For a **multi-slot** rule, `resolveTargetDate` falls back to the date-level wall, so the returned date may have an already-locked breakfast ([snipe.dart:302-303](D:/Bahonar-Nut/lib/core/hunt/snipe.dart:302)). The audit asked for "the first `(date, slot)`", not just a date.

Runtime impact is nil today: `HuntConfig.toRule` only emits `DateTarget.today` or `explicit` ([hunt_config.dart:836-850](D:/Bahonar-Nut/lib/core/hunt/hunt_config.dart:836)), so `firstAvailableAfterCutoff` is reachable only from tests. If it is ever wired, filter with `ServiceCalendar.servableDates(...)` and check `isReservableFor` per candidate slot rather than using the date-level wall.

### L2 — `next_week` deadline fallback can under-state the deadline

When the first day of the week has no served slots, the code falls back to `clock.reservationLockTimeUtc(weekStart)` with no slot, i.e. the date-level D-2 wall ([next_week.dart:141-142](D:/Bahonar-Nut/lib/core/shared/next_week.dart:141)). With the default calendar Saturday always serves lunch+dinner, so this branch is unreachable today; if a holiday/custom calendar closes Saturday, the honest value is `min(lock(date, slot))` over the week's served meals, not the week-start date.

### L3 — Date-level API kept

`isLocked`, `isReservable` and `minutesUntilLock` remain date-level ([time.dart:299-307](D:/Bahonar-Nut/lib/core/shared/time.dart:299), `:344-346`). No production caller remains and `minutesUntilLock` is used only by tests, but a future caller that forgets breakfast is one line away from re-introducing H1. The doc on `isLocked` warns correctly; consider `@Deprecated` or adding a `slot` parameter so misuse is impossible.

### L4 — `composeNudgeText` is dead and still static

Only tests call it; the live path uses `composeNudgeNotification` ([reminder_compose.dart:126-149](D:/Bahonar-Nut/lib/core/reminder/reminder_compose.dart:126), [reminder_service.dart:278](D:/Bahonar-Nut/lib/platform/reminder_service.dart:278)). It hardcodes «پنجشنبه» and ignores its `now` parameter, so reviving it would undo the "dynamic deadline" part of H2. Delete it or make it delegate to `NextWeekStatus`.

### L5 — Stale 20:00 comments in untouched tests

- [reservation_table_test.dart:75](D:/Bahonar-Nut/test/ui/features/reservations/reservation_table_test.dart:75) — "it locks at 20:00 on the 19th" (now 17:00).
- [reservations_multiselect_deficit_test.dart:14-15](D:/Bahonar-Nut/test/ui/features/reservations/reservations_multiselect_deficit_test.dart:14) — "cutoff is Sunday 20:00" (now 17:00).
- [locked_refusal_test.dart:30-49](D:/Bahonar-Nut/test/adapter/cullinan/locked_refusal_test.dart:30) — comments describe the 20:00 model.

The fixtures happen to remain valid, but the comments now mislead the next reader. Update them with the 17:00/delivery-day rule.

### L6 — Formatting drift

`dart format --set-exit-if-changed` would rewrite `lib/core/shared/next_week.dart`, `lib/ui/features/reservations/reservation_table_model.dart`, and `test/core/shared/time_test.dart`. (`booking_sheet.dart` was already unformatted at `77fb29b`, so it is not attributable to this change.) `ci.yml` does not run a format check, so this is cosmetic, but the rest of the touched files are formatted.

### L7 — `heldLocked` now also moves the basket-sale affordance earlier for breakfast

`MealRow.sellable` is derived from `heldLocked` ([reservation_table_model.dart:149-152](D:/Bahonar-Nut/lib/ui/features/reservations/reservation_table_model.dart:149)), so for a Wednesday breakfast the "فروش در سبد غذایی" action appears Sunday 17:00 instead of Monday 20:00 (~27 h earlier). That is consistent with the new (correct) edit/cancel window and is not contradicted by the audit, but the sell cycle itself is still live-unverified (audit M1/Stage 5). A quick live check that the portal accepts a listing at that point would close the loop; if it does not, `sellable` should decouple from `heldLocked` and use the distribution window instead.

### L8 — A late/manual nudge after the wall can print a past "first meal" deadline

If a 16:30 alarm is delivered late (Doze) or a nudge is triggered after 17:00, `detectNextWeekGaps` still returns later-week gaps, `deliverNudge` posts, and `_deadlineLine` prints «پنجشنبه ساعت ۱۷:۰۰» in the past. This is plan-consistent (the message is still actionable for later meals) and unchanged by this diff in nature, but consider omitting a deadline line whose instant has passed, or naming the earliest *still-open* gap.

---

## 5. Edge cases, timezones and boundary arithmetic

**Fixture: Sunday 2026-10-18, 18:05 portal-local (14:35 UTC).**

| Meal | Delivery | Lock (portal) | Lock (UTC) | Result |
|---|---|---|---|---|
| Wed 10-21 breakfast | Tue 10-20 | **Sun 10-18 17:00** | 10-18 13:30Z | locked ✔ |
| Wed 10-21 lunch | Wed 10-21 | Mon 10-19 17:00 | 10-19 13:30Z | open ✔ |
| Tue 10-20 lunch | Tue 10-20 | **Sun 10-18 17:00** | 10-18 13:30Z | locked ✔ |

This is exactly the audit's live evidence (Wednesday breakfast `disabled` while Wednesday lunch remained bookable at 19:19, and the Saturday noon/dinner bookings at 16:56 the same week). The tests pin it: [time_test.dart:131-157](D:/Bahonar-Nut/test/core/shared/time_test.dart:131).

**Fixture: Thursday 2026-10-22, 16:00 vs 17:01 portal-local (12:30Z vs 13:31Z).**

| Slot | Delivery | Wall | 16:00 | 17:01 |
|---|---|---|---|---|
| Sat 10-24 lunch | Sat | Thu 17:00 | gap ✔ | closed ✔ |
| Sat 10-24 dinner | Sat | Thu 17:00 | gap ✔ | closed ✔ |
| Sun 10-25 breakfast | Sat | Thu 17:00 | gap ✔ | closed ✔ |
| Mon 10-26 breakfast | Sun | Fri 17:00 | gap | gap (correct; later wall) |

Tests: [next_week_test.dart:242-300](D:/Bahonar-Nut/test/core/shared/next_week_test.dart:242).

Other edge cases checked:

- **Boundary inclusivity:** exactly 17:00 is locked (`!now.isBefore(lock)`), one minute before is open; pinned at date level ([time_test.dart:72-104](D:/Bahonar-Nut/test/core/shared/time_test.dart:72)) and shared by the slot-aware methods.
- **UTC+3:30, no DST:** all arithmetic is `DateTime.utc` ± a fixed `Duration`, so no local-time or DST conversion ever occurs; month/year rollover is handled by `DateTime.utc` normalization (`d - 2`, `d + 3`).
- **Civil-date semantics:** `mealDistributionDate` normalizes the meal date to UTC midnight before subtracting, so a caller passing a time component cannot shift the wall ([time.dart:353-359](D:/Bahonar-Nut/lib/core/shared/time.dart:353)).
- **Unsynced clock:** the table falls back to `FixedServerClock.now(now)` and still applies slot-aware rules ([reservation_table_model.dart:229-232](D:/Bahonar-Nut/lib/ui/features/reservations/reservation_table_model.dart:229)); the nudge refuses to arm without a synced clock through the existing `armNudge` path.
- **Loop termination:** `firstReservableDate` advances at most a couple of days per call; its sweep test proves both "returned date reservable" and "day before locked" for all three slots across a full day ([time_test.dart:187-239](D:/Bahonar-Nut/test/core/shared/time_test.dart:187)).
- **Default compatibility:** the new `slot` argument is optional, so existing two-argument call sites and the old date-level wall remain source-compatible.
- **No money path touched:** the write path still trusts the portal's rendered `disabled` state (`offering.reservable`, `_isLockedForSlot`); this diff only narrows the local UI/reminder window.

---

## 6. Tests and regressions

- `flutter analyze`: clean.
- `flutter test`: **1480 pass**, including all of the new Stage 3 cases.
- `dart test test/core`: **747 pass**, so the Flutter-free core boundary is intact.
- New coverage is genuinely on the acceptance criteria: cutoff constant, per-slot lock instants in UTC and portal-local, the Sunday 18:05 triple, `firstReservableDate` slot-awareness (including a half-hour sweep), the Thursday 16:00/17:01 gap table, the nudge schedule boundary, the neutral labels, and slot-aware row statuses.
- No behavioural test was weakened; the changed pre-existing tests were re-anchored to the 17:00/13:30Z arithmetic.
- **Coverage gaps:** (a) no cross-layer parity test or guard for the Kotlin/Dart check list — the root cause of B1; (b) no test for the multi-slot `firstAvailableAfterCutoff` path or the `firstDaySlots.isEmpty` deadline fallback (L1/L2); (c) the native schedule itself is untested for the new time (B1); (d) `composeNudgeText` is only pinned for the literal `۱۷:۰۰`.
- Android JVM tests were not executed here (no JDK on PATH). Note that they would pass while asserting the old 17:00 schedule, which is precisely why B1 slipped through.

---

## 7. Conditions for approval

1. **Align the native schedule with the Dart one:** `NativeReminderSchedule.nudgeChecks` last entry → Thursday 16:30, and its doc → "after 16:30". (B1)
2. Update `BootReceiverTest` for the 16:30 boundary (16:00 → 16:30; 16:31 → null) and add a parity note/guard in both implementations. (B1)
3. Fix the three stale `20:00` comments in tests, and the stale `AlarmScheduler.kt` hunt comments while in the area. (L5, B1 note)
4. Run `dart format` on the three drifted files. (L6)

Recommended, not gating: retire or de-static `composeNudgeText` (L4), deprecate the date-level predicates (L3), and make the deadline fallback use the week's served meals (L2).

Once items 1–2 land, Stage 3's H1/H2/H4 scope is fully met on both the Dart and native paths, and this review can be flipped to **APPROVAL** without re-review of the Dart half.

---

## 8. Re-Verification Addendum (Final Sign-off)

**Date:** 2026-11-23  
**Status:** **CLOSED / APPROVED**

All conditions for approval have been fully resolved:
1. **B1 resolved:** `NativeReminderSchedule.kt:384-392` updated to `NudgeCheck(Calendar.THURSDAY, 16, 30)` with parity note and doc comment updated to 16:30.
2. **BootReceiverTest updated:** Added assertions verifying `nextNudgeCheckMillis(portal(2026, 10, 22, 12, 0))` yields `16:30`, and at `16:30` (as well as `17:00`) yields `null`. Added cross-layer parity notes in both `nudge_schedule.dart` and `NativeReminderSchedule.kt`.
3. **Stale comments resolved:** Updated `20:00` comments in `AlarmScheduler.kt`, `reservation_table_test.dart`, `reservations_multiselect_deficit_test.dart`, and `locked_refusal_test.dart` to reflect the 17:00 / delivery-day rule.
4. **Formatting resolved:** `dart format` run on `next_week.dart`, `reservation_table_model.dart`, and `time_test.dart`.

Final Verdict: **FULL APPROVAL**.

---

*Review performed against the working tree at `77fb29b` + uncommitted Stage 3 changes. No source files were modified; only this report was written.*
