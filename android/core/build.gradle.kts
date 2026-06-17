// :core — pure Kotlin/JVM matcher library.
//
// Stays JVM-only (no Android dependencies) so port-parity tests run on the
// host JVM during `./gradlew :core:test`. The Android :app module depends on
// :core and provides the Android-specific corpus loader
// (android.database.sqlite-backed) on top.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(17)
}

tasks.withType<Test> {
    useJUnitPlatform()
    // Forward the env var the port-parity test needs to locate the corpus.
    systemProperty(
        "junit.jupiter.execution.parallel.enabled",
        "false"
    )
    // The Corpus path comes from env GURBANILENS_CORPUS_PATH; tests skip if missing.
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
