#!/usr/bin/env bash
# Selfiyar dev environment. Source this before flutter/dart commands:
#   source scripts/env.sh
#
# Paths verified on this machine 2026-10-18. Note: PATH entries must use the
# POSIX /d/... form in Git Bash — Windows-style "D:/..." entries do not resolve
# for command lookup in this shell, even though they work as command arguments.

export FLUTTER_ROOT="/d/flutter"
export ANDROID_HOME="/d/Android/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_AVD_HOME="D:/Android/avd"
export ANDROID_USER_HOME="D:/Android/android-home"
export JAVA_HOME="/d/Android/openjdk/jdk-17.0.8.101-hotspot"

export PATH="$FLUTTER_ROOT/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/7.0/bin:$PATH"

# Keep Gradle's cache and daemon off the C: drive, which runs near-full on this
# machine (C: hit 0 bytes free during the first APK build attempt). D: has room.
export GRADLE_USER_HOME="/d/gradle-home"