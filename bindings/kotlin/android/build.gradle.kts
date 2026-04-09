plugins {
    id("com.android.library") version "8.7.3"
    kotlin("android")
    kotlin("plugin.serialization")
    `maven-publish`
    signing
    id("net.thebugmc.gradle.sonatype-central-portal-publisher") version "1.2.4"
}

group = "app.zerodev"
version = "0.0.1-alpha"

android {
    namespace = "dev.zerodev.aa"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }

    // Native .so files go here — CI populates jniLibs/
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

dependencies {
    // Re-export the core Kotlin module (all public API comes from here)
    api(project(":"))
}

centralPortal {
    name = "zerodev-aa"
    username = System.getenv("OSSRH_USERNAME") ?: ""
    password = System.getenv("OSSRH_PASSWORD") ?: ""

    pom {
        name.set("ZeroDev AA SDK (Android)")
        description.set("ERC-4337 smart account SDK for Android — bundled native libraries, zero setup")
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
