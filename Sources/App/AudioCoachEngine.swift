import Foundation
@preconcurrency import AVFoundation
import Combine

@MainActor
final class AudioCoachEngine: NSObject, ObservableObject {
    @Published var currentComboDisplay: String = ""
    @Published var strikesCuedCount: Int = 0
    @Published var isPreparingAudio: Bool = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private var engineReady = false
    private var audioEnabled = true

    private var tokenBuffers: [String: AVAudioPCMBuffer] = [:]
    private var beepHighBuffer: AVAudioPCMBuffer?
    private var beepLowBuffer: AVAudioPCMBuffer?
    private var bellBuffer: AVAudioPCMBuffer?

    private var bagTimerTask: Task<Void, Never>?
    private var announcementQueue: [String] = []
    private var isSpeakingDynamic = false

    private let punchTokens = [
        "Jab!", "Cross!", "Left hook!", "Right hook!",
        "Left uppercut!", "Right uppercut!", "Body jab!", "Right body hook!"
    ]
    private let kickTokens = [
        "Left middle kick!", "Right middle kick!",
        "Left low kick!", "Right low kick!", "Teep!", "Switch kick!"
    ]
    private let closeRangeTokens = [
        "Left knee!", "Right knee!", "Left elbow!", "Right elbow!"
    ]
    private let defenseTokens = [
        "Slip!", "Roll!", "Check!", "Pivot!"
    ]

    override init() {
        super.init()
        setupAudioSessionAndEngine()
        buildSynthesizedCues()
    }

    // Only wires the graph. The session and engine are started on demand by
    // ensureEngineRunning(), so the app is not holding an active audio session
    // (and staying awake in the background via UIBackgroundModes=audio) from launch.
    private func setupAudioSessionAndEngine() {
        guard !engineReady else { return }
        audioEngine.attach(playerNode)
        if let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1) {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            engineReady = true
        }
    }

    private func ensureEngineRunning() {
        guard engineReady, audioEnabled else { return }
        if !audioEngine.isRunning {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                try audioEngine.start()
            } catch {
                print("Audio start error: \(error)")
                return
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Call at workout start so cues can play again after a previous shutdown.
    func prepareForWorkout() {
        audioEnabled = true
    }

    /// Stops the engine and releases the audio session after a workout.
    func shutdownAudio() {
        audioEnabled = false
        announcementQueue.removeAll()
        playerNode.stop()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func prepareStrikeVocabulary() async {
        let allTokens = punchTokens + kickTokens + closeRangeTokens + defenseTokens
        let missing = allTokens.filter { tokenBuffers[$0] == nil }
        guard !missing.isEmpty else { return }

        isPreparingAudio = true
        for token in missing {
            if let buf = await renderSpeechToPCMBuffer(text: token, rate: 0.56) {
                tokenBuffers[token] = buf
            }
        }
        isPreparingAudio = false
    }

    private func renderSpeechToPCMBuffer(text: String, rate: Float) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = rate
        utterance.pitchMultiplier = 1.05
        utterance.volume = 1.0

        return await withCheckedContinuation { continuation in
            var chunks: [AVAudioPCMBuffer] = []
            var resumed = false

            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 {
                    chunks.append(pcm)
                } else if !resumed {
                    resumed = true
                    let combined = Self.mergeAndResample(chunks: chunks, targetRate: 22050)
                    continuation.resume(returning: combined)
                }
            }
        }
    }

    private nonisolated static func mergeAndResample(chunks: [AVAudioPCMBuffer], targetRate: Double) -> AVAudioPCMBuffer? {
        guard let first = chunks.first else { return nil }
        let totalFrames = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0,
              let monoSourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: first.format.sampleRate, channels: 1, interleaved: false),
              let combined = AVAudioPCMBuffer(pcmFormat: monoSourceFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            return nil
        }

        combined.frameLength = AVAudioFrameCount(totalFrames)
        guard let dst = combined.floatChannelData?[0] else { return nil }

        var offset = 0
        for chunk in chunks {
            let count = Int(chunk.frameLength)
            if let floatData = chunk.floatChannelData?[0] {
                dst.advanced(by: offset).update(from: floatData, count: count)
            } else if let int16Data = chunk.int16ChannelData?[0] {
                for i in 0..<count {
                    dst[offset + i] = Float(int16Data[i]) / 32768.0
                }
            }
            offset += count
        }

        if abs(monoSourceFormat.sampleRate - targetRate) < 1.0 {
            return combined
        }

        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1),
              let converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat) else {
            return combined
        }

        let ratio = targetRate / monoSourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(totalFrames) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return combined
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return combined
        }
        return outBuffer.frameLength > 0 ? outBuffer : combined
    }

    private func buildSynthesizedCues() {
        beepHighBuffer = makeToneBuffer(freq: 1046.5, duration: 0.085, amplitude: 0.55)
        beepLowBuffer = makeToneBuffer(freq: 784.0, duration: 0.095, amplitude: 0.55)
        bellBuffer = makeToneBuffer(freq: 1318.5, duration: 0.28, amplitude: 0.65)
    }

    private func makeToneBuffer(freq: Double, duration: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        let sampleRate = 22050.0
        let frameCount = Int(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let data = buffer.floatChannelData?[0] else { return nil }

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let envelope = Float(exp(-t * 18.0))
            let wave = Float(sin(2.0 * .pi * freq * t))
            data[i] = wave * envelope * amplitude
        }
        return buffer
    }

    func playBellCue() {
        ensureEngineRunning()
        if let bell = bellBuffer {
            playerNode.scheduleBuffer(bell, at: nil, options: [], completionHandler: nil)
        }
    }

    func startBagCoachLoop(
        config: BagCoachConfig,
        isWorkPhaseProvider: @escaping () -> Bool,
        roundProgressProvider: @escaping () -> Double
    ) {
        stopBagCoachLoop()
        guard config.enabled else { return }

        bagTimerTask = Task {
            await prepareStrikeVocabulary()
            ensureEngineRunning()

            while !Task.isCancelled {
                guard isWorkPhaseProvider() else {
                    currentComboDisplay = "STOOL REST — BREATHE"
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    continue
                }

                let progress = roundProgressProvider()
                let targetCycleSeconds = Double.random(in: config.tempo.pauseRange(roundProgress: progress))
                let executionDuration: Double

                switch config.mode {
                case .voiceCombos:
                    let combo = generateCombo(config: config)
                    currentComboDisplay = combo.map { $0.replacingOccurrences(of: "!", with: "").uppercased() }.joined(separator: "  →  ")
                    strikesCuedCount += combo.count
                    executionDuration = scheduleVoiceCombo(tokens: combo)

                case .cadenceBeep:
                    let pattern = Bool.random() ? [true, true, true, false, false] : [true, true, false]
                    currentComboDisplay = pattern.map { $0 ? "PUNCH" : "KICK" }.joined(separator: " • ")
                    strikesCuedCount += pattern.count
                    executionDuration = scheduleCadenceBeeps(isPunchPattern: pattern)

                case .hybrid:
                    let combo = generateCombo(config: config)
                    currentComboDisplay = combo.map { $0.replacingOccurrences(of: "!", with: "").uppercased() }.joined(separator: "  →  ")
                    strikesCuedCount += combo.count
                    if let hi = beepHighBuffer {
                        playerNode.scheduleBuffer(hi, at: nil, options: [], completionHandler: nil)
                    }
                    executionDuration = scheduleVoiceCombo(tokens: combo)
                }

                let remainingPause = max(1.1, targetCycleSeconds - executionDuration)
                try? await Task.sleep(nanoseconds: UInt64(remainingPause * 1_000_000_000))
            }
        }
    }

    func stopBagCoachLoop() {
        bagTimerTask?.cancel()
        bagTimerTask = nil
        currentComboDisplay = ""
    }

    private func generateCombo(config: BagCoachConfig) -> [String] {
        var combo: [String] = []
        let length = Int.random(in: 2...4)

        if Double.random(in: 0...1) < 0.75 {
            combo.append("Jab!")
        } else {
            combo.append(punchTokens.randomElement() ?? "Jab!")
        }

        while combo.count < length {
            let roll = Double.random(in: 0...1)
            if config.includeDefense && roll < 0.16 && combo.count >= 2 {
                combo.append(defenseTokens.randomElement() ?? "Slip!")
            } else if config.includeKneesElbows && roll < 0.32 {
                combo.append(closeRangeTokens.randomElement() ?? "Right knee!")
            } else if config.includeKicks && roll < 0.56 {
                combo.append(kickTokens.randomElement() ?? "Right middle kick!")
            } else {
                let last = combo.last ?? ""
                if last.contains("Jab") {
                    combo.append(["Cross!", "Right hook!", "Right uppercut!"].randomElement()!)
                } else if last.contains("Cross") {
                    combo.append(["Left hook!", "Left uppercut!", "Body jab!"].randomElement()!)
                } else {
                    combo.append(punchTokens.randomElement() ?? "Cross!")
                }
            }
        }
        return combo
    }

    private func scheduleVoiceCombo(tokens: [String]) -> Double {
        ensureEngineRunning()
        var totalDuration = 0.0
        for (idx, token) in tokens.enumerated() {
            guard let buf = tokenBuffers[token] else { continue }
            let bufSec = Double(buf.frameLength) / buf.format.sampleRate
            let effectiveSec = max(0.24, bufSec * 0.78)
            playerNode.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
            totalDuration += effectiveSec
            if idx < tokens.count - 1 {
                totalDuration += 0.06
            }
        }
        return totalDuration
    }

    private func scheduleCadenceBeeps(isPunchPattern: [Bool]) -> Double {
        ensureEngineRunning()
        var elapsed = 0.0
        Task {
            for (idx, isPunch) in isPunchPattern.enumerated() {
                if let buf = isPunch ? beepHighBuffer : beepLowBuffer {
                    playerNode.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
                }
                if idx < isPunchPattern.count - 1 {
                    let gap: UInt64 = isPunch ? 240_000_000 : 380_000_000
                    try? await Task.sleep(nanoseconds: gap)
                }
            }
        }
        for isPunch in isPunchPattern {
            elapsed += isPunch ? 0.24 : 0.38
        }
        return elapsed
    }

    func announceCoachingCue(_ message: String, enabled: Bool) {
        guard enabled else { return }
        announcementQueue.append(message)
        processNextAnnouncement()
    }

    private func processNextAnnouncement() {
        guard !isSpeakingDynamic, !announcementQueue.isEmpty else { return }
        isSpeakingDynamic = true
        let next = announcementQueue.removeFirst()

        Task {
            ensureEngineRunning()
            if let buf = await renderSpeechToPCMBuffer(text: next, rate: 0.53) {
                let dur = Double(buf.frameLength) / buf.format.sampleRate
                playerNode.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
                try? await Task.sleep(nanoseconds: UInt64((dur + 0.15) * 1_000_000_000))
            }
            isSpeakingDynamic = false
            processNextAnnouncement()
        }
    }
}
