import AppKit
import LavalierCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        PersonalDictionary.ensureSeeded()
        controller = DictationController()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
