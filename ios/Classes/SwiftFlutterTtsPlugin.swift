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
  var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  var languages = Set<String>()
  var volume: Float = 1.0
  var pitch: Float = 1.0
  var voice: AVSpeechSynthesisVoice?
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
    // Populate synthesizers for each available language if not already done
    for language in languages {
      if synthesizers[language] == nil {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        synthesizers[language] = synthesizer
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
      // Set the audio session category and mode before activating
      try audioSession.setCategory(.playback, mode: .default)
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
    // Check if a synthesizer exists for the specified language
    guard let selectedSynthesizer = synthesizers[language] else {
      result("No synthesizer available for the requested language: \(language)")
      return
    }

    // Stop all other synthesizers before proceeding
    for (lang, synthesizer) in synthesizers {
      if lang != language {
        synthesizer.stopSpeaking(at: .immediate)
      }
    }

    // If the synthesizer is paused, continue speaking
    if selectedSynthesizer.isPaused {
      if selectedSynthesizer.continueSpeaking() {
        if self.awaitSpeakCompletion {
          self.speakResult = result
        } else {
          result(1)
        }
      } else {
        result(0)
      }
    } else {
      // Create an utterance and configure it
      let utterance = AVSpeechUtterance(string: text)

      // Try to set the voice based on the specified language; fallback if not available.
      if let voiceForLanguage = AVSpeechSynthesisVoice(language: language) {
        utterance.voice = voiceForLanguage
      } else if let defaultVoice = self.voice {
        utterance.voice = defaultVoice
      } else {
        utterance.voice = AVSpeechSynthesisVoice(language: language)
      }

      utterance.rate = self.rate
      utterance.volume = self.volume
      utterance.pitchMultiplier = self.pitch

      // Start speaking
      selectedSynthesizer.speak(utterance)

      if self.awaitSpeakCompletion {
        self.speakResult = result
      } else {
        result(1)
      }
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

  private func setVoice(voice: [String:String], result: FlutterResult) {
    if #available(iOS 9.0, *) {
      if let matchedVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
        $0.name == voice["name"]! && $0.language == voice["locale"]!
      }) {
        self.voice = matchedVoice
        result(1)
        return
      }
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
