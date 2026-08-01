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

public final class SpeechTranscriber: @unchecked Sendable {
    /// Called with each finalized utterance. Delivered on the main queue
    /// (SFSpeechRecognizer's default handler queue).
    public var onFinal: ((String) -> Void)?
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

    public init(locale: Locale = Locale(identifier: "en-US")) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable
        else {
            throw SpeechEngineError(message:
                "Speech recognition is unavailable for English. Enable Dictation "
                + "once (System Settings → Keyboard → Dictation) to download the "
                + "on-device model, then try again.")
        }
        self.recognizer = recognizer
        onDevice = recognizer.supportsOnDeviceRecognition
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
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
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
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                lastPartial = ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    consecutiveEmptyRestarts += 1
                } else {
                    consecutiveEmptyRestarts = 0
                    onFinal?(text)
                }
                restart()
                return
            }
            lastPartial = text
        }
        if error != nil {
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
