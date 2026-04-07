plugins {
    kotlin("jvm") version "2.1.10"
    kotlin("plugin.serialization") version "2.1.10"
    `maven-publish`
    signing
}

group = "app.zerodev"
version = "0.0.1-alpha"

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
    mavenCentral()
}

dependencies {
    implementation("net.java.dev.jna:jna:5.16.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    // Use bundled resources if available, fall back to zig-out for local dev
    val libPath = file("${rootProject.projectDir}/../../zig-out/lib").absolutePath
    systemProperty("jna.library.path", libPath)
    environment("ZERODEV_PROJECT_ID", System.getenv("ZERODEV_PROJECT_ID") ?: "")
    environment("E2E_PRIVATE_KEY", System.getenv("E2E_PRIVATE_KEY") ?: "")
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])

            artifactId = "zerodev-aa"

            pom {
                name.set("ZeroDev AA SDK")
                description.set("ERC-4337 smart account SDK for Kotlin/JVM — bundled native libraries, zero setup")
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
    }

    repositories {
        maven {
            name = "OSSRH"
            url = uri(
                if (version.toString().endsWith("-SNAPSHOT"))
                    "https://s01.oss.sonatype.org/content/repositories/snapshots/"
                else
                    "https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/"
            )
            credentials {
                username = System.getenv("OSSRH_USERNAME") ?: ""
                password = System.getenv("OSSRH_PASSWORD") ?: ""
            }
        }
    }
}

signing {
    val signingKey = System.getenv("GPG_PRIVATE_KEY")
    val signingPassword = System.getenv("GPG_PASSPHRASE")
    if (signingKey != null && signingPassword != null) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications["maven"])
    }
}
