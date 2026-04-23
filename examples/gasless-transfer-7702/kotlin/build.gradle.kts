plugins {
    kotlin("jvm") version "2.1.10"
    application
}

application {
    mainClass.set("MainKt")
}

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
    implementation("dev.zerodev:zerodev-aa")
}

tasks.named<JavaExec>("run") {
    val libPath = file("${rootProject.projectDir}/../../../zig-out/lib").absolutePath
    systemProperty("jna.library.path", libPath)
}
