# R8 rules for Selfiyar release builds (referenced by app/build.gradle.kts).
# flutter build already adds rules for the engine and the plugins; these keep
# this app's own framework-instantiated entry points from being renamed or
# shrunk away.

# Manifest entry points (MainActivity, HuntService, BootReceiver,
# ReminderAlarmReceiver) and every other class in the package.
-keep class ir.ac.uk.bahonar_nut.** { *; }

# The embedding's activity base class.
-keep class io.flutter.embedding.android.FlutterActivity { *; }

# Named explicitly because the background hunt engine and the foreground
# service it runs inside are reached by class name from platform channels,
# boot alarms, and the alarm scheduler.
-keep class ir.ac.uk.bahonar_nut.BackgroundHuntEngine { *; }
-keep class ir.ac.uk.bahonar_nut.HuntService { *; }
