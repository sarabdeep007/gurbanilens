// :core — pure Kotlin/JVM matcher library.
//
// Stays JVM-only (no Android dependencies) so port-parity tests run on the
// host JVM during `./gradlew :core:test`. The Android :app module depends on
// :core and provides the Android-specific corpus loader
// (android.database.sqlite-backed) on top.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Emit JVM 17 bytecode (Android 8.0+ runtime via desugaring; native on JVM 17).
// The build itself runs on whatever JDK is in JAVA_HOME (we have JDK 21).
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
    systemProperty("junit.jupiter.execution.parallel.enabled", "false")
    environment(
        "GURBANILENS_CORPUS_PATH",
        System.getenv("GURBANILENS_CORPUS_PATH") ?: ""
    )
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
    }
}

dependencies {
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.sqlite.jdbc)
    testImplementation(libs.org.json)
}
