plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val familyStore = System.getenv("FAMILY_ANDROID_KEYSTORE")
val familyStorePassword = System.getenv("FAMILY_ANDROID_STORE_PASSWORD")
val familyKeyAlias = System.getenv("FAMILY_ANDROID_KEY_ALIAS")
val familyKeyPassword = System.getenv("FAMILY_ANDROID_KEY_PASSWORD") ?: familyStorePassword
val familySigningReady = listOf(familyStore, familyStorePassword, familyKeyAlias, familyKeyPassword)
    .all { !it.isNullOrBlank() }
// A minified, debug-signed trial APK is separate from the production release.
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !familySigningReady) {
    throw GradleException("Release requires FAMILY_ANDROID_KEYSTORE, FAMILY_ANDROID_STORE_PASSWORD and FAMILY_ANDROID_KEY_ALIAS.")
}

android {
    namespace = "cn.familyvideo.tv_app"
    compileSdk = 35
    defaultConfig {
        applicationId = "cn.familyvideo.tv_app"
        minSdk = 21
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        resourceConfigurations += listOf("zh", "en")
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
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
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = if (familySigningReady) signingConfigs.getByName("familyRelease") else null
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        create("trial") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    // Pin to a line that supports API 21. Newer Media3 lines require API 23.
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-ui:1.5.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
