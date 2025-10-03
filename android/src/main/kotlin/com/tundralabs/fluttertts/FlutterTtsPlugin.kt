package com.tundralabs.fluttertts

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.*
import io.flutter.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.lang.reflect.Field
import java.text.SimpleDateFormat
import java.util.*

data class TtsAvailabilityResult(val success: Boolean, val message: String? = null)

/** FlutterTtsPlugin  */
class FlutterTtsPlugin : MethodCallHandler, FlutterPlugin {
    private var handler: Handler? = null
    private var methodChannel: MethodChannel? = null
    private var speakResult: Result? = null
    private var synthResult: Result? = null
    private var awaitSpeakCompletion = false
    private var speaking = false
    private var awaitSynthCompletion = false
    private var synth = false
    private var context: Context? = null
    private var tts: TextToSpeech? = null
    private val tag = "TTS"
    private val googleTtsEngine = "com.google.android.tts"
    private var isTtsInitialized = false
    private val pendingMethodCalls = ArrayList<Runnable>()
    private val utterances = HashMap<String, String>()
    private var bundle: Bundle? = null
    private var silencems = 0
    private var lastProgress = 0
    private var currentText: String? = null
    private var pauseText: String? = null
    private var isPaused: Boolean = false
    private var queueMode: Int = TextToSpeech.QUEUE_FLUSH

    // Buffer diagnostic messages until method channel is ready
    private val bufferedDiagnostics = ArrayList<Map<String, Any?>>()
    private var isMethodChannelReady = false

    companion object {
        private const val SILENCE_PREFIX = "SIL_"
        private const val SYNTHESIZE_TO_FILE_PREFIX = "STF_"
    }

    private fun initInstance(messenger: BinaryMessenger, context: Context) {
        this.context = context
        methodChannel = MethodChannel(messenger, "flutter_tts")
        methodChannel!!.setMethodCallHandler(this)
        handler = Handler(Looper.getMainLooper())
        bundle = Bundle()

        // Don't mark as ready yet - wait for first method call from Flutter
        // This ensures Flutter's method call handler is set up
        Log.d(tag, "Android method channel created, waiting for first Flutter method call to confirm Flutter is ready")

        tts = TextToSpeech(context, firstTimeOnInitListener, googleTtsEngine)
    }

    /** Android Plugin APIs  */
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        initInstance(binding.binaryMessenger, binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        tts!!.shutdown()
        context = null
        methodChannel!!.setMethodCallHandler(null)
        methodChannel = null
    }

    private val utteranceProgressListener: UtteranceProgressListener =
        object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) {
                if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
                    invokeMethod("synth.onStart", true)
                } else {
                    if (isPaused) {
                        invokeMethod("speak.onContinue", true)
                        isPaused = false
                    } else {
                        logDiagnostic("INFO", "Utterance started", mapOf("utteranceId" to utteranceId))
                        invokeMethod("speak.onStart", true)
                    }
                }
                if (Build.VERSION.SDK_INT < 26) {
                    onProgress(utteranceId, 0, utterances[utteranceId]!!.length)
                }
            }

            override fun onDone(utteranceId: String) {
                if (utteranceId.startsWith(SILENCE_PREFIX)) return
                if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
                    logDiagnostic("INFO", "Utterance completed (synth)", mapOf("utteranceId" to utteranceId))
                    if (awaitSynthCompletion) {
                        synthCompletion(1)
                    }
                    invokeMethod("synth.onComplete", true)
                } else {
                    logDiagnostic("INFO", "Utterance completed", mapOf("utteranceId" to utteranceId))
                    if (awaitSpeakCompletion && queueMode == TextToSpeech.QUEUE_FLUSH) {
                        speakCompletion(1)
                    }
                    invokeMethod("speak.onComplete", true)
                }
                lastProgress = 0
                pauseText = null
                utterances.remove(utteranceId)
            }

            override fun onStop(utteranceId: String, interrupted: Boolean) {
                logDiagnostic("INFO", "Utterance stopped", mapOf(
                    "utteranceId" to utteranceId,
                    "interrupted" to interrupted
                ))
                if (awaitSpeakCompletion) {
                    speaking = false
                }
                if (isPaused) {
                    invokeMethod("speak.onPause", true)
                } else {
                    invokeMethod("speak.onCancel", true)
                }
            }

            private fun onProgress(utteranceId: String?, startAt: Int, endAt: Int) {
                if (utteranceId != null && !utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
                    val text = utterances[utteranceId]
                    val data = HashMap<String, String?>()
                    data["text"] = text
                    data["start"] = startAt.toString()
                    data["end"] = endAt.toString()
                    data["word"] = text!!.substring(startAt, endAt)
                    invokeMethod("speak.onProgress", data)
                }
            }

            // Requires Android 26 or later
            override fun onRangeStart(utteranceId: String, startAt: Int, endAt: Int, frame: Int) {
                if (!utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
                    lastProgress = startAt
                    super.onRangeStart(utteranceId, startAt, endAt, frame)
                    onProgress(utteranceId, startAt, endAt)
                }
            }

            @Deprecated("")
            override fun onError(utteranceId: String) {
                if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
                    if (awaitSynthCompletion) {
                        synth = false
                    }
                    invokeMethod("synth.onError", "Error from TextToSpeech (synth)")
                } else {
                    if (awaitSpeakCompletion) {
                        speaking = false
                    }
                    invokeMethod("speak.onError", "Error from TextToSpeech (speak)")
                }
            }

            override fun onError(utteranceId: String, errorCode: Int) {
                if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
                    if (awaitSynthCompletion) {
                        synth = false
                    }
                    invokeMethod("synth.onError", "Error from TextToSpeech (synth) - $errorCode")
                } else {
                    if (awaitSpeakCompletion) {
                        speaking = false
                    }
                    invokeMethod("speak.onError", "Error from TextToSpeech (speak) - $errorCode")
                }
            }
        }

    fun speakCompletion(success: Int) {
        speaking = false
        handler!!.post {
            speakResult?.success(success)
            speakResult = null
        }
    }

    fun synthCompletion(success: Int) {
        synth = false
        handler!!.post { synthResult?.success(success) }
    }

    private fun logDiagnostic(level: String, message: String, data: Map<String, Any?>? = null) {
        // Format timestamp as ISO string to match Dart logger format
        val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSSSS", Locale.US)
        dateFormat.timeZone = TimeZone.getDefault()
        val timestamp = dateFormat.format(Date())

        // Log to logcat with data for debugging
        val logMessage = if (data != null) {
            "$message | Data: $data"
        } else {
            message
        }
        when (level) {
            "ERROR" -> Log.e(tag, logMessage)
            "WARN" -> Log.w(tag, logMessage)
            else -> Log.d(tag, logMessage)
        }

        // Send to Dart for Firestore logging
        val diagnosticData = mutableMapOf<String, Any?>(
            "level" to level,
            "message" to message,
            "timestamp" to timestamp
        )
        if (data != null) {
            diagnosticData["data"] = data
        }

        // Buffer if method channel not ready, otherwise send immediately
        synchronized(bufferedDiagnostics) {
            if (!isMethodChannelReady) {
                bufferedDiagnostics.add(diagnosticData)
                Log.d(tag, "Buffered diagnostic (channel not ready): $message [total buffered: ${bufferedDiagnostics.size}]")
            } else {
                invokeMethod("tts.diagnostic", diagnosticData)
            }
        }
    }

    private fun checkTtsAvailability(): TtsAvailabilityResult {
        logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Starting comprehensive TTS availability check")

        // Check 1: TTS Instance and Initialization
        if (tts == null || !isTtsInitialized) {
            return TtsAvailabilityResult(false, "TTS is not initialized.")
        }

        // Check 2: Available Engines
        try {
            val engines = tts!!.engines
            logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Available engines: ${engines.map { it.name }}",
                mapOf("engines" to engines.map { it.name }))
            if (engines.isNullOrEmpty()) {
                return TtsAvailabilityResult(false, "No TTS engines available on device.")
            }

            val defaultEngine = tts!!.defaultEngine
            logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Default engine: $defaultEngine",
                mapOf("defaultEngine" to defaultEngine))
            if (defaultEngine.isNullOrEmpty()) {
                return TtsAvailabilityResult(false, "No default TTS engine configured.")
            }

            // Check if the default engine is actually available
            val engineAvailable = engines.any { it.name == defaultEngine }
            if (!engineAvailable) {
                return TtsAvailabilityResult(false, "Default TTS engine '$defaultEngine' is not available. Available engines: ${engines.map { it.name }}")
            }
        } catch (e: Exception) {
            logDiagnostic("ERROR", "🔍 TTS DIAGNOSTIC: Error checking engines: ${e.message}",
                mapOf("error" to e.message))
            return TtsAvailabilityResult(false, "Error accessing TTS engines: ${e.message}")
        }

        // Check 3: Voice Data Availability
        try {
            val voices = tts!!.voices
            logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Total voices available: ${voices?.size ?: 0}",
                mapOf("voiceCount" to (voices?.size ?: 0)))
            if (voices.isNullOrEmpty()) {
                return TtsAvailabilityResult(false, "No TTS voices available. Voice data may be missing or corrupted.")
            }

            // Check for basic English voice
            val englishVoices = voices.filter { it.locale.language.lowercase() == "en" }
            logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: English voices: ${englishVoices.size}",
                mapOf("englishVoiceCount" to englishVoices.size))
            if (englishVoices.isEmpty()) {
                return TtsAvailabilityResult(false, "No English voices available. TTS voice data may be incomplete.")
            }
        } catch (e: Exception) {
            logDiagnostic("ERROR", "🔍 TTS DIAGNOSTIC: Error checking voices: ${e.message}",
                mapOf("error" to e.message))
            return TtsAvailabilityResult(false, "Error accessing TTS voices: ${e.message}")
        }

        // Check 4: Language Support
        val isLanguageAvailable = tts?.isLanguageAvailable(Locale.US) ?: TextToSpeech.LANG_NOT_SUPPORTED
        logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: US English availability: $isLanguageAvailable",
            mapOf("languageAvailability" to isLanguageAvailable))

        when (isLanguageAvailable) {
            TextToSpeech.LANG_MISSING_DATA -> {
                return TtsAvailabilityResult(false, "TTS language data is missing. Voice data needs to be downloaded.")
            }
            TextToSpeech.LANG_NOT_SUPPORTED -> {
                return TtsAvailabilityResult(false, "US English is not supported by the TTS engine.")
            }
            TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE,
            TextToSpeech.LANG_COUNTRY_AVAILABLE,
            TextToSpeech.LANG_AVAILABLE -> {
                logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Language availability check passed")
            }
            else -> {
                return TtsAvailabilityResult(false, "Unknown language availability status: $isLanguageAvailable")
            }
        }

        // Check 5: Test Speech Synthesis
        try {
            logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Testing speech synthesis capability")
            // Don't actually speak, just test if the method would succeed
            val testResult = tts!!.speak("", TextToSpeech.QUEUE_FLUSH, Bundle(), "diagnostic_test")
            logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: Test synthesis result: $testResult",
                mapOf("testResult" to testResult))

            if (testResult != TextToSpeech.SUCCESS) {
                val errorMsg = when (testResult) {
                    TextToSpeech.ERROR -> "TTS engine reported an error"
                    TextToSpeech.ERROR_SERVICE -> "TTS service is not available"
                    TextToSpeech.ERROR_INVALID_REQUEST -> "Invalid TTS request"
                    TextToSpeech.ERROR_NETWORK -> "TTS network error"
                    TextToSpeech.ERROR_NOT_INSTALLED_YET -> "TTS engine not fully installed"
                    TextToSpeech.ERROR_OUTPUT -> "TTS audio output error"
                    TextToSpeech.ERROR_SYNTHESIS -> "TTS synthesis error"
                    else -> "Unknown TTS error (code: $testResult)"
                }
                return TtsAvailabilityResult(false, "TTS synthesis test failed: $errorMsg")
            }
        } catch (e: Exception) {
            logDiagnostic("ERROR", "🔍 TTS DIAGNOSTIC: Speech synthesis test failed: ${e.message}",
                mapOf("error" to e.message))
            return TtsAvailabilityResult(false, "Speech synthesis test failed: ${e.message}")
        }

        logDiagnostic("INFO", "🔍 TTS DIAGNOSTIC: All checks passed - TTS should be functional")
        return TtsAvailabilityResult(true, "TTS is fully functional")
    }

    private val onInitListener: TextToSpeech.OnInitListener =
        TextToSpeech.OnInitListener { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts!!.setOnUtteranceProgressListener(utteranceProgressListener)
                try {
                    val locale: Locale = tts!!.defaultVoice.locale
                    if (isLanguageAvailable(locale)) {
                        tts!!.language = locale
                    }
                } catch (e: NullPointerException) {
                    logDiagnostic("ERROR", "getDefaultLocale failed: NullPointerException", mapOf("error" to e.message))
                } catch (e: IllegalArgumentException) {
                    logDiagnostic("ERROR", "getDefaultLocale failed: IllegalArgumentException", mapOf("error" to e.message))
                }

                // Handle pending method calls (sent while TTS was initializing)
                synchronized(pendingMethodCalls) {
                    isTtsInitialized = true
                    logDiagnostic("DEBUG", "Processing pending method calls", mapOf("count" to pendingMethodCalls.size))
                    for (call in pendingMethodCalls) {
                        call.run()
                    }
                    pendingMethodCalls.clear()
                    logDiagnostic("DEBUG", "All pending method calls processed")
                }
                invokeMethod("tts.init", isTtsInitialized)
            } else {
                logDiagnostic("ERROR", "Failed to initialize TextToSpeech", mapOf("status" to status))
                invokeMethod("tts.init", isTtsInitialized)
            }
        }

    private val firstTimeOnInitListener: TextToSpeech.OnInitListener =
        TextToSpeech.OnInitListener { status ->
            logDiagnostic("INFO", "🚀 TTS INITIALIZATION STARTED", mapOf(
                "status" to status,
                "androidVersion" to Build.VERSION.SDK_INT,
                "androidRelease" to Build.VERSION.RELEASE
            ))

            if (status == TextToSpeech.SUCCESS) {
                logDiagnostic("INFO", "✅ TTS initialization successful")

                // Log all available engines
                try {
                    val engines = tts!!.engines
                    val engineNames = engines.map { it.name }
                    logDiagnostic("INFO", "📦 Available TTS engines", mapOf(
                        "count" to engines.size,
                        "engines" to engineNames
                    ))
                } catch (e: Exception) {
                    logDiagnostic("ERROR", "Failed to get engines list", mapOf("error" to e.message))
                }

                // Log default engine
                try {
                    val defaultEngine = tts!!.defaultEngine
                    logDiagnostic("INFO", "🎯 Default TTS engine", mapOf("engine" to defaultEngine))
                } catch (e: Exception) {
                    logDiagnostic("ERROR", "Failed to get default engine", mapOf("error" to e.message))
                }

                // Log default voice
                try {
                    val defaultVoice = tts!!.defaultVoice
                    if (defaultVoice != null) {
                        logDiagnostic("INFO", "🎤 Default voice", mapOf(
                            "name" to defaultVoice.name,
                            "locale" to defaultVoice.locale.toLanguageTag(),
                            "quality" to defaultVoice.quality,
                            "requiresNetwork" to defaultVoice.isNetworkConnectionRequired
                        ))
                    } else {
                        logDiagnostic("WARN", "No default voice available")
                    }
                } catch (e: Exception) {
                    logDiagnostic("ERROR", "Failed to get default voice", mapOf("error" to e.message))
                }

                // Log all available voices
                try {
                    val voices = tts!!.voices
                    if (voices != null) {
                        logDiagnostic("INFO", "🎵 Available voices count", mapOf("count" to voices.size))

                        // Group voices by language
                        val voicesByLanguage = voices.groupBy { it.locale.language }
                        val languageCounts = voicesByLanguage.mapValues { it.value.size }
                        logDiagnostic("INFO", "🌍 Voices by language", mapOf("languages" to languageCounts))

                        // Log first few voices as examples
                        val sampleVoices = voices.take(10).map { voice ->
                            mapOf(
                                "name" to voice.name,
                                "locale" to voice.locale.toLanguageTag(),
                                "quality" to voice.quality
                            )
                        }
                        logDiagnostic("INFO", "🎵 Sample voices", mapOf("voices" to sampleVoices))
                    } else {
                        logDiagnostic("ERROR", "No voices available from TTS engine")
                    }
                } catch (e: Exception) {
                    logDiagnostic("ERROR", "Failed to get voices list", mapOf("error" to e.message))
                }

                // Log available languages
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val availableLanguages = tts!!.availableLanguages
                        if (availableLanguages != null) {
                            val languageTags = availableLanguages.map { it.toLanguageTag() }
                            logDiagnostic("INFO", "🗣️ Available languages", mapOf(
                                "count" to availableLanguages.size,
                                "languages" to languageTags.take(20)
                            ))
                        }
                    } else {
                        logDiagnostic("INFO", "Language enumeration not available on Android < 23")
                    }
                } catch (e: Exception) {
                    logDiagnostic("ERROR", "Failed to get available languages", mapOf("error" to e.message))
                }

                tts!!.setOnUtteranceProgressListener(utteranceProgressListener)

                // Set up default locale
                try {
                    val locale: Locale = tts!!.defaultVoice.locale
                    logDiagnostic("INFO", "Setting default locale", mapOf("locale" to locale.toLanguageTag()))
                    if (isLanguageAvailable(locale)) {
                        tts!!.language = locale
                        logDiagnostic("INFO", "Default locale set successfully", mapOf("locale" to locale.toLanguageTag()))
                    } else {
                        logDiagnostic("WARN", "Default locale not available", mapOf("locale" to locale.toLanguageTag()))
                    }
                } catch (e: NullPointerException) {
                    logDiagnostic("ERROR", "Failed to get default locale", mapOf("error" to e.message))
                    invokeMethod("tts.error", mapOf(
                        "type" to "initialization_error",
                        "message" to "Failed to get default locale: ${e.message}",
                        "code" to "NULL_POINTER_EXCEPTION"
                    ))
                } catch (e: IllegalArgumentException) {
                    logDiagnostic("ERROR", "Invalid default locale", mapOf("error" to e.message))
                    invokeMethod("tts.error", mapOf(
                        "type" to "initialization_error",
                        "message" to "Invalid default locale: ${e.message}",
                        "code" to "ILLEGAL_ARGUMENT_EXCEPTION"
                    ))
                }

                // Handle pending method calls (sent while TTS was initializing)
                synchronized(this@FlutterTtsPlugin) {
                    isTtsInitialized = true
                    logDiagnostic("INFO", "Processing pending method calls", mapOf("count" to pendingMethodCalls.size))
                    for (call in pendingMethodCalls) {
                        call.run()
                    }
                    pendingMethodCalls.clear()
                    logDiagnostic("INFO", "✅ TTS INITIALIZATION COMPLETE")
                }
                invokeMethod("tts.init", isTtsInitialized)
            } else {
                val errorMessage = when (status) {
                    TextToSpeech.ERROR -> "TTS engine reported an error during initialization"
                    TextToSpeech.ERROR_INVALID_REQUEST -> "Invalid request during TTS initialization"
                    TextToSpeech.ERROR_NETWORK -> "Network error during TTS initialization"
                    TextToSpeech.ERROR_NETWORK_TIMEOUT -> "Network timeout during TTS initialization"
                    TextToSpeech.ERROR_NOT_INSTALLED_YET -> "TTS engine not installed yet"
                    TextToSpeech.ERROR_OUTPUT -> "Audio output error during TTS initialization"
                    TextToSpeech.ERROR_SERVICE -> "TTS service error during initialization"
                    TextToSpeech.ERROR_SYNTHESIS -> "Speech synthesis error during initialization"
                    else -> "Unknown TTS initialization error (status: $status)"
                }
                logDiagnostic("ERROR", "❌ TTS initialization failed", mapOf(
                    "status" to status,
                    "error" to errorMessage,
                    "androidVersion" to Build.VERSION.SDK_INT
                ))
                invokeMethod("tts.error", mapOf(
                    "type" to "initialization_failure",
                    "message" to errorMessage,
                    "code" to "TTS_INIT_STATUS_$status"
                ))
                invokeMethod("tts.init", false)
            }
        }

    override fun onMethodCall(call: MethodCall, result: Result) {
        // Mark channel as ready on first method call
        if (!isMethodChannelReady) {
            isMethodChannelReady = true
            Log.d(tag, "Method channel confirmed ready via first method call (${call.method})")
        }

        // If TTS is still loading, handle non-blocking
        if (!isTtsInitialized) {
            when (call.method) {
                "speak", "pause", "stop", "setVoice", "setSpeechRate", "setVolume", "setPitch" -> {
                    // For critical methods, queue them safely without blocking
                    synchronized(pendingMethodCalls) {
                        val suspendedCall = Runnable { onMethodCall(call, result) }
                        pendingMethodCalls.add(suspendedCall)
                        logDiagnostic("WARN", "TTS not ready, queuing method", mapOf(
                            "method" to call.method,
                            "queueSize" to pendingMethodCalls.size
                        ))
                    }
                    return
                }
                "checkTTSAvailability" -> {
                    // Return false immediately if not initialized
                    result.success(false)
                    return
                }
                else -> {
                    // For other methods, return appropriate default values
                    result.success(0)
                    return
                }
            }
        }
        logDiagnostic("DEBUG", "Processing method call", mapOf("method" to call.method))
        when (call.method) {
            "speak" -> {
                var text: String = call.argument("text")!!
                var language: String = call.argument("language")!!
                logDiagnostic("DEBUG", "Speak method called", mapOf(
                    "textPreview" to text.take(50),
                    "language" to language,
                    "textLength" to text.length
                ))

                if (pauseText == null) {
                    pauseText = text
                    currentText = pauseText!!
                }

                if (isPaused) {
                    // Ensure the text hasn't changed
                    if (currentText == text) {
                        text = pauseText!!
                    } else {
                        pauseText = text
                        currentText = pauseText!!
                        lastProgress = 0
                    }
                }

                if (speaking) {
                    // If TTS is set to queue mode, allow the utterance to be queued up rather than discarded
                    if (queueMode == TextToSpeech.QUEUE_FLUSH) {
                        result.success(0)
                        return
                    }
                }

                val speechSuccess = speak(text, language)

                if (!speechSuccess) {
                    synchronized(this@FlutterTtsPlugin) {
                        val suspendedCall = Runnable { onMethodCall(call, result) }
                        pendingMethodCalls.add(suspendedCall)
                    }
                    return
                }
                // Only use await speak completion if queueMode is set to QUEUE_FLUSH
                if (awaitSpeakCompletion && queueMode == TextToSpeech.QUEUE_FLUSH) {
                    speaking = true
                    speakResult = result
                } else {
                    result.success(1)
                }
            }

            "checkTTSAvailability" -> {
                val availability = checkTtsAvailability()
                if (availability.success) {
                    result.success(true)
                } else {
                    // Use FlutterError to communicate back to Flutter with the error message
                    result.error("UNAVAILABLE", availability.message, null)
                }
            }

            "awaitSpeakCompletion" -> {
                awaitSpeakCompletion = java.lang.Boolean.parseBoolean(call.arguments.toString())
                result.success(1)
            }

            "awaitSynthCompletion" -> {
                awaitSynthCompletion = java.lang.Boolean.parseBoolean(call.arguments.toString())
                result.success(1)
            }

            "getMaxSpeechInputLength" -> {
                val res = maxSpeechInputLength
                result.success(res)
            }

            "synthesizeToFile" -> {
                val text: String? = call.argument("text")
                if (synth) {
                    result.success(0)
                    return
                }
                val fileName: String? = call.argument("fileName")
                synthesizeToFile(text!!, fileName!!)
                if (awaitSynthCompletion) {
                    synth = true
                    synthResult = result
                } else {
                    result.success(1)
                }
            }

            "pause" -> {
                isPaused = true
                if (pauseText != null) {
                    pauseText = pauseText!!.substring(lastProgress)
                }
                stop()
                result.success(1)
                if (speakResult != null) {
                    speakResult!!.success(0)
                    speakResult = null
                }
            }

            "stop" -> {
                isPaused = false
                pauseText = null
                stop()
                lastProgress = 0
                result.success(1)
                if (speakResult != null) {
                    speakResult!!.success(0)
                    speakResult = null
                }
            }

            "setEngine" -> {
                val engine: String = call.arguments.toString()
                setEngine(engine, result)
            }

            "tryFallbackEngines" -> {
                tryFallbackEngines(result)
            }

            "setSpeechRate" -> {
                val rate: String = call.arguments.toString()
                // To make the FlutterTts API consistent across platforms,
                // Android 1.0 is mapped to flutter 0.5.
                setSpeechRate(rate.toFloat() * 2.0f)
                result.success(1)
            }

            "setVolume" -> {
                val volume: String = call.arguments.toString()
                setVolume(volume.toFloat(), result)
            }

            "setPitch" -> {
                val pitch: String = call.arguments.toString()
                setPitch(pitch.toFloat(), result)
            }

            "setLanguage" -> {
                val language: String = call.arguments.toString()
                setLanguage(language, result)
            }

            "getLanguages" -> getLanguages(result)
            "getVoices" -> getVoices(result)
            "getVoicesForLanguage" -> {
                val language: String = call.arguments.toString()
                getVoicesForLanguage(language, result)
            }
            "getSpeechRateValidRange" -> getSpeechRateValidRange(result)
            "getEngines" -> getEngines(result)
            "getDefaultEngine" -> getDefaultEngine(result)
            "getDefaultVoice" -> getDefaultVoice(result)
            "setVoice" -> {
                val voice: HashMap<String?, String>? = call.arguments()
                setVoice(voice!!, result)
            }

            "isLanguageAvailable" -> {
                val language: String = call.arguments.toString()
                val locale: Locale = Locale.forLanguageTag(language)
                result.success(isLanguageAvailable(locale))
            }

            "setSilence" -> {
                val silencems: String = call.arguments.toString()
                this.silencems = silencems.toInt()
            }

            "setSharedInstance" -> result.success(1)
            "isLanguageInstalled" -> {
                val language: String = call.arguments.toString()
                result.success(isLanguageInstalled(language))
            }

            "areLanguagesInstalled" -> {
                val languages: List<String?>? = call.arguments()
                result.success(areLanguagesInstalled(languages!!))
            }

            "setQueueMode" -> {
                val queueMode: String = call.arguments.toString()
                this.queueMode = queueMode.toInt()
                result.success(1)
            }

            "getBufferedDiagnostics" -> {
                synchronized(bufferedDiagnostics) {
                    val diagnostics = ArrayList(bufferedDiagnostics)
                    bufferedDiagnostics.clear()
                    Log.d(tag, "Returning ${diagnostics.size} buffered diagnostics to Flutter")
                    result.success(diagnostics)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun setSpeechRate(rate: Float) {
        tts!!.setSpeechRate(rate)
    }

    private fun isLanguageAvailable(locale: Locale?): Boolean {
        return tts!!.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE
    }

    private fun areLanguagesInstalled(languages: List<String?>): Map<String?, Boolean> {
        val result: MutableMap<String?, Boolean> = HashMap()
        for (language in languages) {
            result[language] = isLanguageInstalled(language)
        }
        return result
    }

    private fun isLanguageInstalled(language: String?): Boolean {
        val locale: Locale = Locale.forLanguageTag(language!!)
        if (isLanguageAvailable(locale)) {
            var voiceToCheck: Voice? = null
            for (v in tts!!.voices) {
                if (v.locale == locale && !v.isNetworkConnectionRequired) {
                    voiceToCheck = v
                    break
                }
            }
            if (voiceToCheck != null) {
                val features: Set<String> = voiceToCheck.features
                return (!features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED))
            }
        }
        return false
    }

    private fun setEngine(engine: String?, result: Result) {
        tts = TextToSpeech(context, onInitListener, engine)
        isTtsInitialized = false
        result.success(1)
    }

    private fun setLanguage(language: String?, result: Result) {
        val locale: Locale = Locale.forLanguageTag(language!!)
        if (isLanguageAvailable(locale)) {
            tts!!.language = locale
            result.success(1)
        } else {
            result.success(0)
        }
    }

    private fun setVoice(voice: HashMap<String?, String>, result: Result) {
        try {
            val requestedName = voice["name"]
            val requestedLocale = voice["locale"]

            if (requestedName.isNullOrEmpty() || requestedLocale.isNullOrEmpty()) {
                Log.e(tag, "Invalid voice parameters: name=$requestedName, locale=$requestedLocale")
                invokeMethod("tts.error", mapOf(
                    "type" to "voice_setting_error",
                    "message" to "Invalid voice parameters provided",
                    "code" to "INVALID_VOICE_PARAMS",
                    "requested_voice" to voice.toString()
                ))
                result.success(0)
                return
            }

            val availableVoices = tts!!.voices
            if (availableVoices.isNullOrEmpty()) {
                Log.e(tag, "No voices available from TTS engine")
                invokeMethod("tts.error", mapOf(
                    "type" to "voice_setting_error",
                    "message" to "No voices available from TTS engine",
                    "code" to "NO_VOICES_AVAILABLE"
                ))
                result.success(0)
                return
            }

            for (ttsVoice in availableVoices) {
                if (ttsVoice.name == requestedName && ttsVoice.locale.toLanguageTag() == requestedLocale) {
                    try {
                        tts!!.voice = ttsVoice
                        Log.d(tag, "Successfully set voice: ${ttsVoice.name} (${ttsVoice.locale.toLanguageTag()})")
                        result.success(1)
                        return
                    } catch (e: Exception) {
                        Log.e(tag, "Failed to set voice ${ttsVoice.name}: ${e.message}")
                        invokeMethod("tts.error", mapOf(
                            "type" to "voice_setting_error",
                            "message" to "Failed to apply voice: ${e.message}",
                            "code" to "VOICE_APPLICATION_FAILED",
                            "requested_voice" to voice.toString()
                        ))
                        result.success(0)
                        return
                    }
                }
            }

            // Voice not found
            Log.w(tag, "Voice not found: $voice. Available voices: ${availableVoices.map { "${it.name} (${it.locale.toLanguageTag()})" }}")
            invokeMethod("tts.error", mapOf(
                "type" to "voice_setting_error",
                "message" to "Requested voice not found",
                "code" to "VOICE_NOT_FOUND",
                "requested_voice" to voice.toString(),
                "available_voices" to availableVoices.map { mapOf("name" to it.name, "locale" to it.locale.toLanguageTag()) }
            ))
            result.success(0)
        } catch (e: Exception) {
            Log.e(tag, "Exception in setVoice: ${e.message}", e)
            invokeMethod("tts.error", mapOf(
                "type" to "voice_setting_exception",
                "message" to "Exception while setting voice: ${e.message}",
                "code" to "VOICE_SETTING_EXCEPTION",
                "requested_voice" to voice.toString()
            ))
            result.success(0)
        }
    }

    private fun setVolume(volume: Float, result: Result) {
        if (volume in (0.0f..1.0f)) {
            bundle!!.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, volume)
            result.success(1)
        } else {
            Log.d(tag, "Invalid volume $volume value - Range is from 0.0 to 1.0")
            result.success(0)
        }
    }

    private fun setPitch(pitch: Float, result: Result) {
        if (pitch in (0.5f..2.0f)) {
            tts!!.setPitch(pitch)
            result.success(1)
        } else {
            Log.d(tag, "Invalid pitch $pitch value - Range is from 0.5 to 2.0")
            result.success(0)
        }
    }

    private fun getVoices(result: Result) {
        val voices = ArrayList<HashMap<String, String>>()
        try {
            for (voice in tts!!.voices) {
                val voiceMap = HashMap<String, String>()
                voiceMap["name"] = voice.name
                voiceMap["locale"] = voice.locale.toLanguageTag()
                voices.add(voiceMap)
            }
            result.success(voices)
        } catch (e: NullPointerException) {
            Log.d(tag, "getVoices: " + e.message)
            result.success(null)
        }
    }

    private fun getVoicesForLanguage(language: String, result: Result) {
        val voices = ArrayList<HashMap<String, String>>()
        try {
            val targetLocale = Locale.forLanguageTag(language)
            val languagePrefix = targetLocale.language.lowercase()
            
            for (voice in tts!!.voices) {
                val voiceLanguage = voice.locale.language.lowercase()
                if (voiceLanguage == languagePrefix) {
                    val voiceMap = HashMap<String, String>()
                    voiceMap["name"] = voice.name
                    voiceMap["locale"] = voice.locale.toLanguageTag()
                    // Add quality information if available
                    val quality = voice.quality
                    when (quality) {
                        Voice.QUALITY_VERY_HIGH -> voiceMap["quality"] = "Premium"
                        Voice.QUALITY_HIGH -> voiceMap["quality"] = "Enhanced"
                        Voice.QUALITY_NORMAL -> voiceMap["quality"] = "Default"
                        Voice.QUALITY_LOW -> voiceMap["quality"] = "Low"
                        Voice.QUALITY_VERY_LOW -> voiceMap["quality"] = "Very Low"
                        else -> voiceMap["quality"] = "Default"
                    }
                    voices.add(voiceMap)
                }
            }
            result.success(voices)
        } catch (e: Exception) {
            Log.d(tag, "getVoicesForLanguage: " + e.message)
            result.success(voices) // Return empty list on error
        }
    }

    private fun getLanguages(result: Result) {
        val locales = ArrayList<String>()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // While this method was introduced in API level 21, it seems that it
                // has not been implemented in the speech service side until API Level 23.
                for (locale in tts!!.availableLanguages) {
                    locales.add(locale.toLanguageTag())
                }
            } else {
                for (locale in Locale.getAvailableLocales()) {
                    if (locale.variant.isEmpty() && isLanguageAvailable(locale)) {
                        locales.add(locale.toLanguageTag())
                    }
                }
            }
        } catch (e: MissingResourceException) {
            Log.d(tag, "getLanguages: " + e.message)
        } catch (e: NullPointerException) {
            Log.d(tag, "getLanguages: " + e.message)
        }
        result.success(locales)
    }

    private fun getEngines(result: Result) {
        val engines = ArrayList<String>()
        try {
            for (engineInfo in tts!!.engines) {
                engines.add(engineInfo.name)
            }
        } catch (e: Exception) {
            Log.d(tag, "getEngines: " + e.message)
        }
        result.success(engines)
    }

    private fun getDefaultEngine(result: Result) {
        val defaultEngine: String = tts!!.defaultEngine
        result.success(defaultEngine)
    }

    private fun getDefaultVoice(result: Result) {
        val defaultVoice: Voice? = tts!!.defaultVoice
        val voice = HashMap<String, String>()
        if (defaultVoice != null) {
            voice["name"] = defaultVoice.name
            voice["locale"] = defaultVoice.locale.toLanguageTag()
        }
        result.success(voice)
    }

    private fun getSpeechRateValidRange(result: Result) {
        // Valid values available in the android documentation.
        // https://developer.android.com/reference/android/speech/tts/TextToSpeech#setSpeechRate(float)
        // To make the FlutterTts API consistent across platforms,
        // we map Android 1.0 to flutter 0.5 and so on.
        val data = HashMap<String, String>()
        data["min"] = "0"
        data["normal"] = "0.5"
        data["max"] = "1.5"
        data["platform"] = "android"
        result.success(data)
    }

    private fun speak(text: String, language: String) : Boolean {
        logDiagnostic("DEBUG", "speak() called", mapOf(
            "textLength" to text.length,
            "language" to language
        ))

        val locale = Locale.forLanguageTag(language)
        logDiagnostic("DEBUG", "Locale created", mapOf("locale" to locale.toString()))

        // Store the current voice before setting language
        val currentVoice = tts?.voice
        logDiagnostic("DEBUG", "Current voice", mapOf("voice" to (currentVoice?.name ?: "null")))

        // Set the language
        tts?.language = locale
        logDiagnostic("DEBUG", "Language set", mapOf("locale" to locale.toString()))

        // Restore the voice if it was set (setting language can override voice)
        if (currentVoice != null) {
            try {
                tts?.voice = currentVoice
                logDiagnostic("DEBUG", "Voice restored", mapOf("voice" to currentVoice.name))
            } catch (e: Exception) {
                logDiagnostic("ERROR", "Failed to restore voice after setting language", mapOf("error" to e.message))
            }
        }

        val uuid: String = UUID.randomUUID().toString()
        utterances[uuid] = text
        logDiagnostic("DEBUG", "Generated utterance UUID", mapOf("uuid" to uuid))

        logDiagnostic("DEBUG", "Checking service connection")
        return if (isServiceConnectionUsableNonBlocking(tts)) {
            logDiagnostic("DEBUG", "Service connection OK, attempting to speak")
            try {
                val speakResult = if (silencems > 0) {
                    logDiagnostic("DEBUG", "Playing silence then speaking", mapOf("silenceMs" to silencems))
                    tts!!.playSilentUtterance(
                        silencems.toLong(),
                        TextToSpeech.QUEUE_FLUSH,
                        SILENCE_PREFIX + uuid
                    )
                    tts!!.speak(text, TextToSpeech.QUEUE_ADD, bundle, uuid)
                } else {
                    logDiagnostic("DEBUG", "Speaking directly", mapOf("queueMode" to queueMode))
                    tts!!.speak(text, queueMode, bundle, uuid)
                }
                logDiagnostic("DEBUG", "TTS speak call returned", mapOf("result" to speakResult))

                if (speakResult != TextToSpeech.SUCCESS) {
                    val errorMessage = when (speakResult) {
                        TextToSpeech.ERROR -> "TTS engine reported an error during speech"
                        TextToSpeech.ERROR_INVALID_REQUEST -> "Invalid speech request"
                        TextToSpeech.ERROR_NETWORK -> "Network error during speech"
                        TextToSpeech.ERROR_NETWORK_TIMEOUT -> "Network timeout during speech"
                        TextToSpeech.ERROR_NOT_INSTALLED_YET -> "TTS engine not installed"
                        TextToSpeech.ERROR_OUTPUT -> "Audio output error during speech"
                        TextToSpeech.ERROR_SERVICE -> "TTS service error"
                        TextToSpeech.ERROR_SYNTHESIS -> "Speech synthesis error"
                        else -> "Unknown TTS speech error (code: $speakResult)"
                    }
                    Log.e(tag, "TTS speak failed: $errorMessage")
                    invokeMethod("tts.error", mapOf(
                        "type" to "speak_failure",
                        "message" to errorMessage,
                        "code" to "TTS_SPEAK_ERROR_$speakResult",
                        "text" to text,
                        "language" to language
                    ))
                    false
                } else {
                    true
                }
            } catch (e: Exception) {
                Log.e(tag, "Exception during TTS speak: ${e.message}", e)
                invokeMethod("tts.error", mapOf(
                    "type" to "speak_exception",
                    "message" to "Exception during TTS speak: ${e.message}",
                    "code" to "TTS_SPEAK_EXCEPTION",
                    "text" to text,
                    "language" to language
                ))
                false
            }
        } else {
            Log.e(tag, "TTS service connection not usable, reinitializing")
            invokeMethod("tts.error", mapOf(
                "type" to "service_connection_failure",
                "message" to "TTS service connection lost, attempting to reinitialize",
                "code" to "TTS_SERVICE_CONNECTION_LOST"
            ))
            isTtsInitialized = false
            tts = TextToSpeech(context, onInitListener, googleTtsEngine)
            false
        }
    }

    private fun stop() {
        if (awaitSynthCompletion) synth = false
        if (awaitSpeakCompletion) speaking = false
        tts!!.stop()
    }

    private fun isServiceConnectionUsableNonBlocking(tts: TextToSpeech?): Boolean {
        if (tts == null) {
            logDiagnostic("ERROR", "TTS instance is null")
            return false
        }

        // Quick non-blocking checks first
        try {
            // Test if we can get basic properties without reflection
            val engines = tts.engines
            if (engines.isNullOrEmpty()) {
                logDiagnostic("ERROR", "No TTS engines available")
                return false
            }

            // Test if default engine is accessible
            val defaultEngine = tts.defaultEngine
            if (defaultEngine.isNullOrEmpty()) {
                logDiagnostic("ERROR", "No default TTS engine")
                return false
            }

            logDiagnostic("DEBUG", "TTS service connection appears usable", mapOf("engine" to defaultEngine))
            return true

        } catch (e: Exception) {
            logDiagnostic("ERROR", "TTS service connection check failed", mapOf("error" to e.message))
            return false
        }
    }

    private val maxSpeechInputLength: Int
        get() = TextToSpeech.getMaxSpeechInputLength()

    private fun synthesizeToFile(text: String, fileName: String) {
        val file = File(fileName)
        val uuid: String = UUID.randomUUID().toString()
        bundle!!.putString(
            TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID,
            SYNTHESIZE_TO_FILE_PREFIX + uuid
        )
        val result: Int =
            tts!!.synthesizeToFile(text, bundle, file, SYNTHESIZE_TO_FILE_PREFIX + uuid)
        if (result == TextToSpeech.SUCCESS) {
            Log.d(tag, "Successfully created file : " + file.path)
        } else {
            Log.d(tag, "Failed creating file : " + file.path)
        }
    }

    private fun invokeMethod(method: String, arguments: Any) {
        handler!!.post {
            if (methodChannel != null) methodChannel!!.invokeMethod(
                method,
                arguments
            )
        }
    }

    private fun ismServiceConnectionUsable(tts: TextToSpeech?): Boolean {
        var isBindConnection = true
        if (tts == null) {
            return false
        }
        val fields: Array<Field> = tts.javaClass.declaredFields
        for (j in fields.indices) {
            fields[j].isAccessible = true
            if ("mServiceConnection" == fields[j].name && "android.speech.tts.TextToSpeech\$Connection" == fields[j].type.name) {
                try {
                    if (fields[j][tts] == null) {
                        isBindConnection = false
                        Log.e(tag, "*******TTS -> mServiceConnection == null*******")
                    }
                } catch (e: IllegalArgumentException) {
                    e.printStackTrace()
                } catch (e: IllegalAccessException) {
                    e.printStackTrace()
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
        return isBindConnection
    }

    private fun tryFallbackEngines(result: Result) {
        Log.d(tag, "🔄 TTS FALLBACK: Attempting to switch to fallback TTS engines")

        try {
            val availableEngines = tts?.engines ?: emptyList()
            Log.d(tag, "🔄 TTS FALLBACK: Available engines: ${availableEngines.map { it.name }}")

            val currentEngine = tts?.defaultEngine
            Log.d(tag, "🔄 TTS FALLBACK: Current engine: $currentEngine")

            // List of engines to try in order of preference
            val preferredEngines = listOf(
                "com.google.android.tts",           // Google TTS
                "com.samsung.SMT",                  // Samsung TTS
                "com.ivona.tts",                    // Amazon Ivona
                "es.codefactory.miniTTS",           // eSpeak TTS
                "com.cereproc.cerevoice.service",   // CereProc
                "com.acapelagroup.android.tts",     // Acapela TTS
                "com.baidu.dueros.canary"           // Baidu TTS
            )

            // Find engines that are available but not the current one
            val fallbackEngines = preferredEngines.filter { preferredEngine ->
                availableEngines.any { it.name == preferredEngine } && preferredEngine != currentEngine
            }

            if (fallbackEngines.isEmpty()) {
                Log.w(tag, "🔄 TTS FALLBACK: No suitable fallback engines found")
                result.error("NO_FALLBACK", "No alternative TTS engines available", mapOf(
                    "current_engine" to currentEngine,
                    "available_engines" to availableEngines.map { it.name }
                ))
                return
            }

            // Try the first available fallback engine
            val fallbackEngine = fallbackEngines.first()
            Log.d(tag, "🔄 TTS FALLBACK: Switching to engine: $fallbackEngine")

            // Initialize with the fallback engine
            isTtsInitialized = false
            tts?.shutdown()
            tts = TextToSpeech(context, { status ->
                Log.d(tag, "🔄 TTS FALLBACK: Fallback engine initialization status: $status")
                if (status == TextToSpeech.SUCCESS) {
                    Log.d(tag, "🔄 TTS FALLBACK: Successfully switched to $fallbackEngine")
                    isTtsInitialized = true
                    result.success(mapOf(
                        "success" to true,
                        "engine" to fallbackEngine,
                        "previous_engine" to currentEngine
                    ))
                } else {
                    Log.e(tag, "🔄 TTS FALLBACK: Failed to initialize $fallbackEngine")
                    result.error("FALLBACK_FAILED", "Failed to initialize fallback engine: $fallbackEngine", mapOf(
                        "status" to status,
                        "engine" to fallbackEngine
                    ))
                }
            }, fallbackEngine)

        } catch (e: Exception) {
            Log.e(tag, "🔄 TTS FALLBACK: Exception during fallback: ${e.message}", e)
            result.error("FALLBACK_EXCEPTION", "Exception during engine fallback: ${e.message}", null)
        }
    }
}
