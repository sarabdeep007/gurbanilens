// :app — main Android application.
//
// v1 scope is voice-search Gurbani — tap-to-record + Whisper transcription +
// matcher (from :core) + Shabad display. UI scaffolded in a follow-up commit.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.taajsingh.gurbanilens"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.taajsingh.gurbanilens"
        minSdk = 26                          // ~95% device coverage
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0-v1-alpha"
        vectorDrawables { useSupportLibrary = true }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
        jniLibs {
            useLegacyPackaging = false
        }
    }

    // Don't compress the bundled SQLite + Whisper ggml model assets:
    //  1. SQLite must stay store-mode so the driver can mmap it from inside
    //     the APK (compressed assets can't be mmap'd; the driver would have
    //     to copy 158 MB to internal storage on first launch).
    //  2. The .bin Whisper weights are already a tightly packed binary format;
    //     compression adds no benefit and bloats the packager's working set.
    //  3. Crucially, store-mode lets `packageDebug` stream the asset bytes
    //     straight from disk into the APK zip instead of buffering the deflate
    //     output in memory — without this the packager OOM-kills the Gradle
    //     daemon on the 3.7 GB build host.
    androidResources {
        noCompress.addAll(listOf("sqlite", "bin"))
    }

    testOptions {
        unitTests {
            isReturnDefaultValues = true
            isIncludeAndroidResources = true
        }
    }
}

// Produce JVM 17 bytecode (Android 8.0+ runtime). Build runs on whatever JDK
// JAVA_HOME points at (we have JDK 21). AGP 8.6 supports JDK 17–21.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    // Icons used by v1 (Mic / Settings / Close / Check / Share / Refresh /
    // ArrowBack) all live in `material-icons-core`. The much larger
    // `material-icons-extended` (~30 MB of generated Kotlin) was previously
    // listed; on memory-constrained build hosts its dex/merge pass OOM-kills
    // the Gradle daemon. Switched to core 2026-06-21.
    implementation(libs.androidx.material.icons.core)
    implementation(libs.kotlinx.coroutines.android)

    // ui-tooling brings the Android Studio @Preview runtime + Layout Inspector.
    // It's debug-only and useful in the IDE, but it ~doubles the debug dex size
    // and OOM-kills the dex merger on our 3.7 GB build host. Re-enable when
    // building on a bigger machine if you want to use `@Preview` in Studio.
    // debugImplementation(libs.androidx.ui.tooling)

    // Unit tests (host JVM). Robolectric lets us drive AudioRecord and
    // AssetManager without an emulator.
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.mockk)
}
