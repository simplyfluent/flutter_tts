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
  var voicesForLanguage: [String: AVSpeechSynthesisVoice] = [:] // Custom voice per language
  var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  var languages = Set<String>()
  var languageMap: [String: String] = [:] // Maps lowercase to original case
  var volume: Float = 1.0
  var pitch: Float = 1.0
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
    // Reinitialize synthesizers if needed (only if they don’t exist)
    // This ensures they're ready for use when the app comes back to the foreground.
    initializeSynthesizers()
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
    for language in languages {
      if synthesizers[language] == nil {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        synthesizers[language] = synthesizer
        print("initializeSynthesizers: Created synthesizer for language: \(language)")
      }
    }
  }

  private func getSynthesizer(for language: String) -> AVSpeechSynthesizer? {
    // Retrieve an existing synthesizer or create a new one for the specified language
    if let synthesizer = synthesizers[language] {
      return synthesizer
    } else {
      let synthesizer = AVSpeechSynthesizer()
      synthesizer.delegate = self
      synthesizers[language] = synthesizer
      return synthesizer
    }
  }

  private func setLanguages() {
    for voice in AVSpeechSynthesisVoice.speechVoices() {
      let lang = voice.language // e.g., "en-US"
      let langLower = lang.lowercased() // e.g., "en-us"
      self.languages.insert(langLower)
      self.languageMap[langLower] = lang
      print("setLanguages: Mapped \(langLower) to \(lang)")
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
      print("handle: Received speak call with arguments: \(String(describing: call.arguments))")
      guard let args = call.arguments as? [String: Any],
        let text = args["text"] as? String,
        let language = args["language"] as? String else {
        result("Invalid arguments for speak")
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

    case "setVoice":
      print("handle: Received setVoice call with arguments: \(String(describing: call.arguments))")
      guard let args = call.arguments as? [String: String] else {
        result("Invalid arguments for setVoice")
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
    let languageKey = language.lowercased()
    print("speak: Language passed: \(language), normalized to: \(languageKey)")

    // Look up the synthesizer using the normalized key.
    guard let selectedSynthesizer = synthesizers[languageKey] else {
      print("speak: No synthesizer available for languageKey: \(languageKey)")
      result("No synthesizer available for the requested language: \(language)")
      return
    }

    print("speak: Using synthesizer for languageKey: \(languageKey)")

    // Stop all other synthesizers.
    for (lang, synthesizer) in synthesizers {
      if lang != languageKey {
        synthesizer.stopSpeaking(at: .immediate)
        print("speak: Stopped synthesizer for language: \(lang)")
      }
    }

    // Ensure the audio session is active.
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("speak: Failed to activate audio session: \(error)")
    }

    // Create an utterance.
    let utterance = AVSpeechUtterance(string: text)

    // Set the voice: use a custom voice if available; otherwise, fall back to the default.
    if let customVoice = self.voicesForLanguage[languageKey] {
      print("speak: Using custom voice for \(languageKey): \(customVoice.name), locale: \(customVoice.language)")
      utterance.voice = customVoice
    } else if let originalLanguage = self.languageMap[languageKey] {
      print("speak: No custom voice found, using default voice for original language: \(originalLanguage)")
      utterance.voice = AVSpeechSynthesisVoice(language: originalLanguage)
    } else {
      print("speak: No voice available for languageKey: \(languageKey)")
      result("No voice available for the requested language: \(language)")
      return
    }

    // Configure utterance properties.
    utterance.rate = self.rate
    utterance.volume = self.volume
    utterance.pitchMultiplier = self.pitch

    // Start speaking.
    selectedSynthesizer.speak(utterance)
    print("speak: Speaking utterance with text: \(text), language: \(languageKey), voice: \(utterance.voice?.name ?? "nil")")

    // If awaitSpeakCompletion is enabled, store the result callback;
    // otherwise, immediately return success.
    if self.awaitSpeakCompletion {
      self.speakResult = result
    } else {
      result(1)
    }
  }

  private func synthesizeToFile(text: String, fileName: String, result: @escaping FlutterResult) {
    // Currently unimplemented. Return 0 to indicate it's not supported.
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
    result(allPausedSuccessfully ? 1 : 0)
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
    if volume >= 0.0 && volume <= 1.0 {
      self.volume = volume
      result(1)
    } else {
      result(0)
    }
  }

  /// Note the corrected check: use `pitch` in the condition, not `volume`.
  private func setPitch(pitch: Float, result: FlutterResult) {
    if pitch >= 0.5 && pitch <= 2.0 {
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

  // MARK: - Language and Voice Queries
  private func getLanguages(result: FlutterResult) {
    // Return the available languages as an array
    result(Array(self.languages))
  }

  private func getSpeechRateValidRange(result: FlutterResult) {
    let validSpeechRateRange: [String: String] = [
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
      for voice in AVSpeechSynthesisVoice.speechVoices() {
        var voiceDict: [String: String] = [:]
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

  // Updated setVoice to support one voice per language.
  private func setVoice(voice: [String: String], result: FlutterResult) {
    if #available(iOS 9.0, *) {
      guard let locale = voice["locale"]?.lowercased(), let name = voice["name"] else {
        print("setVoice: Missing 'locale' or 'name' in arguments: \(voice)")
        result(0)
        return
      }
      print("setVoice: Attempting to set voice for locale: \(locale), name: \(name)")

      // Log all available voices for debugging
      print("setVoice: Available voices:")
      for avVoice in AVSpeechSynthesisVoice.speechVoices() {
        print(" - Name: \(avVoice.name), Language: \(avVoice.language)")
      }

      if let matchedVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
        $0.name == name && $0.language.compare(locale, options: .caseInsensitive) == .orderedSame
      }) {
        voicesForLanguage[locale] = matchedVoice
        print("setVoice: Successfully set voice for \(locale): \(matchedVoice.name), language: \(matchedVoice.language)")
        result(1)
        return
      }
      print("setVoice: No matching voice found for locale: \(locale), name: \(name)")
      result(0) // Voice not found
    } else {
      print("setVoice: Feature not available below iOS 9.0")
      result(FlutterMethodNotImplemented)
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
