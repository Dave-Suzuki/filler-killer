// Apple Speech adapter: mic -> on-device recognition -> finalized segments.
// Port of the pattern proven in src/fillerkiller/realtime/listener.py:
//   - on isFinal: emit text, start a fresh recognition request
//   - on error (routine on silence, kAFAssistantErrorDomain 203/1110):
//     commit the last partial as final, restart
//   - the AVAudioEngine tap NEVER stops between restarts; the only loss
//     window is the lock-guarded request swap
// New beyond the prototype: restart backoff after consecutive empty restarts,
// and audio-device-change handling (AirPods connecting mid-meeting).
//
// Entire file is compiled out on platforms without Speech (Linux CI).

#if canImport(Speech) && canImport(AVFoundation)

import AVFoundation
import Foundation
import Speech

public enum SpeechAuth {
    public static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public static func requestMicAuthorization() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public struct SpeechEngineError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// On-device recognition isn't available and the caller hasn't been granted
/// consent to use Apple's servers. The app must ask the user explicitly —
/// the privacy promise is "nothing leaves your Mac" and silent fallback
/// would break it.
public struct OnDeviceUnavailableError: LocalizedError {
    public var errorDescription: String? {
        "On-device speech recognition isn't available yet. Enable Dictation "
            + "once (System Settings → Keyboard → Dictation) to download "
            + "Apple's offline model."
    }

    public init() {}
}

public final class SpeechTranscriber: @unchecked Sendable {
    /// Called with each finalized utterance. Delivered on the main queue
    /// (SFSpeechRecognizer's default handler queue).
    public var onFinal: ((String) -> Void)?
    /// Terse diagnostic events ("audio flowing", "heard: ...", errors,
    /// restarts) delivered on the main queue — shown in the menu so field
    /// failures are debuggable without a debugger.
    public var onEvent: ((String) -> Void)?
    /// Mic input level 0...1, throttled, on the main queue — drives the
    /// "it can hear me" indicator.
    public var onLevel: ((Float) -> Void)?
    public private(set) var onDevice: Bool

    // Bias recognition toward the tokens we count (helps, not verbatim).
    private static let contextualStrings = [
        "um", "uh", "you know", "kind of", "sort of", "i mean", "basically",
    ]

    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastPartial = ""
    private var running = false
    private var consecutiveEmptyRestarts = 0
    private var configObserver: NSObjectProtocol?
    private var audioFlowing = false
    private var restartCount = 0
    private var sawAnyResult = false
    private var bufferCount = 0

    private func emit(_ event: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    /// `allowServer` must reflect an EXPLICIT user consent stored by the app.
    /// Without it, the engine refuses to run when the on-device model is
    /// missing rather than silently sending audio to Apple.
    public init(
        locale: Locale = Locale(identifier: "en-US"),
        allowServer: Bool = false
    ) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable
        else {
            throw SpeechEngineError(message:
                "Speech recognition is unavailable for English on this Mac.")
        }
        self.recognizer = recognizer
        onDevice = recognizer.supportsOnDeviceRecognition
        if !onDevice, !allowServer {
            throw OnDeviceUnavailableError()
        }
    }

    public func start() throws {
        running = true
        installTap()
        startRequest()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            running = false
            throw SpeechEngineError(message:
                "Could not start the microphone: \(error.localizedDescription). "
                + "Check the Microphone permission in System Settings → Privacy & Security.")
        }
        emit("engine running (\(onDevice ? "on-device" : "server") recognition)")
        // Watchdog: report a stall, but NEVER silently change where audio
        // goes — recognition mode is a user decision, not a fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.running, !self.sawAnyResult else { return }
            self.emit(self.audioFlowing
                ? "no recognition after 10s — the speech model may be missing (enable Dictation once in System Settings → Keyboard)"
                : "no audio from the mic after 10s — check the input device in System Settings → Sound")
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    public func stop() {
        running = false
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        let pending = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            onFinal?(lastPartial)
        }
        lastPartial = ""
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let req = request
        let tsk = task
        request = nil
        task = nil
        lock.unlock()
        req?.endAudio()
        tsk?.cancel()
    }

    // MARK: - Internals

    private func installTap() {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0) // never hardcode a sample rate
        // Realtime audio thread: append the buffer, nothing else.
        emit("mic format: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if !self.audioFlowing {
                self.audioFlowing = true
                self.emit("audio flowing from mic")
            }
            self.bufferCount += 1
            if self.bufferCount % 8 == 0, let data = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let n = Int(buffer.frameLength)
                if n > 0 {
                    for i in 0 ..< n { sum += data[i] * data[i] }
                    let rms = (sum / Float(n)).squareRoot()
                    let level = min(1.0, rms * 12)
                    DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
                }
            }
            self.lock.lock()
            let req = self.request
            self.lock.unlock()
            req?.append(buffer)
        }
    }

    private func startRequest() {
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if onDevice {
            newRequest.requiresOnDeviceRecognition = true
        }
        newRequest.contextualStrings = Self.contextualStrings
        lastPartial = ""

        lock.lock()
        request = newRequest
        lock.unlock()

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard running else { return }
        if result != nil {
            sawAnyResult = true
        }
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                lastPartial = ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    consecutiveEmptyRestarts += 1
                } else {
                    consecutiveEmptyRestarts = 0
                    emit("final: …\(text.suffix(36))")
                    onFinal?(text)
                }
                restart()
                return
            }
            if lastPartial.isEmpty, !text.isEmpty {
                emit("hearing you…")
            }
            lastPartial = text
        }
        if let error {
            let ns = error as NSError
            emit("recognizer error \(ns.domain)#\(ns.code): \(ns.localizedDescription.prefix(60))")
            // Routine on silence: commit what we heard, start fresh.
            let pending = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if pending.isEmpty {
                consecutiveEmptyRestarts += 1
            } else {
                consecutiveEmptyRestarts = 0
                onFinal?(lastPartial)
            }
            lastPartial = ""
            restart()
        }
    }

    private func restart() {
        lock.lock()
        let oldTask = task
        request = nil // tap stops feeding the old request immediately
        task = nil
        lock.unlock()
        oldTask?.cancel()
        guard running else { return }
        restartCount += 1
        if restartCount % 5 == 0 {
            emit("recognition restarted ×\(restartCount)")
        }
        if consecutiveEmptyRestarts > 3 {
            // A silent room produces a restart loop; breathe between attempts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.running else { return }
                self.startRequest()
            }
        } else {
            startRequest()
        }
    }

    /// Input device changed mid-session (AirPods connected, etc.): the tap's
    /// format is stale. Commit pending speech, reinstall the tap with the new
    /// format, and restart recognition.
    private func handleConfigurationChange() {
        guard running else { return }
        let pending = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            onFinal?(lastPartial)
            lastPartial = ""
        }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        restart()
    }
}

#endif
