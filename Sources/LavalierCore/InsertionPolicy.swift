import Foundation

/// Decides when text must go in by paste only, never through the Accessibility write.
///
/// In web content (browsers, and Chromium or Electron shells such as Slack, Obsidian and the Claude desktop
/// app) a focused field is exposed as AXTextField or AXTextArea, accepts a selected-text write, and then
/// reports its value unchanged. The verification in the inserter reads that as "nothing happened" and pastes
/// as well, which used to give doubled text in browsers. Paste alone is reliable everywhere.
public enum InsertionPolicy {
    /// Role of the web content root that WebKit and Chromium expose above every web text field.
    public static let webContentRole = "AXWebArea"

    /// Apps whose text fields are web content. Checked by bundle identifier because the role walk can fail
    /// when an app answers Accessibility queries slowly.
    public static let pasteOnlyBundleIDs: Set<String> = [
        // Browsers
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "org.chromium.Chromium",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.kagi.kagimacOS", "ai.perplexity.comet",
        // Chromium and Electron apps
        "com.tinyspeck.slackmacgap", "md.obsidian", "com.anthropic.claudefordesktop", "com.openai.chat",
        "com.hnc.Discord", "com.microsoft.teams2", "notion.id", "com.figma.Desktop", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "com.linear", "com.spotify.client", "com.electron.whatsapp", "net.whatsapp.WhatsApp",
    ]

    /// Nil when the Accessibility write may be tried; otherwise the reason paste is used.
    public static func pasteOnlyReason(bundleID: String?, ancestorRoles: [String]) -> String? {
        if let id = bundleID, pasteOnlyBundleIDs.contains(id) {
            return "web app \(id)"
        }
        if ancestorRoles.contains(webContentRole) {
            return "web content (\(webContentRole) above the field)"
        }
        return nil
    }
}
