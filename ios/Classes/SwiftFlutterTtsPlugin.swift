import Flutter
import UIKit
import AVFoundation

public class SwiftFlutterTtsPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate {
  final var iosAudioCategoryKey = "iosAudioCategoryKey"
  final var iosAudioCategoryOptionsKey = "iosAudioCategoryOptionsKey"
  final var iosAudioModeKey = "iosAudioModeKey"

  var synthesizers: [String: AVSpeechSynthesizer] = [:] // Map language codes to synthesizers
  var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  var languages = Set<String>()
  var volume: Float = 1.0
  var pitch: Float = 1.0
  var voice: AVSpeechSynthesisVoice?
  var awaitSpeakCompletion: Bool = false
  var awaitSynthCompletion: Bool = false
  var autoStopSharedSession: Bool = true
  var speakResult: FlutterResult? = nil
  var synthResult: FlutterResult? = nil

  var channel = FlutterMethodChannel()
  lazy var audioSession = AVAudioSession.sharedInstance()

  init(channel: FlutterMethodChannel) {
    super.init()
    self.channel = channel
    setLanguages()
    initializeSynthesizers()
    // Activate audio session right away
    do {
      try audioSession.setActive(true)
    } catch {
      print("Failed to activate audio session: \(error)")
    }
  }

  private func initializeSynthesizers() {
    // Assuming `languages` is already populated with available language codes
    for language in languages {
      let synthesizer = AVSpeechSynthesizer()
      synthesizer.delegate = self
      synthesizers[language] = synthesizer
    }
  }

  private func setLanguages() {
    for voice in AVSpeechSynthesisVoice.speechVoices() {
      self.languages.insert(voice.language)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_tts", binaryMessenger: registrar.messenger())
    let instance = SwiftFlutterTtsPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkTTSAvailability":
      let availability = checkTtsAvailability()
      if availability.success {
        result(true)
      } else {
        // Use FlutterError to throw an exception back to Flutter with the error message
        result(FlutterError(code: "UNAVAILABLE", message: availability.message, details: nil))
      }
      break
    case "speak":
      guard let args = call.arguments as? [String: Any],
            let text = args["text"] as? String,
            let language = args["language"] as? String else {
        result("Flutter arguments are not formatted correctly")
        return
      }
      self.speak(text: text, language: language, result: result)
      break
    case "awaitSpeakCompletion":
      self.awaitSpeakCompletion = call.arguments as! Bool
      result(1)
      break
    case "awaitSynthCompletion":
      self.awaitSynthCompletion = call.arguments as! Bool
      result(1)
      break
    case "synthesizeToFile":
      guard let args = call.arguments as? [String: Any],
            let text = args["text"] as? String,
            let language = args["language"] as? String,
            let fileName = args["fileName"] as? String else {
        result("iOS could not recognize flutter arguments in method: (sendParams)")
        return
      }
      self.synthesizeToFile(text: text, language: language, fileName: fileName, result: result)
      break
    case "pause":
      self.pause(result: result)
      break
    case "setSpeechRate":
      let rate: Double = call.arguments as! Double
      self.setRate(rate: Float(rate))
      result(1)
      break
    case "setVolume":
      let volume: Double = call.arguments as! Double
      self.setVolume(volume: Float(volume), result: result)
      break
    case "setPitch":
      let pitch: Double = call.arguments as! Double
      self.setPitch(pitch: Float(pitch), result: result)
      break
    case "stop":
      self.stop()
      result(1)
      break
    case "getLanguages":
      self.getLanguages(result: result)
      break
    case "getSpeechRateValidRange":
      self.getSpeechRateValidRange(result: result)
      break
    case "isLanguageAvailable":
      let language: String = call.arguments as! String
      self.isLanguageAvailable(language: language, result: result)
      break
    case "getVoices":
      self.getVoices(result: result)
      break
    case "setVoice":
      guard let args = call.arguments as? [String: String] else {
        result("iOS could not recognize flutter arguments in method: (sendParams)")
        return
      }
      self.setVoice(voice: args, result: result)
      break
    case "setSharedInstance":
      let sharedInstance = call.arguments as! Bool
      self.setSharedInstance(sharedInstance: sharedInstance, result: result)
      break
    case "autoStopSharedSession":
      let autoStop = call.arguments as! Bool
      self.autoStopSharedSession = autoStop
      result(1)
      break
    case "setIosAudioCategory":
      guard let args = call.arguments as? [String: Any] else {
        result("iOS could not recognize flutter arguments in method: (sendParams)")
        return
      }
      let audioCategory = args["iosAudioCategoryKey"] as? String
      let audioOptions = args[iosAudioCategoryOptionsKey] as? Array<String>
      let audioModes = args[iosAudioModeKey] as? String
      self.setAudioCategory(audioCategory: audioCategory, audioOptions: audioOptions, audioMode: audioModes, result: result)
      break
    default:
      result(FlutterMethodNotImplemented)
    }
  }

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
      var outputAvailable = false
      for output in audioSession.currentRoute.outputs where output.portType != AVAudioSession.Port.builtInReceiver && output.portType != AVAudioSession.Port.builtInSpeaker {
        outputAvailable = true
        break
      }
      if !outputAvailable {
        return (false, "Audio output seems to be compromised. Please check your device's audio output settings.")
      }
    } catch {
      return (false, "Failed to activate audio session, which might affect TTS functionality.")
    }

    // If all checks pass
    return (true, "TTS should be functional.")
  }

  private func speak(text: String, language: String, result: @escaping FlutterResult) {
      // Check if a synthesizer exists for the specified language. If not, immediately return an error result.
      guard let selectedSynthesizer = synthesizers[language] else {
          result("No synthesizer available for the requested language: \(language)")
          return
      }

      // Stop all other synthesizers before proceeding.
      for (lang, synthesizer) in synthesizers {
          if lang != language {
              synthesizer.stopSpeaking(at: .immediate)
          }
      }

      // Proceed with the existing logic, using 'selectedSynthesizer' instead of 'self.synthesizer'.
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
          let utterance = AVSpeechUtterance(string: text)
          // Try to set the voice based on the specified language; fallback to the default if not available.
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

          selectedSynthesizer.speak(utterance)
          if self.awaitSpeakCompletion {
              self.speakResult = result
          } else {
              result(1)
          }
      }
  }

  private func synthesizeToFile(text: String, language: String, fileName: String, result: @escaping FlutterResult) {
     // Check if a synthesizer exists for the specified language.
    guard let selectedSynthesizer = synthesizers[language] else {
      result("No synthesizer available for the requested language: \(language)")
      return
    }

    // Stop all synthesizers before proceeding.
    for (_, synthesizer) in synthesizers {
      synthesizer.stopSpeaking(at: .immediate)
    }

    let utterance = AVSpeechUtterance(string: text)
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

    var output: AVAudioFile?
    var failed = false
    var resultReturned = false

    if #available(iOS 13.0, *) {
      if self.awaitSynthCompletion {
        self.synthResult = result
      } else {
        self.synthResult = result
      }
      selectedSynthesizer.write(utterance) { [weak self] (buffer: AVAudioBuffer) in
        guard let self = self else { return }
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
          NSLog("unknown buffer type: \(buffer)")
          failed = true
          if !resultReturned {
            if self.awaitSynthCompletion && self.synthResult != nil {
              self.synthResult!(0)
              self.synthResult = nil
            } else {
              result(0)
            }
            resultReturned = true
          }
          return
        }
        if pcmBuffer.frameLength == 0 {
          // Finished
          if !resultReturned {
            if self.awaitSynthCompletion && self.synthResult != nil {
              self.synthResult!(1)
              self.synthResult = nil
            } else {
              result(1)
            }
            resultReturned = true
          }
        } else {
          // Append buffer to file
          let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(fileName)
          if output == nil {
            do {
              if #available(iOS 17.0, *) {
                guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(22050), channels: 1, interleaved: false) else {
                  NSLog("Error creating audio format for iOS 17+")
                  failed = true
                  if !resultReturned {
                    if self.awaitSynthCompletion && self.synthResult != nil {
                      self.synthResult!(0)
                      self.synthResult = nil
                    } else {
                      result(0)
                    }
                    resultReturned = true
                  }
                  return
                }
                output = try AVAudioFile(forWriting: fileURL, settings: audioFormat.settings)
              } else {
                output = try AVAudioFile(forWriting: fileURL, settings: pcmBuffer.format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
              }
            } catch {
              NSLog("Error creating AVAudioFile: \(error.localizedDescription)")
              failed = true
              if !resultReturned {
                if self.awaitSynthCompletion && self.synthResult != nil {
                  self.synthResult!(0)
                  self.synthResult = nil
                } else {
                  result(0)
                }
                resultReturned = true
              }
              return
            }
          }

          do {
            try output!.write(from: pcmBuffer)
          } catch {
            NSLog("Error writing to AVAudioFile: \(error.localizedDescription)")
            failed = true
            if !resultReturned {
              if self.awaitSynthCompletion && self.synthResult != nil {
                self.synthResult!(0)
                self.synthResult = nil
              } else {
                result(0)
              }
              resultReturned = true
            }
            return
          }
        }
      }
    } else {
      result("Unsupported iOS version")
      return
    }

    if !self.awaitSynthCompletion && !resultReturned {
      result(1)
      resultReturned = true
    }
  }

  private func pause(result: FlutterResult) {
    var allPausedSuccessfully = true

    for (_, synthesizer) in synthesizers {
      // Attempt to pause each synthesizer.
      if synthesizer.isSpeaking || synthesizer.isPaused {
        if !synthesizer.pauseSpeaking(at: .word) {
          allPausedSuccessfully = false
        }
      }
    }

    if allPausedSuccessfully {
      result(1) // Indicate success if all relevant synthesizers were paused.
    } else {
      result(0) // Indicate failure if at least one relevant synthesizer could not be paused.
    }
  }

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
    let category: AVAudioSession.Category = AudioCategory(rawValue: audioCategory ?? "")?.toAVAudioSessionCategory() ?? audioSession.category
    let options: AVAudioSession.CategoryOptions = audioOptions?.reduce([], { (result, option) -> AVAudioSession.CategoryOptions in
      return result.union(AudioCategoryOptions(rawValue: option)?.toAVAudioSessionCategoryOptions() ?? [])
    }) ?? []
    do {
      if #available(iOS 12.0, *) {
        if audioMode == nil {
          try audioSession.setCategory(category, options: options)
        } else {
          let mode: AVAudioSession.Mode? = AudioModes(rawValue: audioMode ?? "")?.toAVAudioSessionMode() ?? AVAudioSession.Mode.default
          try audioSession.setCategory(category, mode: mode!, options: options)
        }
      } else {
        try audioSession.setCategory(category, options: options)
      }
      result(1)
    } catch {
      print(error)
      result(0)
    }
  }

  private func stop() {
    // Stop all synthesizers
    for (_, synthesizer) in synthesizers {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func getLanguages(result: FlutterResult) {
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
    var isAvailable: Bool = false
    if (self.languages.contains(where: { $0.range(of: language, options: [.caseInsensitive, .anchored]) != nil })) {
      isAvailable = true
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
      // Since voice selection is not supported below iOS 9, make voice getter and setter
      // have the same behavior as language selection.
      getLanguages(result: result)
    }
  }

  private func setVoice(voice: [String: String], result: FlutterResult) {
    if #available(iOS 9.0, *) {
      if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voice["name"]! && $0.language == voice["locale"]! }) {
        self.voice = voice
        result(1)
        return
      }
      result(0)
    }
  }

  private func shouldDeactivateAndNotifyOthers(_ session: AVAudioSession) -> Bool {
    var options: AVAudioSession.CategoryOptions = .duckOthers
    if #available(iOS 9.0, *) {
      options.insert(.interruptSpokenAudioAndMixWithOthers)
    }
    options.remove(.mixWithOthers)

    return !options.isDisjoint(with: session.categoryOptions)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // Removed deactivation of audio session
    if self.awaitSpeakCompletion && self.speakResult != nil {
      self.speakResult!(1)
      self.speakResult = nil
    }
    if self.awaitSynthCompletion && self.synthResult != nil {
      self.synthResult!(1)
      self.synthResult = nil
    }
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

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
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

extension AVSpeechSynthesisVoiceQuality {
  var stringValue: String {
    switch self {
    case .default:
      return "default"
    case .premium:
      return "premium"
    case .enhanced:
      return "enhanced"
    @unknown default:
      return "unknown"
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
    @unknown default:
      return "unknown"
    }
  }
}
