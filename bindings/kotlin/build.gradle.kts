plugins {
    kotlin("jvm") version "2.1.20"
    kotlin("android") version "2.1.20" apply false
    kotlin("plugin.serialization") version "2.1.20"
    id("com.android.library") version "8.9.0" apply false
    `maven-publish`
    signing
    id("net.thebugmc.gradle.sonatype-central-portal-publisher") version "1.2.4"
}

group = "app.zerodev"
version = "0.0.1-alpha"

subprojects {
    group = rootProject.group
    version = rootProject.version

    repositories {
        google()
        mavenCentral()
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
    withSourcesJar()
    withJavadocJar()
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

repositories {
    google()
    mavenCentral()
    gradlePluginPortal()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

publishing {
    publications {
        create<MavenPublication>("mavenJava") {
            artifactId = "zerodev-aa-jvm"
            from(components["java"])
        }
    }
}

tasks.test {
    useJUnitPlatform()
    // For local dev: add zig-out/lib to java.library.path so JNI can find the native lib
    val libPath = file("${rootProject.projectDir}/../../zig-out/lib").absolutePath
    systemProperty("java.library.path", libPath)
    environment("ZERODEV_PROJECT_ID", System.getenv("ZERODEV_PROJECT_ID") ?: "")
    environment("E2E_PRIVATE_KEY", System.getenv("E2E_PRIVATE_KEY") ?: "")
}

centralPortal {
    name = "zerodev-aa-jvm"
    username = System.getenv("OSSRH_USERNAME") ?: ""
    password = System.getenv("OSSRH_PASSWORD") ?: ""

    pom {
        name.set("ZeroDev AA SDK (JVM)")
        description.set("ERC-4337 smart account SDK for desktop JVM — bundled native libraries, zero setup")
        url.set("https://github.com/zerodevapp/zerodev-omni-sdk")

        licenses {
            license {
                name.set("MIT License")
                url.set("https://opensource.org/licenses/MIT")
            }
        }

        developers {
            developer {
                id.set("zerodev")
                name.set("ZeroDev")
                url.set("https://zerodev.app")
            }
        }

        scm {
            url.set("https://github.com/zerodevapp/zerodev-omni-sdk")
            connection.set("scm:git:git://github.com/zerodevapp/zerodev-omni-sdk.git")
            developerConnection.set("scm:git:ssh://github.com/zerodevapp/zerodev-omni-sdk.git")
        }
    }
}

signing {
    val signingKey = System.getenv("GPG_PRIVATE_KEY")
    val signingPassword = System.getenv("GPG_PASSPHRASE")
    if (signingKey != null && signingPassword != null) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications)
    }
}
