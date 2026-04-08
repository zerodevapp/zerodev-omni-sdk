package dev.zerodev.aa

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Loads the native zerodev_aa library.
 *
 * - **Android**: System.loadLibrary from APK's jniLibs/
 * - **Desktop JVM**: Extracts from JAR resources to a temp file, then System.load
 */
internal object NativeLoader {
    private val loaded = AtomicBoolean(false)

    @Synchronized
    fun load() {
        if (loaded.getAndSet(true)) return

        try {
            // Works on Android (loads from APK) and desktop if lib is on java.library.path
            System.loadLibrary("zerodev_aa")
        } catch (_: UnsatisfiedLinkError) {
            // Desktop JVM fallback: extract from JAR resources
            loadFromResources()
        }
    }

    private fun loadFromResources() {
        val (dir, name) = platformLibPath()
        val resource = "/$dir/$name"

        val input = NativeLoader::class.java.getResourceAsStream(resource)
            ?: throw UnsatisfiedLinkError("Native library not found in JAR: $resource")

        val tempDir = File(System.getProperty("java.io.tmpdir"), "zerodev-aa-native")
        tempDir.mkdirs()
        val tempFile = File(tempDir, name)

        input.use { src ->
            tempFile.outputStream().use { dst -> src.copyTo(dst) }
        }
        tempFile.deleteOnExit()

        System.load(tempFile.absolutePath)
    }

    private fun platformLibPath(): Pair<String, String> {
        val os = System.getProperty("os.name").lowercase()
        val arch = System.getProperty("os.arch").lowercase()

        val dir = when {
            os.contains("mac") || os.contains("darwin") -> when {
                arch.contains("aarch64") || arch.contains("arm64") -> "darwin-aarch64"
                else -> "darwin-x86-64"
            }
            os.contains("linux") -> when {
                arch.contains("aarch64") || arch.contains("arm64") -> "linux-aarch64"
                else -> "linux-x86-64"
            }
            else -> throw UnsatisfiedLinkError("Unsupported OS: $os $arch")
        }

        val name = when {
            os.contains("mac") || os.contains("darwin") -> "libzerodev_aa.dylib"
            else -> "libzerodev_aa.so"
        }

        return dir to name
    }
}
