import AVFoundation
import Speech
import SwiftUI

@MainActor
final class WiqoSpeechRecorder: NSObject, ObservableObject {
    enum StartResult {
        case started
        /// The user tapped Don't Allow (this time, or on a previous launch). iOS never shows its
        /// own permission dialog a second time once a decision is recorded, so the only way
        /// forward is Settings - the caller shows that path explicitly instead of silently
        /// re-attempting a request that's guaranteed to fail the same way again.
        case permissionDenied
        /// The selected locale cannot be constructed at all. The normal unsupported-on-device
        /// case uses Apple's own recognizer as a controlled network fallback below.
        case speechUnavailable
        /// The device can use Apple's recognizer, but not its on-device model for this locale.
        /// This is deliberately not the Groq/server audio path.
        case startedWithNetworkFallback
        /// Permission is fine; something about configuring the audio session/recorder itself
        /// failed (e.g. another app holding exclusive audio hardware access).
        case setupFailed
    }

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastErrorMessage: String?
    /// How loud the person is speaking right now, 0...1, smoothed (quick to rise, slow to fall); drives the listening orb.
    @Published private(set) var level: Float = 0

    private let speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var audioSessionIsActive = false
    private var isFinishing = false

    override init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
        super.init()
    }

    func start() async -> StartResult {
        // Checked before ever calling requestRecordPermission: iOS only shows its native prompt
        // once per app install, on the FIRST ever call while status is .undetermined - calling it
        // again after a .denied decision just resolves immediately with `false` and shows nothing,
        // which used to read as "the app never even asks". Requesting only when genuinely
        // undetermined is what makes the system prompt appear automatically exactly once, and
        // lets a real prior denial be told apart from "never asked yet".
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            return .permissionDenied
        case .undetermined:
            // AVAudioApplication's native async overload handles its arbitrary callback queue
            // without inheriting this recorder's MainActor isolation.
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { return .permissionDenied }
        case .granted:
            break
        @unknown default:
            return .permissionDenied
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            // isAvailable (not just the locale existing) is what actually reflects whether a
            // recognition task can run right now - false here almost always means Siri/Dictation
            // is off system-wide (Settings > Siri & Search, or no network and no on-device model
            // ready), and no amount of retrying the request will change that.
            return .speechUnavailable
        }
        // supportsOnDeviceRecognition reports the DEVICE CLASS's general capability, not whether
        // this specific language's on-device model is actually downloaded and ready right now -
        // forcing requiresOnDeviceRecognition based on it alone (as this used to) disables
        // SFSpeechRecognizer's own automatic network fallback, so an unready-but-"supported"
        // on-device model fails outright instead of transparently using the network path. Leaving
        // the request's default (false) lets the framework pick on-device when it's truly ready
        // and fall back to network itself - this is what actually made recognition fail before.
        let usesOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition

        switch await requestSpeechAuthorization() {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            return .permissionDenied
        @unknown default:
            return .permissionDenied
        }

        transcript = ""
        lastErrorMessage = nil
        isFinishing = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            // setActive(_:) is synchronous and can block for the duration of an audio route
            // negotiation (e.g. a Bluetooth headset) - AVFoundation's own runtime warning flags
            // calling it on the main thread ("can lead to UI unresponsiveness"). Off-loading it to
            // a detached task keeps the actual system call off the main thread while `start()`
            // (already async) still correctly waits for it before installing the tap/starting the
            // engine below, which need the session already active.
            try await Task.detached(priority: .userInitiated) {
                try AVAudioSession.sharedInstance().setActive(true)
            }.value
            audioSessionIsActive = true

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                cleanupCapture()
                return .setupFailed
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Deliberately NOT forced to usesOnDeviceRecognition - see the comment above where
            // that capability is read. Leaving this false lets SFSpeechRecognizer choose on-device
            // when it's actually ready and fall back to network transparently, instead of a hard
            // failure when the capability check said "yes" but the model wasn't ready yet.
            audioEngine = engine
            recognitionRequest = request
            isRecording = true

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let didFail = error != nil
                Task { @MainActor [weak self] in
                    self?.handleRecognitionUpdate(text: text, isFinal: isFinal, didFail: didFail)
                }
            }

            // The tap block runs on AVAudioEngine's own realtime audio thread, never on the main
            // actor - a closure literal written directly here would still lexically inherit this
            // method's @MainActor isolation under Swift 6 strict concurrency, so the compiler
            // attaches a dynamic executor check to it. AVAudioEngine then invokes it from the
            // realtime thread, the check finds it's NOT running on the main actor's queue, and
            // Swift traps with dispatch_assert_queue_fail (EXC_BREAKPOINT) on the very first audio
            // buffer - exactly the "says Dinliyorum then gets stuck" crash this fixes. Building
            // the block in a `nonisolated` factory instead means the closure is lexically declared
            // in a context with no actor isolation to inherit, so no such check is attached.
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: Self.makeTapBlock(for: request, meter: WiqoLevelMeter(recorder: self)))
            inputTapInstalled = true
            engine.prepare()
            try engine.start()
            return usesOnDeviceRecognition ? .started : .startedWithNetworkFallback
        } catch {
            cleanupCapture()
            return .setupFailed
        }
    }

    func stop() async -> String {
        guard isRecording else { return normalizedTranscript }

        isFinishing = true
        audioEngine?.stop()
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        recognitionRequest?.endAudio()

        // The last partial result arrives asynchronously after endAudio(). This short, bounded
        // wait keeps the final Turkish word without blocking the main thread or polling forever.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let finalTranscript = normalizedTranscript
        cleanupCapture()
        return finalTranscript
    }

    private var normalizedTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nonisolated` so the closure it returns is declared in a context with no actor to inherit -
    /// see the long comment at the installTap call site for why that's what actually matters here
    /// (isolation is a property of a closure's lexical declaration site, not of what it does
    /// inside). `SFSpeechAudioBufferRecognitionRequest.append(_:)` being called from the realtime
    /// audio thread while the rest of the request's lifecycle runs on the main actor is Apple's
    /// own documented pattern for this API, not a real data race this happens to paper over.
    nonisolated private static func makeTapBlock(for request: SFSpeechAudioBufferRecognitionRequest, meter: WiqoLevelMeter) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            request.append(buffer)
            meter.measure(buffer)
        }
    }

    fileprivate func applyLevel(_ value: Float) {
        guard isRecording else { return }
        // Quick attack, slow release: the orb swells with a word and settles between words.
        level = value > level ? level + (value - level) * 0.55 : level + (value - level) * 0.18
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await WiqoSpeechPermissionBridge.requestSpeechRecognition()
    }

    private func handleRecognitionUpdate(text: String?, isFinal: Bool, didFail: Bool) {
        if let text, !text.isEmpty {
            transcript = text
        }
        guard isRecording else { return }
        if didFail, !isFinishing {
            lastErrorMessage = String(localized: "Konuşma tanıma durdu. Lütfen tekrar dene.")
            cleanupCapture()
        } else if isFinal {
            cleanupCapture()
        }
    }

    private func cleanupCapture() {
        isRecording = false
        level = 0
        isFinishing = false
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        if audioSessionIsActive {
            audioSessionIsActive = false
            // cleanupCapture() itself stays synchronous (called from non-async contexts too, like
            // the recognition task's completion handling) - the deactivate call doesn't need to be
            // awaited by anything here, so it's just moved off the main thread rather than made
            // blocking-async, for the same reason as the activate call in start() above.
            Task.detached(priority: .utility) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

/// Reads the loudness of each audio buffer on the audio thread and hands a 0...1 value to the recorder on the main actor.
/// A plain (non-actor) class on purpose: the tap block that calls it runs off the main actor.
private final class WiqoLevelMeter: @unchecked Sendable {
    private weak var recorder: WiqoSpeechRecorder?
    private var buffers = 0

    @MainActor init(recorder: WiqoSpeechRecorder) { self.recorder = recorder }

    func measure(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        guard buffers % 2 == 0, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        // -50 dB (quiet room) ... -8 dB (loud speech) mapped to 0...1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        let value = min(max((decibels + 50) / 42, 0), 1)
        Task { @MainActor [weak recorder] in recorder?.applyLevel(value) }
    }
}
