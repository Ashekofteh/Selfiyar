#!/usr/bin/env bash
# Selfiyar dev environment template.
#
# Copy to scripts/env.sh and adjust the defaults below, then source it:
#   cp scripts/env.example.sh scripts/env.sh
#   source scripts/env.sh
#
# scripts/env.sh is gitignored on purpose: it holds machine-specific paths.
# This template is the committed copy.
#
# Cross-platform: detects Git Bash / MSYS2 (MINGW*), macOS (Darwin*), and
# Linux; converts Windows-style paths to the POSIX form Git Bash needs for
# PATH lookup; uses ${VAR:-default} so existing exports win; and warns
# instead of dying, so sourcing it can never kill an interactive shell.

# --- Toolchain roots: override any of these by exporting it first ----------
FLUTTER_ROOT="${FLUTTER_ROOT:-/d/flutter}"
ANDROID_HOME="${ANDROID_HOME:-/d/Android/android-sdk}"
JAVA_HOME="${JAVA_HOME:-/d/Android/openjdk/jdk-17.0.8.101-hotspot}"
# Gradle's cache and daemon live here, off the system drive (C: fills up
# during Android builds; D: has the headroom).
GRADLE_USER_HOME="${GRADLE_USER_HOME:-/d/gradle-home}"

# --- OS detection -----------------------------------------------------------
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) SELFIYAR_OS="windows" ;;
  Darwin*)              SELFIYAR_OS="macos" ;;
  *)                    SELFIYAR_OS="linux" ;;
esac

# --- OS-aware defaults ------------------------------------------------------
# Windows AVD/user homes are pinned to D: for room; other platforms use the
# standard $HOME locations.
ANDROID_AVD_HOME_DEFAULT="${ANDROID_AVD_HOME:-/d/Android/avd}"
ANDROID_USER_HOME_DEFAULT="${ANDROID_USER_HOME:-/d/Android/android-home}"
if [ "$SELFIYAR_OS" != "windows" ]; then
  ANDROID_AVD_HOME_DEFAULT="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
  ANDROID_USER_HOME_DEFAULT="${ANDROID_USER_HOME:-$HOME/.android}"
fi

# --- Helpers ----------------------------------------------------------------
# Windows-style paths ("D:\flutter", "D:/flutter") do not resolve for command
# lookup in Git Bash; convert them to the POSIX form "/d/flutter".
selfiyar_posix_path() {
  local p="$1"
  if [ "$SELFIYAR_OS" = "windows" ]; then
    p="${p//\\//}"
    if [[ "$p" =~ ^([A-Za-z]):(.*)$ ]]; then
      p="/$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')${BASH_REMATCH[2]}"
    fi
  fi
  printf '%s' "$p"
}

# Export $1 only if it points at a real directory; otherwise warn and move on.
selfiyar_export_dir() {
  local name="$1" value
  value="$(selfiyar_posix_path "${!name}")"
  if [ ! -d "$value" ]; then
    echo "env.sh: WARNING: $name=$value does not exist — not exported." >&2
    return 0
  fi
  export "$name=$value"
}

# Prepend $1 to PATH only if it exists and is not already on PATH.
selfiyar_prepend_path() {
  local dir
  dir="$(selfiyar_posix_path "$1")"
  if [ ! -d "$dir" ]; then
    echo "env.sh: WARNING: $dir does not exist — not added to PATH." >&2
    return 0
  fi
  case ":$PATH:" in
    *":$dir:"*) : ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

# --- Apply -------------------------------------------------------------------
# Cache and emulator homes are created on demand so first-time sourcing works.
mkdir -p "$GRADLE_USER_HOME" "$ANDROID_AVD_HOME_DEFAULT" "$ANDROID_USER_HOME_DEFAULT" 2>/dev/null \
  || echo "env.sh: WARNING: could not create a tool directory — continuing without it." >&2

selfiyar_export_dir FLUTTER_ROOT
selfiyar_export_dir JAVA_HOME
selfiyar_export_dir ANDROID_HOME

export ANDROID_AVD_HOME="$ANDROID_AVD_HOME_DEFAULT"
export ANDROID_USER_HOME="$ANDROID_USER_HOME_DEFAULT"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
# ANDROID_SDK_ROOT is the canonical name; ANDROID_HOME is the legacy alias
# some tools still read. Keep them pointing at the same validated directory.
ANDROID_HOME="$ANDROID_SDK_ROOT"

selfiyar_prepend_path "$FLUTTER_ROOT/bin"
selfiyar_prepend_path "$JAVA_HOME/bin"
selfiyar_prepend_path "$ANDROID_HOME/platform-tools"
selfiyar_prepend_path "$ANDROID_HOME/emulator"
selfiyar_prepend_path "$ANDROID_HOME/cmdline-tools/7.0/bin"

# Leave no helper functions behind in the sourcing shell.
unset -f selfiyar_posix_path selfiyar_export_dir selfiyar_prepend_path
