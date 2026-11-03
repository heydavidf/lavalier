import AppKit
import AVFoundation
import ApplicationServices

enum PermissionStatus: Equatable {
    case granted, denied, notDetermined

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .notDetermined: return "Not asked yet"
        }
    }
}

enum Permission: CaseIterable {
    case microphone, accessibility, inputMonitoring

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var why: String {
        switch self {
        case .microphone: return "To hear you while the key is held. Audio goes to ElevenLabs and is not stored."
        case .accessibility: return "To watch the push-to-talk key and to insert text into the app you are using."
        case .inputMonitoring: return "Needed when a shortcut is a keyboard key or a mouse button, or if macOS asks for it to see the key."
        }
    }

    /// Microphone and Accessibility are always required. Input Monitoring only if the event tap needs it.
    var required: Bool { self != .inputMonitoring }

    var status: PermissionStatus {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .denied
        }
    }

    /// Triggers the system prompt where macOS offers one.
    func request(completion: @escaping @Sendable () -> Void) {
        switch self {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: completion) }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: completion)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: completion)
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    static var missingRequired: [Permission] {
        allCases.filter { $0.required && $0.status != .granted }
    }
}
