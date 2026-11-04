package com.example.askme

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val channelName = "askme/offline_model"
    private val pickModelRequest = 7412
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importModel" -> {
                        if (pendingResult != null) {
                            result.error("IMPORT_BUSY", "A model import is already in progress.", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                                "application/octet-stream", "application/x-gguf", "application/gguf"
                            ))
                        }
                        try {
                            startActivityForResult(intent, pickModelRequest)
                        } catch (e: Exception) {
                            pendingResult = null
                            result.error("PICKER_UNAVAILABLE", e.message, null)
                        }
                    }
                    "modelInfo" -> result.success(currentModelInfo())
                    "modelPath" -> {
                        val model = File(File(filesDir, "models"), "model.gguf")
                        result.success(if (model.isFile && isGguf(model)) model.absolutePath else null)
                    }
                    "deviceProfile" -> result.success(deviceProfile())
                    "removeModel" -> {
                        val dir = File(filesDir, "models")
                        result.success(!dir.exists() || dir.deleteRecursively())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Android API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickModelRequest) return
        val callback = pendingResult ?: return
        pendingResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            callback.success(null)
            return
        }
        try {
            callback.success(importSelectedModel(data.data!!))
        } catch (e: Exception) {
            callback.error("MODEL_IMPORT_FAILED", e.message ?: "Could not import selected model.", null)
        }
    }

    // GGUF files begin with the ASCII magic "GGUF" followed by a little-endian
    // version. This validates the container header, not model architecture.
    private fun isGguf(file: File): Boolean {
        if (!file.isFile || file.length() < 24L) return false
        RandomAccessFile(file, "r").use { input ->
            val magic = ByteArray(4)
            input.readFully(magic)
            val version = Integer.reverseBytes(input.readInt())
            return magic.contentEquals(byteArrayOf(0x47, 0x47, 0x55, 0x46)) && version in 2..3
        }
    }

    private fun importSelectedModel(uri: Uri): Map<String, Any> {
        val dir = File(filesDir, "models")
        if (!dir.exists() && !dir.mkdirs()) error("Cannot create private model directory.")
        val temp = File(dir, "model.gguf.partial")
        val target = File(dir, "model.gguf")
        val backup = File(dir, "model.gguf.previous")
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        val maxBytes = 8L * 1024L * 1024L * 1024L
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                temp.outputStream().buffered().use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= maxBytes) { "Model file exceeds the 8 GB import limit." }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            } ?: error("Selected file cannot be opened.")
            require(isGguf(temp)) { "Selected file is not a supported GGUF v2/v3 model." }
            if (backup.exists()) backup.delete()
            if (target.exists()) require(target.renameTo(backup)) { "Could not preserve the previous model." }
            if (!temp.renameTo(target)) {
                if (backup.exists()) backup.renameTo(target)
                error("Could not finalize imported model.")
            }
            backup.delete()
            return mapOf(
                "fileName" to (uri.lastPathSegment ?: "model.gguf"),
                "storedName" to target.name,
                "sizeBytes" to total,
                "sha256" to digest.digest().joinToString("") { "%02x".format(it) },
                "validated" to false,
                "message" to "GGUF header validated; runtime architecture and device compatibility are checked when loaded."
            )
        } catch (e: Exception) {
            temp.delete()
            if (!target.exists() && backup.exists()) backup.renameTo(target)
            throw e
        }
    }

    private fun deviceProfile(): Map<String, Any> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memory)
        val ramGb = memory.totalMem / (1024.0 * 1024.0 * 1024.0)
        val tier = when {
            ramGb >= 8.0 -> "high"
            ramGb >= 6.0 -> "standard"
            ramGb >= 4.0 -> "compact"
            else -> "minimum"
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "is64Bit" to (Build.VERSION.SDK_INT >= 23 && android.os.Process.is64Bit()),
            "cpuCores" to Runtime.getRuntime().availableProcessors(),
            "totalRamBytes" to memory.totalMem,
            "availableRamBytes" to memory.availMem,
            "lowMemory" to memory.lowMemory,
            "deviceTier" to tier,
            "modelRuntimeReady" to false
        )
    }

    private fun currentModelInfo(): Map<String, Any>? {
        val model = File(File(filesDir, "models"), "model.gguf")
        if (!model.exists()) return null
        val valid = isGguf(model)
        return mapOf("storedName" to model.name, "sizeBytes" to model.length(),
            "validated" to valid, "message" to if (valid)
                "GGUF header valid; runtime compatibility is checked when loaded."
            else "Imported file is invalid or incomplete.")
    }
}
