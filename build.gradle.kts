import org.gradle.jvm.tasks.Jar

plugins {
    kotlin("jvm") version "2.3.0-Beta2"
    kotlin("plugin.serialization") version "2.0.0"
    application
    id("com.gradleup.shadow") version "9.2.2"
}

group = "com.github.kernitus"
version = "0.1.0"

repositories {
    mavenCentral()
}

dependencies {
    implementation(kotlin("stdlib"))

    // Koog agents
    implementation("ai.koog:koog-agents:0.5.3")

    // JSON for decoding the envelope from Lua
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    // Msgpack for RPC communication
    implementation("org.msgpack:msgpack-core:0.9.10")
    // Msgpack for Kotlin object serialisation
    implementation("com.ensarsarajcic.kotlinx:serialization-msgpack:0.6.0")

}

application {
    mainClass.set("com.github.kernitus.neoai.DaemonKt")
}

// Use a stable LTS JDK for both Java and Kotlin
java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(25))
    }
}

kotlin {
    jvmToolchain(25)
}

tasks.named<Jar>("shadowJar") {
    archiveFileName.set("neoai-daemon-all.jar")
}
