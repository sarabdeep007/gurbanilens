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
        // Don't compress the bundled SQLite asset — lets the SQLite driver
        // mmap it from the APK directly. Whisper .bin model is already
        // tightly packed; leave it uncompressed too for fast startup.
        jniLibs {
            useLegacyPackaging = false
        }
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
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.kotlinx.coroutines.android)

    debugImplementation(libs.androidx.ui.tooling)

    // Unit tests (host JVM). Robolectric lets us drive AudioRecord and
    // AssetManager without an emulator.
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.mockk)
}
