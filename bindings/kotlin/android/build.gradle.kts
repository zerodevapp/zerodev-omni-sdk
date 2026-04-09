plugins {
    id("com.android.library")
    kotlin("android")
    kotlin("plugin.serialization")
    `maven-publish`
    signing
    id("net.thebugmc.gradle.sonatype-central-portal-publisher")
}

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

    sourceSets["main"].apply {
        java.srcDir("../src/main/kotlin")
        manifest.srcFile("src/main/AndroidManifest.xml")
        jniLibs.srcDir("src/main/jniLibs")
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

publishing {
    publications {
        register<MavenPublication>("release") {
            artifactId = "zerodev-aa"
            afterEvaluate {
                from(components["release"])
            }
        }
    }
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
