import SwiftUI
import AppKit

/// A feedback message. Atlas 1.0.1 sent it over SMTP with a password inside the app;
/// here it goes through the user's own Mail app, or the clipboard as a GitHub issue.
struct Feedback: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case bug = "Bug Report", suggestion = "Suggestion", feature = "Feature Request", other = "Other"
        var id: String { rawValue }
    }

    static let recipient = "contact.viniciuslopes@gmail.com"

    var kind: Kind = .bug
    var subject = ""
    var description = ""
    var includeSystemInfo = true

    var isReady: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var systemInfo: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Atlas \(AppInfo.version) (build \(AppInfo.build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    var title: String { "[Atlas \(AppInfo.version)] [\(kind.rawValue)] \(subject.trimmingCharacters(in: .whitespacesAndNewlines))" }

    func body(systemInfo: String = Feedback.systemInfo) -> String {
        var s = "Type: \(kind.rawValue)\n\nDescription:\n\(description.trimmingCharacters(in: .whitespacesAndNewlines))"
        if includeSystemInfo { s += "\n\n---\n\(systemInfo)" }
        return s
    }

    func mailURL(systemInfo: String = Feedback.systemInfo) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = Self.recipient
        c.queryItems = [URLQueryItem(name: "subject", value: title), URLQueryItem(name: "body", value: body(systemInfo: systemInfo))]
        return c.url
    }

    func githubIssue(systemInfo: String = Feedback.systemInfo) -> String {
        var s = "## \(kind.rawValue): \(subject.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        s += description.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeSystemInfo { s += "\n\n---\n_\(systemInfo)_" }
        return s + "\n"
    }
}

struct FeedbackView: View {
    @State private var feedback = Feedback()
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Feedback", subtitle: "Report a bug or suggest something for Atlas")
            if let notice { NoticeBanner(message: notice) { self.notice = nil } }
            Form {
                Picker("Type", selection: $feedback.kind) {
                    ForEach(Feedback.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Subject", text: $feedback.subject, prompt: Text("What is it about?"))
                LabeledRow("Description") {
                    TextEditor(text: $feedback.description)
                        .font(.body)
                        .frame(minHeight: 180)
                }
                Toggle("Include the Atlas and macOS versions", isOn: $feedback.includeSystemInfo)
                if feedback.includeSystemInfo {
                    Text(Feedback.systemInfo).font(.caption).foregroundStyle(.secondary)
                }
            }
            .groupedForm()
            .frame(maxWidth: 720)
            HStack {
                Text("Nothing is sent by Atlas itself: Mail opens with the message ready, or the text is copied for a GitHub issue.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy as GitHub Issue") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(feedback.githubIssue(), forType: .string)
                    notice = "Copied. Paste it into a new issue on GitHub."
                }
                Button("Open in Mail") {
                    if let url = feedback.mailURL(), NSWorkspace.shared.open(url) {
                        notice = "Mail opened with your message. Send it from there."
                    } else {
                        notice = "Couldn't open a mail app. Use Copy as GitHub Issue, or write to \(Feedback.recipient)."
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!feedback.isReady)
            .frame(maxWidth: 720)
            Spacer()
        }
        .padding(24)
    }
}
