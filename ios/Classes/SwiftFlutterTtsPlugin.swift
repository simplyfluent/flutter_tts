import Flutter
import UIKit
import AVFoundation

public class SwiftFlutterTtsPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate {

  // MARK: - Constants
  final var iosAudioCategoryKey = "iosAudioCategoryKey"
  final var iosAudioCategoryOptionsKey = "iosAudioCategoryOptionsKey"
  final var iosAudioModeKey = "iosAudioModeKey"

  // MARK: - Properties
  var synthesizers: [String: AVSpeechSynthesizer] = [:] // Map language codes to synthesizers
  var voices: [String: AVSpeechSynthesisVoice] = [:] // Map language codes to voices
  var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  var languages = Set<String>()
  var volume: Float = 1.0
  var pitch: Float = 1.0
  var defaultVoice: AVSpeechSynthesisVoice?
  var awaitSpeakCompletion: Bool = false
  var awaitSynthCompletion: Bool = false
  var autoStopSharedSession: Bool = false
  var speakResult: FlutterResult? = nil
  var synthResult: FlutterResult? = nil

  var channel = FlutterMethodChannel()
  lazy var audioSession = AVAudioSession.sharedInstance()

  // MARK: - Initializer
  init(channel: FlutterMethodChannel) {
    super.init()
    self.channel = channel
    setLanguages()
    initializeSynthesizers()
    registerForAppLifecycleNotifications()
  }

  // MARK: - FlutterPlugin Registration
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_tts", binaryMessenger: registrar.messenger())
    let instance = SwiftFlutterTtsPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  // MARK: - App Lifecycle Notifications
  private func registerForAppLifecycleNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  @objc private func appWillEnterForeground() {
    // Force reinitialize all synthesizers when app comes back to foreground
    // This ensures they're properly initialized after potential backgrounding/termination
    reinitializeSynthesizers()
  }

  @objc private func appDidEnterBackground() {
    // Pause any ongoing speech when the app goes to the background
    pauseSynthesizers()
  }

  /// Pauses all active synthesizers
  private func pauseSynthesizers() {
    for (_, synthesizer) in synthesizers {
      if synthesizer.isSpeaking {
        synthesizer.pauseSpeaking(at: .word)
      }
    }
  }

  deinit {
    // Remove observers when this instance is deallocated
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Synthesizer Management
  private func initializeSynthesizers() {
    // Populate synthesizers for each available language if not already done
    for language in languages {
      if synthesizers[language] == nil {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        synthesizers[language] = synthesizer
      }
    }
  }
  
  private func reinitializeSynthesizers() {
    // Force re-creation of all synthesizers and their delegates
    // This ensures they're properly initialized after app lifecycle transitions
    print("TTS: Reinitializing all synthesizers after app lifecycle change")
    for language in languages {
      let synthesizer = AVSpeechSynthesizer()
      synthesizer.delegate = self
      synthesizers[language] = synthesizer
    }
    print("TTS: Reinitialized \(synthesizers.count) synthesizers")
  }

  private func getSynthesizer(for language: String) -> AVSpeechSynthesizer? {
    // Retrieve an existing synthesizer or create a new one for the specified language
    if let synthesizer = synthesizers[language] {
      // Ensure the delegate is properly set (may have been cleared during app lifecycle)
      if synthesizer.delegate !== self {
        synthesizer.delegate = self
      }
      return synthesizer
    } else {
      let synthesizer = AVSpeechSynthesizer()
      synthesizer.delegate = self
      synthesizers[language] = synthesizer
      return synthesizer
    }
  }

  private func setLanguages() {
    // Collect all supported voices/languages on this device
    for voice in AVSpeechSynthesisVoice.speechVoices() {
      self.languages.insert(voice.language)
    }
  }

  // MARK: - Flutter Method Call Handler
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkTTSAvailability":
      let availability = checkTtsAvailability()
      if availability.success {
        result(true)
      } else {
        // Use FlutterError to return an error message to Flutter
        result(FlutterError(code: "UNAVAILABLE", message: availability.message, details: nil))
      }

    case "speak":
      guard let args = call.arguments as? [String: Any],
            let text = args["text"] as? String,
            let language = args["language"] as? String else {
        result("Flutter arguments are not formatted correctly")
        return
      }
      self.speak(text: text, language: language, result: result)

    case "awaitSpeakCompletion":
      self.awaitSpeakCompletion = call.arguments as! Bool
      result(1)

    case "awaitSynthCompletion":
      self.awaitSynthCompletion = call.arguments as! Bool
      result(1)

    case "synthesizeToFile":
      guard let args = call.arguments as? [String: Any] else {
        result("iOS could not recognize flutter arguments in method: (sendParams)")
        return
      }
      let text = args["text"] as! String
      let fileName = args["fileName"] as! String
      self.synthesizeToFile(text: text, fileName: fileName, result: result)

    case "pause":
      self.pause(result: result)

    case "setSpeechRate":
      let rate: Double = call.arguments as! Double
      self.setRate(rate: Float(rate))
      result(1)

    case "setVolume":
      let volume: Double = call.arguments as! Double
      self.setVolume(volume: Float(volume), result: result)

    case "setPitch":
      let pitch: Double = call.arguments as! Double
      self.setPitch(pitch: Float(pitch), result: result)

    case "stop":
      self.stop()
      result(1)

    case "getLanguages":
      self.getLanguages(result: result)

    case "getSpeechRateValidRange":
      self.getSpeechRateValidRange(result: result)

    case "isLanguageAvailable":
      let language: String = call.arguments as! String
      self.isLanguageAvailable(language: language, result: result)

    case "getVoices":
      self.getVoices(result: result)

    case "getVoicesForLanguage":
      let language: String = call.arguments as! String
      self.getVoicesForLanguage(language: language, result: result)

    case "setVoice":
      guard let args = call.arguments as? [String: String] else {
        result("iOS could not recognize flutter arguments in method: (sendParams)")
        return
      }
      self.setVoice(voice: args, result: result)

    case "setSharedInstance":
      let sharedInstance = call.arguments as! Bool
      self.setSharedInstance(sharedInstance: sharedInstance, result: result)

    case "autoStopSharedSession":
      let autoStop = call.arguments as! Bool
      self.autoStopSharedSession = autoStop
      result(1)

    case "setIosAudioCategory":
      guard let args = call.arguments as? [String: Any] else {
        result("iOS could not recognize flutter arguments in method: (sendParams)")
        return
      }
      let audioCategory = args[iosAudioCategoryKey] as? String
      let audioOptions = args[iosAudioCategoryOptionsKey] as? Array<String>
      let audioModes = args[iosAudioModeKey] as? String
      self.setAudioCategory(audioCategory: audioCategory, audioOptions: audioOptions, audioMode: audioModes, result: result)

    case "forceReinitializeSynthesizers":
      self.reinitializeSynthesizers()
      result(1)

    case "getDiagnosticSnapshot":
      let snapshot = self.getDiagnosticSnapshot()
      result(snapshot)

    case "runDiagnosticTests":
      guard let args = call.arguments as? [String: Any],
            let languages = args["languages"] as? [String] else {
        result(FlutterError(code: "INVALID_ARGUMENTS",
                           message: "Languages array required",
                           details: nil))
        return
      }
      let testResults = self.runDiagnosticTests(languages: languages)
      result(testResults)

    case "getBufferedDiagnostics":
      // iOS doesn't buffer diagnostics like Android does
      // Return empty array to maintain API compatibility
      result([])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - TTS Core Methods
  func checkTtsAvailability() -> (success: Bool, message: String) {
    // Check iOS version compatibility
    if #available(iOS 7.0, *) {
      // TTS is supported in iOS 7 and above
    } else {
      return (false, "TTS is not supported on iOS versions below 7.0")
    }

    // Verify speech synthesis voices are available
    let voices = AVSpeechSynthesisVoice.speechVoices()
    if voices.isEmpty {
      return (false, "No TTS voices are available. Check if voice data is downloaded.")
    }

    // Check AVAudioSession availability
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setActive(true)

      let outputAvailable = !audioSession.currentRoute.outputs.isEmpty
      if !outputAvailable {
        return (false, "No audio outputs are available. Please check your device's audio output settings.")
      }
    } catch let error as NSError {
      return (false, "Failed to activate audio session: \(error.localizedDescription)")
    }

    // If all checks pass
    return (true, "TTS should be functional.")
  }

  private func speak(text: String, language: String, result: @escaping FlutterResult) {
    // Get a valid synthesizer for the specified language
    guard let selectedSynthesizer = getSynthesizer(for: language) else {
      let errorMessage = "No synthesizer available for the requested language: \(language)"
      print("TTS Error: \(errorMessage)")
      channel.invokeMethod("tts.error", arguments: [
        "type": "speak_failure",
        "message": errorMessage,
        "code": "NO_SYNTHESIZER_AVAILABLE",
        "language": language
      ])
      result(0)
      return
    }

    // Stop all other synthesizers before proceeding
    for (lang, synthesizer) in synthesizers {
      if lang != language {
        synthesizer.stopSpeaking(at: .immediate)
      }
    }

    do {
      // If the synthesizer is paused, continue speaking
      if selectedSynthesizer.isPaused {
        if selectedSynthesizer.continueSpeaking() {
          print("TTS: Continuing paused speech for language: \(language)")
          if self.awaitSpeakCompletion {
            self.speakResult = result
          } else {
            result(1)
          }
        } else {
          let errorMessage = "Failed to continue paused speech"
          print("TTS Error: \(errorMessage)")
          channel.invokeMethod("tts.error", arguments: [
            "type": "speak_failure",
            "message": errorMessage,
            "code": "CONTINUE_SPEAKING_FAILED",
            "language": language
          ])
          result(0)
        }
      } else {
        // Create an utterance and configure it
        let utterance = AVSpeechUtterance(string: text)

        // Try to set the voice based on the specified language; fallback if not available.
        var voiceUsed: String = "default"
        if let selectedVoice = self.voices[language] {
          utterance.voice = selectedVoice
          voiceUsed = selectedVoice.name
        } else if let voiceForLanguage = AVSpeechSynthesisVoice(language: language) {
          utterance.voice = voiceForLanguage
          voiceUsed = voiceForLanguage.name
        } else if let defaultVoice = self.defaultVoice {
          utterance.voice = defaultVoice
          voiceUsed = defaultVoice.name
        } else {
          utterance.voice = AVSpeechSynthesisVoice(language: language)
          voiceUsed = "system_default"
        }

        if utterance.voice == nil {
          let errorMessage = "No voice available for language: \(language)"
          print("TTS Error: \(errorMessage)")
          channel.invokeMethod("tts.error", arguments: [
            "type": "speak_failure",
            "message": errorMessage,
            "code": "NO_VOICE_AVAILABLE",
            "language": language
          ])
          result(0)
          return
        }

        utterance.rate = self.rate
        utterance.volume = self.volume
        utterance.pitchMultiplier = self.pitch

        // Start speaking with error handling
        do {
          selectedSynthesizer.speak(utterance)
          print("TTS: Started speaking with voice '\(voiceUsed)' for language: \(language)")

          if self.awaitSpeakCompletion {
            self.speakResult = result
          } else {
            result(1)
          }
        } catch {
          let errorMessage = "Failed to start speech synthesis: \(error.localizedDescription)"
          print("TTS Error: \(errorMessage)")
          channel.invokeMethod("tts.error", arguments: [
            "type": "speak_failure",
            "message": errorMessage,
            "code": "SPEAK_START_FAILED",
            "language": language,
            "voice": voiceUsed
          ])
          result(0)
        }
      }
    } catch {
      let errorMessage = "Exception in speak method: \(error.localizedDescription)"
      print("TTS Error: \(errorMessage)")
      channel.invokeMethod("tts.error", arguments: [
        "type": "speak_exception",
        "message": errorMessage,
        "code": "SPEAK_EXCEPTION",
        "language": language,
        "text": text
      ])
      result(0)
    }
  }

  private func synthesizeToFile(text: String, fileName: String, result: @escaping FlutterResult) {
    // Currently unimplemented. Return 0 or error if you want to indicate it's not supported.
    result(0)
  }

  // MARK: - Pause / Stop
  private func pause(result: FlutterResult) {
    var allPausedSuccessfully = true

    for (_, synthesizer) in synthesizers {
      // Attempt to pause each synthesizer
      if synthesizer.isSpeaking || synthesizer.isPaused {
        if !synthesizer.pauseSpeaking(at: .word) {
          allPausedSuccessfully = false
        }
      }
    }

    if allPausedSuccessfully {
      result(1) // Indicate success
    } else {
      result(0) // Indicate failure
    }
  }

  private func stop() {
    for (_, synthesizer) in synthesizers {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  // MARK: - TTS Configuration
  private func setRate(rate: Float) {
    self.rate = rate
  }

  private func setVolume(volume: Float, result: FlutterResult) {
    if (volume >= 0.0 && volume <= 1.0) {
      self.volume = volume
      result(1)
    } else {
      result(0)
    }
  }

  /// Note the corrected check: use `pitch` in the condition, not `volume`.
  private func setPitch(pitch: Float, result: FlutterResult) {
    if (pitch >= 0.5 && pitch <= 2.0) {
      self.pitch = pitch
      result(1)
    } else {
      result(0)
    }
  }

  private func setSharedInstance(sharedInstance: Bool, result: FlutterResult) {
    do {
      try AVAudioSession.sharedInstance().setActive(sharedInstance)
      result(1)
    } catch {
      result(0)
    }
  }

  private func setAudioCategory(audioCategory: String?, audioOptions: Array<String>?, audioMode: String?, result: FlutterResult) {
    let category: AVAudioSession.Category =
      AudioCategory(rawValue: audioCategory ?? "")?.toAVAudioSessionCategory() ?? audioSession.category

    let options: AVAudioSession.CategoryOptions =
      audioOptions?.reduce([], { (acc, option) -> AVAudioSession.CategoryOptions in
        return acc.union(AudioCategoryOptions(rawValue: option)?.toAVAudioSessionCategoryOptions() ?? [])
      }) ?? []

    do {
      if #available(iOS 12.0, *) {
        if audioMode == nil {
          try audioSession.setCategory(category, options: options)
        } else {
          let mode: AVAudioSession.Mode? =
            AudioModes(rawValue: audioMode ?? "")?.toAVAudioSessionMode() ?? AVAudioSession.Mode.default
          try audioSession.setCategory(category, mode: mode!, options: options)
        }
      } else {
        try audioSession.setCategory(category, options: options)
      }
      result(1)
    } catch {
      print("setAudioCategory error:", error)
      result(0)
    }
  }

  // MARK: - Diagnostics
  private func captureAudioState() -> [String: Any] {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      var audioState: [String: Any] = [:]

      audioState["category"] = audioSession.category.rawValue
      audioState["mode"] = audioSession.mode.rawValue
      audioState["outputVolume"] = audioSession.outputVolume
      audioState["isOtherAudioPlaying"] = audioSession.isOtherAudioPlaying

      // Get current route information
      let currentRoute = audioSession.currentRoute
      let outputs = currentRoute.outputs.map { output in
        return [
          "portType": output.portType.rawValue,
          "portName": output.portName
        ]
      }
      audioState["outputs"] = outputs

      let inputs = currentRoute.inputs.map { input in
        return [
          "portType": input.portType.rawValue,
          "portName": input.portName
        ]
      }
      audioState["inputs"] = inputs

      return audioState
    } catch {
      return ["error": "Failed to capture audio state: \(error.localizedDescription)"]
    }
  }

  private func getDiagnosticSnapshot() -> [String: Any] {
    var snapshot: [String: Any] = [:]

    // Audio state
    snapshot["audioState"] = captureAudioState()

    // Synthesizer states
    var synthesizerStates: [[String: Any]] = []
    for (language, synthesizer) in synthesizers {
      synthesizerStates.append([
        "language": language,
        "isSpeaking": synthesizer.isSpeaking,
        "isPaused": synthesizer.isPaused
      ])
    }
    snapshot["synthesizers"] = synthesizerStates

    // Voice information
    snapshot["voicesCount"] = AVSpeechSynthesisVoice.speechVoices().count
    snapshot["languagesCount"] = languages.count

    if let defaultVoice = self.defaultVoice {
      snapshot["defaultVoice"] = [
        "name": defaultVoice.name,
        "language": defaultVoice.language,
        "identifier": defaultVoice.identifier
      ]
    }

    // Configuration
    snapshot["rate"] = rate
    snapshot["volume"] = volume
    snapshot["pitch"] = pitch
    snapshot["awaitSpeakCompletion"] = awaitSpeakCompletion
    snapshot["awaitSynthCompletion"] = awaitSynthCompletion

    // System info
    snapshot["iosVersion"] = UIDevice.current.systemVersion
    snapshot["deviceModel"] = UIDevice.current.model
    snapshot["deviceName"] = UIDevice.current.name

    return snapshot
  }

  private func runDiagnosticTests(languages: [String]) -> [String: Any] {
    var results: [String: Any] = [:]
    var languageTests: [[String: Any]] = []

    print("🔬 iOS: Starting diagnostic tests for \(languages.count) languages")

    for languageCode in languages {
      var testResult: [String: Any] = [:]
      testResult["language"] = languageCode
      let startTime = Date()

      // Test 1: Find voices for this language
      let languageVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
        voice.language.lowercased().starts(with: languageCode.lowercased()) ||
        voice.language.lowercased() == languageCode.lowercased()
      }
      testResult["availableVoicesCount"] = languageVoices.count
      testResult["isLanguageAvailable"] = !languageVoices.isEmpty ? "AVAILABLE" : "NOT_AVAILABLE"

      // Test 2: Try to speak with this language
      if let synthesizer = getSynthesizer(for: languageCode) {
        let utterance = AVSpeechUtterance(string: "Test")

        // Try to set voice for this language
        if let voice = languageVoices.first {
          utterance.voice = voice
          testResult["voiceAfterSetLanguage"] = [
            "name": voice.name,
            "locale": voice.language,
            "identifier": voice.identifier
          ]
        } else {
          testResult["voiceAfterSetLanguage"] = NSNull()
        }

        utterance.rate = self.rate
        utterance.volume = self.volume
        utterance.pitchMultiplier = self.pitch

        // Try to speak (this is always "successful" on iOS unless synthesizer is nil)
        do {
          synthesizer.speak(utterance)
          synthesizer.stopSpeaking(at: .immediate) // Stop immediately
          testResult["speakResult"] = "SUCCESS"
          testResult["speakResultCode"] = 0
          testResult["success"] = true
        } catch {
          testResult["speakResult"] = "ERROR"
          testResult["speakException"] = error.localizedDescription
          testResult["success"] = false
        }
      } else {
        testResult["speakResult"] = "NO_SYNTHESIZER"
        testResult["success"] = false
      }

      let duration = Date().timeIntervalSince(startTime) * 1000
      testResult["testDurationMs"] = Int(duration)

      print("🔬 iOS test result for \(languageCode): voices=\(languageVoices.count), duration=\(Int(duration))ms")
      languageTests.append(testResult)
    }

    results["languageTests"] = languageTests
    results["totalLanguagesTested"] = languages.count
    results["successCount"] = languageTests.filter { ($0["success"] as? Bool) == true }.count
    results["failureCount"] = languageTests.filter { ($0["success"] as? Bool) == false }.count
    results["audioState"] = captureAudioState()

    print("🔬 iOS diagnostic tests complete: \(results["successCount"] ?? 0)/\(languages.count) successful")

    return results
  }

  // MARK: - Language and Voice Queries
  private func getLanguages(result: FlutterResult) {
    // Return the available languages as an array
    result(Array(self.languages))
  }

  private func getSpeechRateValidRange(result: FlutterResult) {
    let validSpeechRateRange: [String:String] = [
      "min": String(AVSpeechUtteranceMinimumSpeechRate),
      "normal": String(AVSpeechUtteranceDefaultSpeechRate),
      "max": String(AVSpeechUtteranceMaximumSpeechRate),
      "platform": "ios"
    ]
    result(validSpeechRateRange)
  }

  private func isLanguageAvailable(language: String, result: FlutterResult) {
    // Check if the set of voices includes the given language
    let isAvailable = self.languages.contains {
      $0.range(of: language, options: [.caseInsensitive, .anchored]) != nil
    }
    result(isAvailable)
  }

  private func getVoices(result: FlutterResult) {
    if #available(iOS 9.0, *) {
      let voices = NSMutableArray()
      var voiceDict: [String: String] = [:]
      for voice in AVSpeechSynthesisVoice.speechVoices() {
        voiceDict["name"] = voice.name
        voiceDict["locale"] = voice.language
        voiceDict["quality"] = voice.quality.stringValue
        if #available(iOS 13.0, *) {
          voiceDict["gender"] = voice.gender.stringValue
        }
        voiceDict["identifier"] = voice.identifier
        voices.add(voiceDict)
      }
      result(voices)
    } else {
      // Voice selection is not supported below iOS 9; revert to language list
      getLanguages(result: result)
    }
  }

  private func getVoicesForLanguage(language: String, result: FlutterResult) {
    if #available(iOS 9.0, *) {
      let voices = NSMutableArray()
      let languageLower = language.lowercased()
      let languagePrefix = languageLower.prefix(2) // Get "fr" from "fr-FR"
      
      print("iOS getVoicesForLanguage called with: \(language)")
      print("Looking for voices with language prefix: \(languagePrefix)")
      
      for voice in AVSpeechSynthesisVoice.speechVoices() {
        let voiceLanguage = voice.language.lowercased()
        let voicePrefix = voiceLanguage.prefix(2)
        
        // Match by language prefix (e.g., "fr-FR", "fr-CA" both match "fr")
        // Or exact match for full language codes
        let isMatch = voicePrefix == languagePrefix || voiceLanguage == languageLower
        
        if isMatch {
          var voiceDict: [String: String] = [:]
          voiceDict["name"] = voice.name
          voiceDict["locale"] = voice.language
          voiceDict["quality"] = voice.quality.stringValue
          if #available(iOS 13.0, *) {
            voiceDict["gender"] = voice.gender.stringValue
          }
          voiceDict["identifier"] = voice.identifier
          voices.add(voiceDict)
          
          print("Found matching voice: \(voice.name) (\(voice.language))")
        }
      }
      
      print("Total voices found for \(language): \(voices.count)")
      result(voices)
    } else {
      // Voice selection is not supported below iOS 9; return empty array
      result([])
    }
  }

  private func setVoice(voice: [String:String], result: FlutterResult) {
    if #available(iOS 9.0, *) {
      guard let requestedName = voice["name"], let requestedLocale = voice["locale"] else {
        let errorMessage = "Invalid voice parameters: missing name or locale"
        print("TTS Error: \(errorMessage)")
        channel.invokeMethod("tts.error", arguments: [
          "type": "voice_setting_error",
          "message": errorMessage,
          "code": "INVALID_VOICE_PARAMS",
          "requested_voice": voice
        ])
        result(0)
        return
      }

      let availableVoices = AVSpeechSynthesisVoice.speechVoices()
      if availableVoices.isEmpty {
        let errorMessage = "No voices available from iOS TTS engine"
        print("TTS Error: \(errorMessage)")
        channel.invokeMethod("tts.error", arguments: [
          "type": "voice_setting_error",
          "message": errorMessage,
          "code": "NO_VOICES_AVAILABLE"
        ])
        result(0)
        return
      }

      // Try to match by identifier first (stable, non-localized)
      // Fall back to name + locale matching for backward compatibility
      var matchedVoice: AVSpeechSynthesisVoice? = nil

      if let requestedIdentifier = voice["identifier"], !requestedIdentifier.isEmpty {
        // Primary: Match by identifier (most reliable, immune to localization)
        matchedVoice = availableVoices.first(where: { $0.identifier == requestedIdentifier })
        if matchedVoice != nil {
          print("TTS: Matched voice by identifier: \(requestedIdentifier)")
        }
      }

      // Fallback: Match by name + locale (for backward compatibility with old saved voices)
      if matchedVoice == nil {
        matchedVoice = availableVoices.first(where: {
          $0.name == requestedName && $0.language == requestedLocale
        })
        if matchedVoice != nil {
          print("TTS: Matched voice by name+locale: \(requestedName) (\(requestedLocale))")
        }
      }

      if let matchedVoice = matchedVoice {
        do {
          let voiceLocale = requestedLocale
          let voicePrefix = String(voiceLocale.lowercased().prefix(2)) // Get "fr" from "fr-CA"

          // Store the voice for all related language codes
          // This ensures speak() can find it regardless of which language code is used
          for (languageCode, synthesizer) in synthesizers {
            let synthesizerPrefix = String(languageCode.lowercased().prefix(2))
            if synthesizerPrefix == voicePrefix {
              self.voices[languageCode] = matchedVoice
              print("Stored voice \(matchedVoice.name) for language code: \(languageCode)")
            }
          }

          // Also store it under the voice's actual locale
          self.voices[voiceLocale] = matchedVoice

          // Also set as default voice if none exists
          if self.defaultVoice == nil {
            self.defaultVoice = matchedVoice
          }

          print("TTS: Successfully set voice: \(matchedVoice.name) (\(matchedVoice.language))")
          result(1)
          return
        } catch {
          let errorMessage = "Failed to apply voice: \(error.localizedDescription)"
          print("TTS Error: \(errorMessage)")
          channel.invokeMethod("tts.error", arguments: [
            "type": "voice_setting_error",
            "message": errorMessage,
            "code": "VOICE_APPLICATION_FAILED",
            "requested_voice": voice
          ])
          result(0)
          return
        }
      }

      // Voice not found
      let availableVoiceInfo = availableVoices.map { ["name": $0.name, "locale": $0.language] }
      let errorMessage = "Requested voice not found: \(requestedName) (\(requestedLocale))"
      print("TTS Error: \(errorMessage)")
      print("Available voices: \(availableVoiceInfo)")
      channel.invokeMethod("tts.error", arguments: [
        "type": "voice_setting_error",
        "message": errorMessage,
        "code": "VOICE_NOT_FOUND",
        "requested_voice": voice,
        "available_voices": availableVoiceInfo
      ])
      result(0)
    } else {
      let errorMessage = "Voice setting not supported on iOS versions below 9.0"
      print("TTS Error: \(errorMessage)")
      channel.invokeMethod("tts.error", arguments: [
        "type": "voice_setting_error",
        "message": errorMessage,
        "code": "IOS_VERSION_UNSUPPORTED"
      ])
      result(0)
    }
  }

  // MARK: - AVSpeechSynthesizerDelegate
  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // If we're awaiting completion of speak, return success to Flutter
    if self.awaitSpeakCompletion, let speakResult = self.speakResult {
      speakResult(1)
      self.speakResult = nil
    }

    // If we're awaiting completion of file synthesis, return success to Flutter
    if self.awaitSynthCompletion, let synthResult = self.synthResult {
      synthResult(1)
      self.synthResult = nil
    }

    // Notify Flutter of completion
    self.channel.invokeMethod("speak.onComplete", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    self.channel.invokeMethod("speak.onStart", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
    self.channel.invokeMethod("speak.onPause", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
    self.channel.invokeMethod("speak.onContinue", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    self.channel.invokeMethod("speak.onCancel", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                willSpeakRangeOfSpeechString characterRange: NSRange,
                                utterance: AVSpeechUtterance) {
    let nsWord = utterance.speechString as NSString
    let data: [String: String] = [
      "text": utterance.speechString,
      "start": String(characterRange.location),
      "end": String(characterRange.location + characterRange.length),
      "word": nsWord.substring(with: characterRange)
    ]
    self.channel.invokeMethod("speak.onProgress", arguments: data)
  }
}

// MARK: - Extensions for Voice Quality/Gender
extension AVSpeechSynthesisVoiceQuality {
  var stringValue: String {
    switch self {
    case .default:
      return "default"
    case .premium:
      return "premium"
    case .enhanced:
      return "enhanced"
    }
  }
}

@available(iOS 13.0, *)
extension AVSpeechSynthesisVoiceGender {
  var stringValue: String {
    switch self {
    case .male:
      return "male"
    case .female:
      return "female"
    case .unspecified:
      return "unspecified"
    }
  }
}
