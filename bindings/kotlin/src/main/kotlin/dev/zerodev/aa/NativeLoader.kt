package dev.zerodev.aa

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Loads the native zerodev_aa library.
 *
 * - **Android**: Extracts from JAR resources to app cache, then System.load
 * - **Desktop JVM**: Extracts from JAR resources to temp dir, then System.load
 * - Falls back to System.loadLibrary if bundled resources aren't found
 */
internal object NativeLoader {
    private val loaded = AtomicBoolean(false)

    @Synchronized
    fun load() {
        if (loaded.getAndSet(true)) return

        try {
            // Try system path first (works if lib is in jniLibs/ on Android or java.library.path on JVM)
            System.loadLibrary("zerodev_aa")
        } catch (_: UnsatisfiedLinkError) {
            // Extract from JAR resources
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

    private val isAndroid: Boolean by lazy {
        try {
            Class.forName("android.os.Build")
            true
        } catch (_: ClassNotFoundException) {
            false
        }
    }

    private fun platformLibPath(): Pair<String, String> {
        val arch = System.getProperty("os.arch").lowercase()

        if (isAndroid) {
            val dir = when {
                arch.contains("aarch64") || arch.contains("arm64") -> "android-aarch64"
                arch.contains("x86_64") || arch.contains("amd64") -> "android-x86-64"
                else -> throw UnsatisfiedLinkError("Unsupported Android arch: $arch")
            }
            return dir to "libzerodev_aa.so"
        }

        val os = System.getProperty("os.name").lowercase()
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
