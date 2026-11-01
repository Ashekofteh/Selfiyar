# Changelog

All notable changes to **Selfiyar (سِلفیار)** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-11-01

### Added
- **Official Stable Release:** First non-beta production release supporting Android, iOS, Windows, macOS, and Linux.
- **Smart Background Food Basket Monitor:** Autonomous 15-minute periodic monitor that tracks active basket listings with zero battery drain when idle, automatic distribution cutoff detection, and instant Persian notifications when a meal is sold.
- **Multi-Account Hunt Picker:** Instant account switching within the Hunt screen, preserving independent configurations, target dates, and meal schedules for each student account.
- **Context-Aware Hunt Action Button:** Intelligent bottom action button adapting between immediate execution, automatic scheduling, schedule cancellation, and expiration alerts based on the meal's time window.
- **Dedicated Meal Reminder Screen:** Rich reminder view with direct deep-linking from system notifications.
- **Automatic SQL Server Deadlock Recovery:** Transient error classification and exponential backoff retry mechanism for university server database deadlocks.

### Fixed
- **Two-Step Food Basket Sale:** Implemented complete WebForms postback lifecycle (`btnFoodReload` followed by `btnFoodSell` and `btnCancel`), ensuring listings reliably register on the Cullinan portal.
- **Receipt Code Locking:** Disabled receipt issuance while a meal is listed in the Food Basket to prevent invalid portal voucher states.
- **Pre-Cancellation Sale Check:** Validated current reservation state before cancelling sale listings to notify users if a meal was already purchased.

### Changed
- Refactored repository structure to international open-source standards with streamlined root files, clean CI/CD workflows, and zero analyzer warnings.
