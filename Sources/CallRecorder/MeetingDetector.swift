import AppKit
import AudioToolbox
import Foundation
import Observation
import SwiftUI

/// Notices when a call starts (a call app takes the microphone), records it or asks first, and stops when the call
/// ends. Recording includes the call app's audio, so the other participants are captured cleanly.
@MainActor @Observable
final class MeetingDetector {
    static let shared = MeetingDetector()

    struct App {
        let prefix: String; let name: String; let browser: Bool
        /// WhatsApp, Telegram: often personal, so always asked, never recorded automatically.
        var messenger = false
    }
    static let apps: [App] = [
        App(prefix: "us.zoom.", name: "Zoom", browser: false),
        App(prefix: "com.microsoft.teams", name: "Teams", browser: false),
        App(prefix: "com.cisco.webex", name: "Webex", browser: false),
        App(prefix: "Cisco-Systems.Spark", name: "Webex", browser: false),
        App(prefix: "com.tinyspeck.slackmacgap", name: "Slack", browser: false),
        App(prefix: "com.apple.FaceTime", name: "FaceTime", browser: false),
        App(prefix: "com.apple.avconferenced", name: "FaceTime", browser: false),  // FaceTime's audio runs here
        App(prefix: "net.whatsapp.", name: "WhatsApp", browser: false, messenger: true),
        App(prefix: "desktop.WhatsApp", name: "WhatsApp", browser: false, messenger: true),
        App(prefix: "ru.keepcoder.Telegram", name: "Telegram", browser: false, messenger: true),
        App(prefix: "org.telegram.desktop", name: "Telegram", browser: false, messenger: true),
        App(prefix: "com.google.Chrome", name: "Chrome", browser: true),
        App(prefix: "com.apple.Safari", name: "Safari", browser: true),
        App(prefix: "com.apple.WebKit", name: "Safari", browser: true),
        App(prefix: "company.thebrowser.", name: "Arc", browser: true),
        App(prefix: "com.microsoft.edgemac", name: "Edge", browser: true),
        App(prefix: "org.mozilla.firefox", name: "Firefox", browser: true),
        App(prefix: "com.brave.Browser", name: "Brave", browser: true),
    ]

    struct Detected {
        let appName: String
        let isBrowser: Bool
        let isMessenger: Bool
        /// The microphone the call app uses (AirPods during a call): the recording uses the same one.
        let inputDevice: AudioDeviceID?
        /// The app's audio processes (main app and helpers), tapped for the other participants' voices.
        let processIDs: [AudioObjectID]
        /// The app is both listening and playing: a conversation, not just dictation.
        let twoWay: Bool
    }

    private var timer: Timer?
    private var activeSince: Date?
    private var twoWaySince: Date?
    private var quietSince: Date?
    /// Asked (or declined) for the current call: don't ask again until it ends.
    private var handledCurrentCall = false
    private var autoStarted = false
    private var polling = false

    func start() {
        timer?.invalidate()
        // Hops with a Task rather than MainActor.assumeIsolated: the executor check inside assumeIsolated once crashed
        // the recorder from this timer mid-call.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in MeetingDetector.shared.poll() }
        }
    }

    /// Core Audio is asked off the main thread: each query is a round trip to coreaudiod (tens of milliseconds, longer
    /// when it is busy), which would make the menu stutter.
    private func poll() {
        guard Settings.mode != .off, !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let procs = AudioProcess.all()
            Task { @MainActor in
                MeetingDetector.shared.polling = false
                MeetingDetector.shared.tick(procs)
            }
        }
    }

    /// The call going on right now, if any (also used when you press Record yourself, to include the other participants).
    func activeMeeting(_ procs: [AudioProcess] = AudioProcess.all()) -> Detected? {
        let me = getpid()
        guard let caller = procs.first(where: { $0.isRunningInput && $0.pid != me && Self.app(for: $0.bundleID) != nil }),
              let app = Self.app(for: caller.bundleID) else { return nil }
        let family = procs.filter { $0.bundleID.hasPrefix(app.prefix) && $0.pid != me }
        return Detected(appName: app.name, isBrowser: app.browser, isMessenger: app.messenger, inputDevice: caller.inputDevice,
                        processIDs: family.map(\.objectID), twoWay: family.contains(where: \.isRunningOutput))
    }

    func tick(_ procs: [AudioProcess]) {
        let recorder = CallRecorder.shared
        guard Settings.mode != .off else { return }
        guard let call = activeMeeting(procs) else {
            activeSince = nil
            twoWaySince = nil
            if quietSince == nil { quietSince = Date() }
            // The call ended (no app has used the mic for 30 s): stop what detection started, and be ready for the next call.
            if Date().timeIntervalSince(quietSince!) > 30 {
                handledCurrentCall = false
                if autoStarted && recorder.isRecording { recorder.stop() }
                autoStarted = false
            }
            return
        }
        quietSince = nil
        guard !handledCurrentCall, !recorder.isRecording else { return }
        if call.twoWay { if twoWaySince == nil { twoWaySince = Date() } } else { twoWaySince = nil }
        // Browsers and messengers also use the mic for dictation and voice messages: a call is listening and playing for a
        // while. Call apps count once they've held the mic for 2 s (skips a momentary mic check).
        if call.isBrowser || call.isMessenger {
            guard let since = twoWaySince, Date().timeIntervalSince(since) >= (call.isBrowser ? 15 : 3) else { return }
        } else {
            if activeSince == nil { activeSince = Date() }
            guard Date().timeIntervalSince(activeSince!) >= 2 else { return }
        }
        handledCurrentCall = true
        if Settings.mode == .automatic && !call.isMessenger {
            recorder.start(meeting: call)
            autoStarted = true
            CallPrompt.shared.show(.started(call))
        } else {
            CallPrompt.shared.show(.ask(call)) { [weak self] record in
                guard record, let self else { return }
                recorder.start(meeting: call)
                self.autoStarted = true
            }
        }
    }

    static func app(for bundleID: String) -> App? { apps.first { bundleID.hasPrefix($0.prefix) } }

    /// What to tell the others: recording people without telling them is illegal in many places.
    static let notice = "Heads-up: I'm recording this call for my own notes. Tell me if you'd rather I didn't."
}

// MARK: - Prompt

/// A small floating panel at the top right: "Record this call?" or "Recording", with a notice to share.
@MainActor
final class CallPrompt {
    static let shared = CallPrompt()
    enum Kind { case ask(MeetingDetector.Detected), started(MeetingDetector.Detected) }
    private var panel: NSPanel?
    private var closeTimer: Timer?

    func show(_ kind: Kind, onAnswer: ((Bool) -> Void)? = nil) {
        close()
        let size = NSSize(width: 360, height: 130)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let view = CallPromptView(kind: kind) { [weak self] answer in
            onAnswer?(answer)
            self?.close()
        }
        let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        p.contentViewController = host
        p.setContentSize(size)
        if let f = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - 16)) }
        p.orderFrontRegardless()
        panel = p
        // An unanswered question means "no"; the "recording" note just goes away.
        let seconds: TimeInterval = if case .ask = kind { 120 } else { 20 }
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in onAnswer?(false); CallPrompt.shared.close() }
        }
    }

    func close() {
        closeTimer?.invalidate(); closeTimer = nil
        panel?.close(); panel = nil
    }
}

struct CallPromptView: View {
    let kind: CallPrompt.Kind
    let answer: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isAsk ? "waveform.badge.mic" : "record.circle.fill").foregroundStyle(isAsk ? Color.accentColor : Color.red)
                Text(isAsk ? "Record this call?" : "Recording").font(.headline)
            }
            Text("\(call.appName) call. Includes the other participants' audio.").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Button(copied ? "Copied" : "Copy notice for others") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingDetector.notice, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                .help("Paste it in the call chat so everyone knows they're being recorded")
                Spacer()
                if isAsk {
                    Button("Not this one") { answer(false) }.controlSize(.small)
                    Button("Record") { answer(true) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Stop") { CallRecorder.shared.stop(); answer(false) }.controlSize(.small)
                    Button("OK") { answer(false) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(14)
        .padding(.top, 6)
    }

    var isAsk: Bool { if case .ask = kind { return true }; return false }
    var call: MeetingDetector.Detected { switch kind { case .ask(let c), .started(let c): c } }
}
