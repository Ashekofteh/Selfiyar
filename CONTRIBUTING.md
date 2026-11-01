# Contributing to Selfiyar (سِلفیار)

Thank you for your interest in contributing to **Selfiyar**! We welcome contributions that adhere to the code quality, testing standards, and architectural conventions of the project.

---

## Code of Conduct

- Be respectful, constructive, and collaborative in discussions, issues, and code reviews.
- Focus on maintaining the reliability, privacy, and speed of the university dining automation client.

---

## Development Setup

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.13.5+ or latest stable)
- [Android SDK](https://developer.android.com/studio) (API level 24+)
- **Windows:** Visual Studio with C++ Desktop Development tools
- **macOS & iOS:** macOS with Xcode and Command Line Tools
- **Linux:** `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`

### Getting Started

1. **Fork and clone the repository:**
   ```bash
   git clone https://github.com/Ashekofteh/Selfiyar.git
   cd Selfiyar
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Verify the static analyzer and test suite:**
   ```bash
   dart analyze lib/
   flutter test
   ```
   > All 1060+ tests must pass with zero analyzer warnings before submitting a pull request.

---

## Architectural Principles

1. **Pure Domain Logic (`lib/core/`):**
   - Must remain platform-agnostic and free of any `package:flutter/*` or `dart:io` imports.
   - All models, business rules, and rankers are 100% unit testable on the standard Dart VM.

2. **Isolated Transport & Parser (`lib/transport/`, `lib/adapter/`):**
   - Keep ASP.NET WebForms parsing decoupled and auditable.
   - All HTML parsers are backed by tests against real captures in `test/adapter/`.

3. **Zero Unnecessary Network Requests:**
   - Reuse existing responses and piggyback balance / user name extractions rather than sending duplicate requests.
   - Use `version.json` via CDN for rate-limit-free version updates.

4. **Right-to-Left (RTL) First:**
   - The UI is designed for Persian speakers; ensure proper layout alignment, Persian digit formatting (`persian.dart`), and localization support.

---

## Pull Request Guidelines

1. Create a descriptive feature branch:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. Commit your changes using conventional commit messages (`feat:`, `fix:`, `perf:`, `test:`, `docs:`, `chore:`).
3. Ensure all existing tests pass and add unit tests for any new logic.
4. Submit your pull request with a clear description of the problem solved and testing steps performed.
