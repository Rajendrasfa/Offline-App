package com.example.askme

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
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
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingSpeechLanguage: String = "hi-IN"
    private val audioPermissionRequest = 7413

    private var backendLoadAttempted = false
    private var backendLoadError: String? = null

    private external fun nativeBackendApiVersion(): Int
    private external fun nativeBackendInitialize(): Int
    private external fun nativeBackendStartRequest(): Long
    private external fun nativeBackendCancelRequest(requestId: Long): Boolean
    private external fun nativeBackendCompleteRequest(requestId: Long): Boolean

    private fun backendRuntimeInfo(): Map<String, Any> {
        if (!backendLoadAttempted) {
            backendLoadAttempted = true
            try {
                System.loadLibrary("askme_android_host")
                System.loadLibrary("askme_jni_bridge")
            } catch (error: UnsatisfiedLinkError) {
                backendLoadError = error.message ?: "Native backend library could not be loaded."
            }
        }
        if (backendLoadError != null) {
            return mapOf("available" to false, "apiVersion" to 0, "error" to backendLoadError!!)
        }
        return try {
            val version = nativeBackendApiVersion()
            val initialized = nativeBackendInitialize() == 0
            mapOf("available" to initialized, "apiVersion" to version, "error" to "")
        } catch (error: UnsatisfiedLinkError) {
            mapOf("available" to false, "apiVersion" to 0, "error" to (error.message ?: "JNI entry point unavailable."))
        }
    }

    override fun onDestroy() {
        pendingSpeechResult?.error("ACTIVITY_DESTROYED", "Speech activity was closed.", null)
        pendingSpeechResult = null
        speechRecognizer?.destroy()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "backendRuntimeInfo" -> result.success(backendRuntimeInfo())
                    "backendStartRequest" -> {
                        val info = backendRuntimeInfo()
                        result.success(if (info["available"] == true) runCatching { nativeBackendStartRequest() }.getOrDefault(0L) else 0L)
                    }
                    "backendCancelRequest" -> {
                        val info = backendRuntimeInfo()
                        result.success(if (info["available"] == true) runCatching { nativeBackendCancelRequest(call.argument<Number>("requestId")?.toLong() ?: 0L) }.getOrDefault(false) else false)
                    }
                    "backendCompleteRequest" -> {
                        val info = backendRuntimeInfo()
                        result.success(if (info["available"] == true) runCatching { nativeBackendCompleteRequest(call.argument<Number>("requestId")?.toLong() ?: 0L) }.getOrDefault(false) else false)
                    }
                    "startOfflineSpeech" -> startOfflineSpeech(call.argument<String>("language") ?: "hi-IN", result)
                    "stopOfflineSpeech" -> {
                        speechRecognizer?.cancel()
                        speechRecognizer?.destroy()
                        speechRecognizer = null
                        pendingSpeechResult?.error("SPEECH_CANCELLED", "Speech input was cancelled.", null)
                        pendingSpeechResult = null
                        result.success(true)
                    }
                    "speakOffline" -> speakOffline(
                        call.argument<String>("text") ?: "",
                        call.argument<String>("language") ?: "hi-IN",
                        result
                    )
                    "stopSpeaking" -> {
                        textToSpeech?.stop()
                        result.success(true)
                    }
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


    private fun startOfflineSpeech(language: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.error("ON_DEVICE_SPEECH_UNAVAILABLE", "On-device speech recognition requires Android 12 or later.", null)
            return
        }
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
            result.error("ON_DEVICE_SPEECH_UNAVAILABLE", "No installed on-device speech recognition service is available.", null)
            return
        }
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            pendingSpeechResult = result
            pendingSpeechLanguage = language
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), audioPermissionRequest)
            return
        }
        beginOnDeviceRecognition(language, result)
    }

    private fun beginOnDeviceRecognition(language: String, result: MethodChannel.Result) {
        try {
            speechRecognizer?.destroy()
            val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            speechRecognizer = recognizer
            pendingSpeechResult = result
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) {
                    pendingSpeechResult?.error("SPEECH_RECOGNITION_FAILED", "On-device recognizer error: $error", null)
                    pendingSpeechResult = null
                    recognizer.destroy()
                    speechRecognizer = null
                }
                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                    pendingSpeechResult?.success(text)
                    pendingSpeechResult = null
                    recognizer.destroy()
                    speechRecognizer = null
                }
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }
            recognizer.startListening(intent)
        } catch (e: Exception) {
            pendingSpeechResult = null
            speechRecognizer?.destroy()
            speechRecognizer = null
            result.error("SPEECH_START_FAILED", e.message, null)
        }
    }

    private fun speakOffline(text: String, language: String, result: MethodChannel.Result) {
        if (text.isBlank()) {
            result.error("EMPTY_SPEECH_TEXT", "Text to speak is empty.", null)
            return
        }
        val locale = Locale.forLanguageTag(language)
        if (textToSpeech == null) {
            textToSpeech = TextToSpeech(this) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                if (!ttsReady) {
                    result.error("TTS_INIT_FAILED", "Android text-to-speech could not initialize.", null)
                } else {
                    speakWithOfflineVoice(text, locale, result)
                }
            }
        } else if (ttsReady) {
            speakWithOfflineVoice(text, locale, result)
        } else {
            result.error("TTS_NOT_READY", "Text-to-speech is still initializing. Try again.", null)
        }
    }

    private fun speakWithOfflineVoice(text: String, locale: Locale, result: MethodChannel.Result) {
        val engine = textToSpeech ?: run {
            result.error("TTS_NOT_READY", "Text-to-speech is unavailable.", null)
            return
        }
        val voice = engine.voices?.firstOrNull {
            it.locale.language == locale.language && !it.isNetworkConnectionRequired
        }
        if (voice == null) {
            result.error("OFFLINE_VOICE_UNAVAILABLE", "No offline voice is installed for ${locale.toLanguageTag()}.", null)
            return
        }
        engine.voice = voice
        val languageResult = engine.setLanguage(locale)
        if (languageResult == TextToSpeech.LANG_MISSING_DATA || languageResult == TextToSpeech.LANG_NOT_SUPPORTED) {
            result.error("OFFLINE_VOICE_UNAVAILABLE", "The requested offline language voice is not supported.", null)
            return
        }
        val utteranceId = "askme-${System.currentTimeMillis()}"
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) {
                if (id == utteranceId) runOnUiThread { result.success(true) }
            }
            @Deprecated("Deprecated in Android API")
            override fun onError(id: String?) {
                if (id == utteranceId) runOnUiThread { result.error("TTS_FAILED", "Offline speech playback failed.", null) }
            }
        })
        if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId) == TextToSpeech.ERROR) {
            result.error("TTS_FAILED", "Could not start offline speech.", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != audioPermissionRequest) return
        val callback = pendingSpeechResult ?: return
        pendingSpeechResult = null
        if (grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            beginOnDeviceRecognition(pendingSpeechLanguage, callback)
        } else {
            callback.error("MIC_PERMISSION_DENIED", "Microphone permission was not granted.", null)
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
