plugins {
    kotlin("jvm") version "2.1.10"
    kotlin("plugin.serialization") version "2.1.10"
}

group = "dev.zerodev"
version = "0.1.0"

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("net.java.dev.jna:jna:5.16.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    val libPath = file("${rootProject.projectDir}/../../zig-out/lib").absolutePath
    systemProperty("jna.library.path", libPath)
    environment("ZERODEV_PROJECT_ID", System.getenv("ZERODEV_PROJECT_ID") ?: "")
    environment("E2E_PRIVATE_KEY", System.getenv("E2E_PRIVATE_KEY") ?: "")
}
