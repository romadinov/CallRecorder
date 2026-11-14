import AVFoundation
import Foundation
import ObjCCatch
import Observation

/// Records a call: the microphone (you), plus the call app's own audio (everyone else) through a process tap. Both are
/// written as they arrive, as ADTS AAC: every frame carries its own header, so a file cut off by a crash still plays up
/// to the last frame (an .m4a writes its index on close and is unreadable if the app dies). When the call ends the two
/// parts are mixed into one .m4a in the recordings folder.
@MainActor @Observable
final class CallRecorder {
    static let shared = CallRecorder()

    enum State: Equatable { case idle, recording(Date), failed(String) }
    private(set) var state: State = .idle
    var isRecording: Bool { if case .recording = state { return true }; return false }
    private(set) var title: String?
    private(set) var lastSaved: URL?

    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var file: AVAudioFile?
    private var systemTap: SystemAudioTap?
    private var parts: URL?

    func toggle() { isRecording ? stop() : start(meeting: MeetingDetector.shared.activeMeeting()) }

    /// Starts recording the microphone, plus the audio of `meeting`'s app (the other participants) when there is one.
    func start(meeting: MeetingDetector.Detected? = nil) {
        guard !isRecording else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .failed("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone.")
                return
            }
            do { try begin(meeting: meeting) } catch { state = .failed("Couldn't start recording: \(error.localizedDescription)"); teardown() }
        }
    }

    private func begin(meeting: MeetingDetector.Detected?) throws {
        let started = Date()
        let name = "\(Self.stamp.string(from: started)) \(meeting?.appName ?? "Recording")"
        let dir = Settings.partsFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Record from the microphone the call uses (e.g. AirPods), not just the Mac's default input.
        if let device = meeting?.inputDevice, let unit = engine.inputNode.audioUnit {
            var dev = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        file = try AVAudioFile(forWriting: dir.appendingPathComponent("mic.aac"), settings: Audio.fileSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        // A call starting is often when AirPods switch to call mode: the microphone may not be usable for a moment.
        // The recording starts anyway (the call audio goes on) and the microphone is retried.
        do { try startMic() } catch {
            NSLog("CallRecorder: microphone not ready (%@); retrying", error.localizedDescription)
            retryMic()
        }
        // AirPods connecting or switching to call mode reconfigures the engine (and stops it): pick up the new input format
        // and carry on writing to the same file.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in
                let r = CallRecorder.shared
                guard r.isRecording else { return }
                do { try r.startMic() } catch {
                    NSLog("CallRecorder: microphone lost after a device change (%@); retrying", error.localizedDescription)
                    r.retryMic()
                }
            }
        }
        if let meeting {
            // If System Audio Recording isn't allowed, the microphone recording still goes on.
            let tap = SystemAudioTap()
            do { try tap.start(processes: meeting.processIDs, writingTo: dir.appendingPathComponent("call.aac")); systemTap = tap }
            catch { NSLog("CallRecorder: call audio not recorded: %@", error.localizedDescription) }
        }
        parts = dir
        title = meeting.map { "\($0.appName) call" } ?? "Recording"
        state = .recording(started)
    }

    private func startMic() throws {
        try installMicTap()
        try catchingObjCExceptions { engine.prepare() }
        try engine.start()
    }

    private var micRetry: Task<Void, Never>?

    /// Tries the microphone again every second for 20 s (a Bluetooth mode switch takes a few seconds), unless a
    /// configuration change gets there first.
    private func retryMic() {
        micRetry?.cancel()
        micRetry = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isRecording else { return }
                if self.engine.isRunning { return }
                do { try self.startMic(); NSLog("CallRecorder: microphone recording again"); return } catch {}
            }
            NSLog("CallRecorder: microphone still unavailable; recording the call audio only")
        }
    }

    /// Converts whatever the input delivers (48 kHz built-in mic, 16/24 kHz AirPods in call mode) to mono at `Audio.rate`.
    /// The tap uses the hardware's format: the node's output format can still describe the previous mode while AirPods
    /// switch, and AVAudioEngine rejects a tap that doesn't match the hardware (with an exception, caught here).
    private func installMicTap() throws {
        guard let out = file else { return }
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.sampleRate, channels: hw.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: Audio.mono) else { throw RecorderError.format }
        try catchingObjCExceptions {
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
                let cap = AVAudioFrameCount(Double(buffer.frameLength) * Audio.rate / inFormat.sampleRate + 32)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: Audio.mono, frameCapacity: cap) else { return }
                var fed = false
                converter.convert(to: pcm, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buffer
                }
                try? out.write(from: pcm)
            }
        }
    }

    /// Stops, then mixes the parts into one file in the background.
    func stop() {
        guard isRecording, let dir = parts else { return }
        teardown()
        parts = nil
        title = nil
        state = .idle
        Task { lastSaved = await Mixer.finish(dir) }
    }

    private func teardown() {
        micRetry?.cancel()
        micRetry = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        systemTap?.stop()
        systemTap = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil  // closes the file
    }

    /// Recordings left unmixed (the app crashed, or the Mac restarted mid-call): what was saved is mixed now.
    func finishOrphans() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Settings.partsFolder, includingPropertiesForKeys: nil)) ?? []
        Task { for dir in dirs where dir.hasDirectoryPath { _ = await Mixer.finish(dir) } }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    enum RecorderError: LocalizedError {
        case format
        var errorDescription: String? { "The microphone's audio format isn't supported" }
    }
}

/// The recording format: mono AAC, good for speech and about 20 MB an hour.
enum Audio {
    static let rate: Double = 24000
    static let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    static let fileSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                              AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000]
}

/// Mixes a recording's parts (mic.aac, call.aac) into "<name>.m4a" next to the parts folder, then removes the parts.
enum Mixer {
    static func finish(_ dir: URL) async -> URL? {
        let out = Settings.folder.appendingPathComponent(dir.lastPathComponent).appendingPathExtension("m4a")
        do {
            try await mix([dir.appendingPathComponent("mic.aac"), dir.appendingPathComponent("call.aac")], to: out)
            try? FileManager.default.removeItem(at: dir)
            return out
        } catch {
            NSLog("CallRecorder: couldn't mix %@ (%@); the parts are kept", dir.path, error.localizedDescription)
            return nil
        }
    }

    static func mix(_ inputs: [URL], to out: URL) async throws {
        let composition = AVMutableComposition()
        for url in inputs where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        guard !composition.tracks.isEmpty,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw MixError.nothing }
        try? FileManager.default.removeItem(at: out)
        try await export.export(to: out, as: .m4a)
    }

    enum MixError: LocalizedError {
        case nothing
        var errorDescription: String? { "Nothing was recorded" }
    }
}

/// Runs `body`, turning an Objective-C exception into a thrown error (AVAudioEngine's `installTap` and `prepare` raise them).
func catchingObjCExceptions(_ body: () -> Void) throws {
    var failure: NSError?
    guard CRCatchException(body, &failure) else { throw failure ?? NSError(domain: "ObjCException", code: 0) }
}
