import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// CallRecorder: a menu bar app that records your calls (you and the other participants) into one audio file per call.
@main
struct CallRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var recorder = CallRecorder.shared

    var body: some Scene {
        MenuBarExtra {
            RecorderMenu().environment(recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform.circle")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--mix" { Self.mixAndExit() }
        try? FileManager.default.createDirectory(at: Settings.partsFolder, withIntermediateDirectories: true)
        CallRecorder.shared.finishOrphans()
        Watchdog.start()
        MeetingDetector.shared.start()
        HotKeyCenter.shared.register(id: 1, Shortcut(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")) {
            CallRecorder.shared.toggle()
        }
    }

    /// Quitting (or logging out) mid-call keeps what was recorded: it's mixed at the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        CallRecorder.shared.stop()
    }

    /// `CallRecorder --mix mic.aac call.aac out.m4a`: the mixing step on its own, for testing.
    private static func mixAndExit() {
        let a = CommandLine.arguments
        Task {
            do { try await Mixer.mix([URL(fileURLWithPath: a[2]), URL(fileURLWithPath: a[3])], to: URL(fileURLWithPath: a[4])); exit(0) }
            catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
        }
    }
}

enum Settings {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic, ask, off
        var id: String { rawValue }
        var label: String {
            switch self { case .automatic: "Record automatically"; case .ask: "Ask before recording"; case .off: "Don't watch for calls" }
        }
    }

    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .ask }

    /// ~/Music/Call Recordings: one .m4a per call.
    static var folder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Call Recordings", isDirectory: true)
    }
    /// Calls being recorded (or not mixed yet): mic.aac and call.aac.
    static var partsFolder: URL { folder.appendingPathComponent(".parts", isDirectory: true) }
}

/// A Core Audio call that never returned once froze the recorder's main thread for two days: no calls were noticed or
/// recorded, and nothing said so. If the main thread doesn't answer for 2 minutes (time asleep doesn't count), the app
/// starts a fresh copy of itself and exits; the new one mixes what was recorded.
enum Watchdog {
    static func start() {
        Thread.detachNewThread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 120) == .timedOut {
                    NSLog("CallRecorder: main thread stuck for 2 minutes; restarting")
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relaunch.arguments = ["-c", "sleep 2; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
                    try? relaunch.run()
                    _exit(1)
                }
                Thread.sleep(forTimeInterval: 30)
            }
        }
    }
}

struct RecorderMenu: View {
    @Environment(CallRecorder.self) private var recorder
    @AppStorage("mode") private var mode: Settings.Mode = .ask
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        switch recorder.state {
        case .recording(let started):
            Text("Recording since \(started.formatted(date: .omitted, time: .shortened))")
            if let t = recorder.title { Text(t) }
            Button("Stop Recording") { recorder.stop() }.keyboardShortcut("r", modifiers: [.control, .option])
        case .failed(let m):
            Text(m)
            Button("Record Now") { recorder.toggle() }
        case .idle:
            Text(mode == .off ? "Not watching for calls" : "Watching for calls")
            Button("Record Now") { recorder.toggle() }.keyboardShortcut("r", modifiers: [.control, .option])
        }
        Divider()
        Picker("When a Call Starts", selection: $mode) {
            ForEach(Settings.Mode.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Open at Login", isOn: $openAtLogin)
            .onChange(of: openAtLogin) { _, on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { openAtLogin = SMAppService.mainApp.status == .enabled }
            }
        Button("Show Recordings") {
            try? FileManager.default.createDirectory(at: Settings.folder, withIntermediateDirectories: true)
            if let last = recorder.lastSaved { NSWorkspace.shared.activateFileViewerSelecting([last]) } else { NSWorkspace.shared.open(Settings.folder) }
        }
        Divider()
        Button("Quit CallRecorder") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
