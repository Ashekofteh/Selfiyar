# Senior Review Council — Stage 4 (M4: Event-Sourced Spend Summary)

**Reviewer:** DeepSeek 4.1 Flash Free (OpenCode), independent council member
**Date:** 2026-11-23
**Scope:** `git diff 2c5edf4` — 3 modified files (`lib/core/portal/portal_models.dart`, `lib/core/finance/spend_summary.dart`, `test/core/finance/spend_summary_test.dart`), no untracked files
**Base commit:** `2c5edf4 fix(deadline): align cutoff with delivery date and neutralize row labels (Stage 3 H1/H2/H4)`
**Spec:** `docs/fix-plan.md` §5, `docs/optimization-audit.md` §5 (M4), acceptance tests #16 and #17
**Mode:** read-only audit; this review modified only this report (one temporary probe test was created and deleted)

---

## Verdict

## **APPROVAL** (Promoted from REQUEST CHANGES following resolution of B1, S1, S2, S3)

The event-sourcing skeleton is right — grouping, chronological replay, classification, final-state exclusion, and the totals plumbing all match the spec and the audit's recommended fix. The sign convention of the modification delta (B1) has been corrected to `amountRial -= event.amountRial`, properly reflecting that negative edit rows represent a debited balance / increased meal cost (`price = bookingPrice - Σ(edit amount)`).

All test expectations and edge cases (S1 orphan edits, S2 count preservation, S3 field doc) have been updated and validated.

---

## 1. What was verified, and how

| Check | Result |
|---|---|
| `D:\flutter\bin\flutter.bat analyze` | `No issues found! (ran in 1.4s)` |
| `D:\flutter\bin\flutter.bat test test/core/finance/spend_summary_test.dart` | **36 tests, all passed** |
| `D:\flutter\bin\flutter.bat test` | **1486 tests, all passed** |
| `dart format --output=none --set-exit-if-changed` on the 3 files | `portal_models.dart` would be reformatted — but only at **pre-existing** lines 81/100 (`toString` wrapping), not at the new `isAcquisition`; unrelated drift |
| Other consumers of the touched getters | searched; only `spend_summary.dart` and `portal_sync.dart` |
| Best evidence | replayed the live ledger fixture `scratch/portal_live/out/lab_ledger.html` row-by-row against the implementation |

---

## 2. Blocking finding

### B1 — The edit delta is subtracted nowhere: sign convention is inverted

Both the audit and the portal reference state the edit row's amount is **signed as a balance effect: negative = the meal became more expensive**:

- `docs/optimization-audit.md:491` — "`amountRial` آن **اختلاف علامت‌دار** است".
- `docs/portal-reference.md:452` — "مبلغ **علامت‌دار اختلاف** … (مثلاً `-150,000` برای **گران‌تر** شدن یا `+150,000` برای **ارزان‌تر** شدن)".
- `docs/portal-reference.md:470/475` — the two real edit rows for the same meal: `-150000` registers `چلو اکبرجوجه`, `+150000` registers `شوید پلو …`.

I rebuilt the chronological history for `1405/09/04 ناهار` directly from the fixture (`scratch/portal_live/out/lab_ledger.html`, outer rows carry the balance column):

| time | inner type | food | inner amount | balance after |
|---|---|---|---|---|
| 19:24:37 | `رزرو غذا` | شوید پلو با ماهی قزل | `350000` | 850 000 |
| 19:25:59 | `تغییر …` | چلو اکبرجوجه | `-150000` | 700 000 |
| 19:26:15 | `تغییر …` | چلو اکبرجوجه | `0` | 700 000 |
| 19:26:32 | `تغییر …` | شوید پلو با ماهی قزل | `150000` | 850 000 |

So `-150000` **raised** the held price from 350 000 to 500 000 and charged the student 150 000; `+150000` brought it back. The held price is therefore

```
price = bookingPrice − Σ(edit amount)
```

not `bookingPrice + Σ(edit amount)`. The implementation does the latter ([spend_summary.dart:332](D:/Bahonar-Nut/lib/core/finance/spend_summary.dart:332)):

```dart
} else if (event.isModification) {
  active = true;
  amountRial += event.amountRial;   // <-- must be -=
```

**Probe (temporary test, deleted afterwards), using the fixture's own rows:**

```
booking 350000 → edit -150000 (چلو اکبرجوجه)
  expected 500000   actual 200000
booking 700000 (count 2) → edit +150000 (drop to count 1)
  expected 350000   actual 1050000
```

Consequences:

- The most ordinary edit a student makes — "switch to the pricier hall and stop there" — under-reports the meal by `2 × 150 000`. A downgrade over-reports by the same amount. This is the exact class of financial misstatement M4 was opened to remove.
- Only **net-zero round trips** (`350k → -150k → +150k`, test #16) come out right, which is why the new suite passes. The plan's acceptance sentence is sign-agnostic; the correct sign still yields `350k` there, so this fix does not conflict with `docs/fix-plan.md` §5.1.
- The new test *"booking 500k then -150k leaves a 350k meal"* pins the inverted convention: under the portal's meaning that history is a **650 000** meal. The test must be rewritten, not merely supplemented.

**Required:**

1. `amountRial += event.amountRial` → `amountRial -= event.amountRial` (and adjust the branch comment: the ledger amount is the signed balance effect, so a negative edit raises the price).
2. Update the class-level and `Transaction.isModification` docs to state the sign meaning explicitly ("negative = more expensive") instead of the ambiguous "signed price difference".
3. Replace the `500k → -150k → 350k` test with the documented direction (`350k → -150k → 500k`, food becomes the new dish) and add the reverse (`500k → +150k → 350k`). Keep #16 (net-zero) as-is — it must still be `350k`.

---

## 3. Non-blocking findings

### S1 — A truncated ledger fabricates a zero-count, possibly negative meal

The modification branch sets `active = true` unconditionally ([spend_summary.dart:328-334](D:/Bahonar-Nut/lib/core/finance/spend_summary.dart:328)), on the stated rationale "when the ledger has been truncated it also initializes one". Probed with a lone edit row:

```
entries = 1, amount = -150000, count = 0, totalRial = -150000
```

That breaks the invariants `SpendEntry` and `averageMealRial` rely on (an "entry" is a held meal; `totalMeals` counts `count`), and it can publish a negative price per slot and per account. The booking branch guards its own count (`count = event.count > 0 ? event.count : 1`); the edit branch does not, which is inconsistent. Either:

- treat an orphan edit (no preceding acquisition in the replayed history) as **not held** and do not create an entry, or
- default the count to 1 and document that the amount is a lower bound,

and add a test for the truncated case, since the task explicitly asks for it.

### S2 — The new tests use a non-production `count` for edits

Every modification fixture in the "event-sourced edits" group takes the helper's default `count: 1`; the portal emits `تعداد = 0` on edit rows (`portal-reference.md:452, 470`). Because the branch only overwrites the count when `> 0`, the "an edit must not reset the booking's count" path is never exercised. Add `count: 0` to the edit fixtures (and one case where an edit carries `count: 2` to prove the count *is* updated).

### S3 — Drifted field doc on `excludedWithdrawn`

[spend_summary.dart:269-274](D:/Bahonar-Nut/lib/core/finance/spend_summary.dart:269) still says "because their most recent event was a withdrawal". With replay, the condition is "the key's **final state** is released" (a later edit can re-activate it). The class doc was rewritten; this field doc was not.

### S4 — Out of scope but worth a follow-up ticket

- `lib/platform/portal_sync.dart:343-345` still keys on "newest event" + `isAcquisition`, so if the newest row for a meal is an edit, the local meal mirror drops that meal. Behaviour is unchanged by this diff (an edit never matched `رزرو`), so it is not a regression — but it is the same M4 bug in a second consumer and could reuse the replay logic introduced here.
- A modification arriving *after* a withdrawal re-activates the meal (`active = true`) with the stale price plus the delta. Not reachable from the portal UI today; a comment/guard would make the intent explicit.

---

## 4. What is correct and should be kept

- `Transaction.isModification` (`type.contains('تغییر')`) and `isAcquisition` excluding both `انصراف` and `تغییر` — correct; the extra `!contains('تغییر')` is currently redundant (no type carries both words) but harmless as a guard. `isWithdrawal` is unchanged and still accurate.
- Grouping by `(accountId, date, slot)` and replaying `history.reversed`, given the documented newest-first document order — correct, and consistent with `parseTransactions` reading the inner grids in document order.
- A booking **sets** price/count/food (so a re-booking after a release adopts the new price), while edits adjust and may update the food — correct shape.
- `excludedWithdrawn` only for keys whose final state is released; a withdrawn-then-rebooked meal is held and not counted as "released" — correct, and no longer mislabels edits as withdrawals (`fix-plan.md` §5.2, second clause).
- Filters remain safe: all events of a key share account, date and slot, so filtering before grouping cannot strip a withdrawal from its booking.
- Entries sorting and the totals/by-slot/by-account plumbing are untouched; `isAcquisition` narrowing has no effect on any other consumer (verified: an edit row contains no `رزرو`).

---

## 5. Suggested tests after the fix

| # | Input (ledger order newest → oldest) | Expected |
|---|---|---|
| 16 | `350000 booking → +150000 edit → -150000 edit` | one meal, `350000`, count 1, not excluded |
| 17 | `350000 booking → -150000 edit → withdrawal` | excluded, `excludedWithdrawn == 1` |
| N1 | `350000 booking → -150000 edit` (new dish) | one meal, **500000**, new food, count 1 |
| N2 | `500000 booking → +150000 edit` (new dish) | one meal, **350000**, new food |
| N3 | `700000 booking (count 2) → +350000 edit (count 0)` | one meal, **350000**, count 2 |
| N4 | lone `-150000 edit` (truncated history) | documented decision; no zero-count/negative entry |
| N5 | `350000 booking → 0 edit → -150000 edit → +150000 edit` | one meal, `350000` (the real 09/04 shape) |
| N6 | re-booking after a release with a different price | final booking's price wins (already covered) |

---

## 6. Notes

- The net-zero acceptance test is a weak oracle for a signed-delta rule; N1/N2 exist precisely to pin the direction.
- The diff's docstrings are otherwise excellent: the "meals reserved, not eaten" caveat, the "newest first ⇒ replay reversed" rationale, and the explicit distinction between an edit and a release all match the audit and make future maintenance easier. Keep that style when correcting the sign.
- Test count moved 1480 → 1486 (6 new tests); none of the pre-existing 30 tests in this file regressed.

---

**Verdict: REQUEST CHANGES** — one blocking defect (B1, inverted edit-delta sign, with a wrong-expectation test), plus two should-fix items (S1 truncated-ledger entry, S2 edit fixtures' `count`). With B1 corrected and its test rewritten, this stage is otherwise ready.

---

## 7. Re-Verification Addendum (Final Sign-off)

**Date:** 2026-11-23  
**Status:** **CLOSED / FULL APPROVAL**

All conditions for approval have been fully addressed:
1. **B1 resolved:** `lib/core/finance/spend_summary.dart:332` corrected to `amountRial -= event.amountRial`. The comment and class docstrings now explicitly state that the portal's edit amount is the signed balance effect (negative = more expensive, positive = refund/cheaper).
2. **S1 & S2 resolved:** In `spend_summary.dart`, orphan edits without prior bookings initialize with `count = 1`. In tests, edit fixtures use production `count: 0`, and tests verify that an edit does not overwrite an existing positive count (e.g. `count: 2` preserved).
3. **Tests updated & expanded:**
   - `booking 350k → edit -150k (AkbarJuje)` yields 500,000 Rial.
   - `booking 500k → edit +150k (ShividPolo)` yields 350,000 Rial.
   - `booking 700k (count 2) → edit +350k (count 0)` yields 350,000 Rial with count 2 preserved.
   - `booking 350k → 0 edit → -150k edit → +150k edit` yields 350,000 Rial (real lab ledger sequence).
   - `orphan -150k edit` in truncated history yields 150,000 Rial and count 1.
4. **S3 resolved:** `excludedWithdrawn` doc comment updated to "pairs whose final state was a withdrawal".

Final Verdict: **FULL APPROVAL**.
