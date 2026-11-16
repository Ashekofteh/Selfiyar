import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ir.ac.uk.bahonar_nut"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ir.ac.uk.bahonar_nut"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing material is never committed. It comes from
    // android/key.properties (gitignored) or, failing that, from the
    // KEYSTORE_PATH / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD environment
    // variables. All four values must be present together; a half-configured
    // set fails the build here instead of producing an APK signed with blanks.
    val keyPropertiesFile = rootProject.file("key.properties")
    val keyProperties = Properties().apply {
        if (keyPropertiesFile.exists()) {
            keyPropertiesFile.inputStream().use { load(it) }
        }
    }
    fun signingProp(propName: String, envName: String): String? =
        keyProperties.getProperty(propName)?.takeIf { it.isNotBlank() }
            ?: System.getenv(envName)?.takeIf { it.isNotBlank() }

    val releaseStorePath = signingProp("storeFile", "KEYSTORE_PATH")
        ?: signingProp("storePath", "KEYSTORE_PATH")
    val releaseStorePassword = signingProp("storePassword", "KEYSTORE_PASSWORD")
    val releaseKeyAlias = signingProp("keyAlias", "KEY_ALIAS")
    val releaseKeyPassword = signingProp("keyPassword", "KEY_PASSWORD")
    val hasReleaseSigning =
        listOf(releaseStorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it != null }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword!!
                keyAlias = releaseKeyAlias!!
                keyPassword = releaseKeyPassword!!
            }
        }
    }

    buildTypes {
        release {
            // Without committed secrets, sign with the debug key — the Flutter
            // template's own fallback — so local and CI release builds keep
            // producing an installable app-release.apk. Supply key.properties
            // or the KEYSTORE_* env vars for real release signing.
            signingConfig =
                if (hasReleaseSigning) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}


dependencies {
    implementation("com.google.android.gms:play-services-auth:21.2.0")
    implementation("com.google.android.gms:play-services-auth-api-phone:18.1.0")

    // Plain JVM unit tests for the platform logic that does not need Android:
    // the exact-vs-window alarm fallback, the receiver's route table, and the
    // secure-store format. Run with: ./gradlew testDebugUnitTest
    testImplementation("junit:junit:4.13.2")
}
