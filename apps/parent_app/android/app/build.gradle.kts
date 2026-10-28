plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val familyStore = System.getenv("FAMILY_ANDROID_KEYSTORE")
val familyStorePassword = System.getenv("FAMILY_ANDROID_STORE_PASSWORD")
val familyKeyAlias = System.getenv("FAMILY_ANDROID_KEY_ALIAS")
val familyKeyPassword = System.getenv("FAMILY_ANDROID_KEY_PASSWORD") ?: familyStorePassword
val familySigningReady = listOf(familyStore, familyStorePassword, familyKeyAlias, familyKeyPassword).all { !it.isNullOrBlank() }
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !familySigningReady) {
    throw GradleException("Release requires FAMILY_ANDROID_KEYSTORE, FAMILY_ANDROID_STORE_PASSWORD and FAMILY_ANDROID_KEY_ALIAS; configure the existing signing key before building.")
}

android {
    namespace = "cn.familyvideo.parent_app"
    compileSdk = 36 // mobile_scanner 的 camera 1.6 要求 API 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.familyvideo.parent_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24 // mobile_scanner 23 + video_player fork 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (familySigningReady) {
            create("familyRelease") {
                storeFile = file(familyStore!!)
                storePassword = familyStorePassword
                keyAlias = familyKeyAlias
                keyPassword = familyKeyPassword
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (familySigningReady) signingConfigs.getByName("familyRelease") else null
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
