import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/reminder.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppState accounts', () {
    test('starts empty', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();
      expect(state.accounts, isEmpty);
      expect(state.isLoaded, isTrue);
    });

    test('adds an account and resolves its name', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.upsertAccount(studentId: '400123456', alias: 'برادر');
      expect(state.accounts, hasLength(1));
      expect(state.accounts.single.resolvedName, 'برادر');
    });

    test('a blank student id is rejected with an error', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.upsertAccount(studentId: '   ');
      expect(state.accounts, isEmpty);
      expect(state.error, isNotNull);
    });

    test('adding the same student id updates rather than duplicates', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.upsertAccount(studentId: '400123456', alias: 'یک');
      await state.upsertAccount(studentId: '400123456', alias: 'دو');
      expect(state.accounts, hasLength(1));
      expect(state.accounts.single.resolvedName, 'دو');
    });

    test('clearing an alias falls back to the profile name', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.upsertAccount(studentId: '400123456', alias: 'برادر');
      final id = state.accounts.single.id;
      await state.setProfileName(id, 'رضا شريفي');
      await state.setAlias(id, '   ');

      expect(state.accounts.single.resolvedName, 'رضا شريفي');
    });

    test('removing an account takes it out of the list', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.upsertAccount(studentId: '400123456');
      final id = state.accounts.single.id;
      await state.removeAccount(id);
      expect(state.accounts, isEmpty);
    });
  });

  group('AppState reminders', () {
    test('the master switch defaults on and can be turned off', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      expect(state.reminderConfig.masterEnabled, isTrue);

      await state.saveReminderConfig(const ReminderConfig(masterEnabled: false));
      expect(state.reminderConfig.masterEnabled, isFalse);
    });

    test('the default times are 10:30 and 16:30', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      expect(state.reminderConfig.lunch.time.hour, 10);
      expect(state.reminderConfig.lunch.time.minute, 30);
      expect(state.reminderConfig.evening.time.hour, 16);
      expect(state.reminderConfig.evening.time.minute, 30);
    });

    test('toggling an account adds then removes it', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.toggleReminderAccount('a1');
      expect(state.reminderConfig.accountIds, {'a1'});

      await state.toggleReminderAccount('a1');
      expect(state.reminderConfig.accountIds, isEmpty);
    });

    test('toggling an account preserves the other settings', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.saveReminderConfig(const ReminderConfig(
        masterEnabled: false,
        lunch: ReminderSlotConfig(
          slot: ReminderSlot.lunch,
          time: ClockTime(11, 0),
          covers: {MealSlot.lunch},
        ),
      ));
      await state.toggleReminderAccount('a1');

      expect(state.reminderConfig.masterEnabled, isFalse);
      expect(state.reminderConfig.lunch.time.hour, 11);
    });

    test('toggling an account never silently re-enables the master switch',
        () async {
      // This was a real bug: the toggle rebuilt the config field-by-field and
      // omitted masterEnabled, so turning the whole feature off and then
      // touching an account turned every reminder back on.
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.saveReminderConfig(const ReminderConfig(masterEnabled: false));
      await state.toggleReminderAccount('a1');
      await state.toggleReminderAccount('a1');

      expect(state.reminderConfig.masterEnabled, isFalse,
          reason: 'the master switch must survive any other change');
    });

    test('the nudge toggle survives an account change', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      await state.saveReminderConfig(
        ReminderConfig(nextWeekNudgeEnabled: false),
      );
      await state.toggleReminderAccount('a1');
      expect(state.reminderConfig.nextWeekNudgeEnabled, isFalse);
    });
  });

  group('AppState dashboard filter', () {
    test('toggling an account and a slot composes', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      state.toggleSpendAccount('a1');
      state.toggleSpendSlot(MealSlot.lunch);

      expect(state.spendFilter.accountIds, {'a1'});
      expect(state.spendFilter.slots, {MealSlot.lunch});
      expect(state.spendFilter.isUnfiltered, isFalse);
    });

    test('clearing returns to showing everything', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
      );
      await state.load();

      state.toggleSpendAccount('a1');
      state.clearSpendFilter();
      expect(state.spendFilter.isUnfiltered, isTrue);
    });

    test('the summary honours the filter', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        transactions: [
          const Transaction(
            accountId: 'a1',
            type: 'رزرو غذا',
            foodName: 'چلو اکبرجوجه',
            slot: MealSlot.lunch,
            weekday: 'سه شنبه',
            date: '1405/07/28',
            count: 1,
            amountRial: 500000,
          ),
          const Transaction(
            accountId: 'a2',
            type: 'رزرو غذا',
            foodName: 'شیر',
            slot: MealSlot.breakfast,
            weekday: 'دوشنبه',
            date: '1405/07/27',
            count: 1,
            amountRial: 150000,
          ),
        ],
      );
      await state.load();

      expect(state.spendSummary.totalRial, 650000);

      state.toggleSpendAccount('a1');
      expect(state.spendSummary.totalRial, 500000);

      state.clearSpendFilter();
      state.toggleSpendSlot(MealSlot.breakfast);
      expect(state.spendSummary.totalRial, 150000);
    });
  });

  group('AppState hunt config management', () {
    test('saveHuntConfigFor saves for specified account without modifying active account', () async {
      final accountStore = InMemoryAccountStore();
      final huntStore = InMemoryHuntConfigStore();
      final state = AppState(
        accountStore: accountStore,
        reminderConfigStore: InMemoryReminderConfigStore(),
        huntConfigStore: huntStore,
      );
      await state.load();
      await state.upsertAccount(studentId: '111', alias: 'Acc 1');
      await state.upsertAccount(studentId: '222', alias: 'Acc 2');
      final acc1 = state.accounts[0].id;
      final acc2 = state.accounts[1].id;

      state.selectHuntAccount(acc1);
      await state.saveHuntConfig(HuntConfig(enabled: true));

      // Save for acc2 while acc1 is active
      await state.saveHuntConfigFor(acc2, HuntConfig(enabled: false));

      expect(state.huntConfigFor(acc1)?.enabled, isTrue);
      expect(state.huntConfigFor(acc2)?.enabled, isFalse);
      expect(state.activeHuntConfig?.enabled, isTrue);

      final loadedAcc2 = await huntStore.load(acc2);
      expect(loadedAcc2?.enabled, isFalse);
    });

    test('reloadHuntConfigs updates in-memory configs from persistent store', () async {
      final accountStore = InMemoryAccountStore();
      final huntStore = InMemoryHuntConfigStore();
      final state = AppState(
        accountStore: accountStore,
        reminderConfigStore: InMemoryReminderConfigStore(),
        huntConfigStore: huntStore,
      );
      await state.load();
      await state.upsertAccount(studentId: '111', alias: 'Acc 1');
      final acc1 = state.accounts.single.id;

      state.selectHuntAccount(acc1);
      await state.saveHuntConfig(HuntConfig(enabled: true));
      expect(state.activeHuntConfig?.enabled, isTrue);

      // Simulate external background execution modifying store to disabled
      await huntStore.save(acc1, HuntConfig(enabled: false));
      expect(state.activeHuntConfig?.enabled, isTrue); // still true before reload

      // Reload
      await state.reloadHuntConfigs();
      expect(state.activeHuntConfig?.enabled, isFalse);
    });
  });
}

