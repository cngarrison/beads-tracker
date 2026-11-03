// CreateIssueView.swift
// CreateIssueView, IssueFormContent, and shared form helper free functions.

import SwiftUI
import AppKit

// MARK: - Form Helpers (file-scope, shared by CreateIssueView and IssueEditSheet)

@ViewBuilder
func formField<C: View>(
    _ label: String,
    required: Bool = false,
    @ViewBuilder content: () -> C
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 2) {
            Text(label).font(.subheadline).fontWeight(.medium)
            if required { Text("*").foregroundStyle(.red).font(.subheadline) }
        }
        content()
    }
}

// MARK: - Auto-Resizing Text Area

/// AppKit-backed resize grip. Captures raw mouse events so it is unaffected by
/// the enclosing ScrollView's gesture arbitration (which would cause half-speed
/// dragging if we used SwiftUI DragGesture inside a ScrollView).
private class ResizeHandleNSView: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var minHeight: CGFloat = 40
    var currentHeight: CGFloat = 40
    private var dragStartWindowY: CGFloat = 0
    private var dragStartHeight:  CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        let cx = bounds.midX, cy = bounds.midY
        for offsetX: CGFloat in [-22, 0, 22] {
            NSBezierPath(
                roundedRect: NSRect(x: cx + offsetX - 9, y: cy - 1, width: 18, height: 2),
                xRadius: 1, yRadius: 1
            ).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWindowY = event.locationInWindow.y
        dragStartHeight  = currentHeight
    }

    override func mouseDragged(with event: NSEvent) {
        // AppKit y-axis increases upward; dragging down → y decreases → delta > 0 → taller
        let delta  = dragStartWindowY - event.locationInWindow.y
        let newH   = max(minHeight, dragStartHeight + delta)
        DispatchQueue.main.async { self.onDrag(newH) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: -1, height: 7) }
    override var acceptsFirstResponder: Bool   { false }
}

private struct ResizeHandle: NSViewRepresentable {
    @Binding var height:   CGFloat
    @Binding var isManual: Bool
    let minHeight: CGFloat

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let v        = ResizeHandleNSView()
        v.minHeight  = minHeight
        v.onDrag     = { h in height = h; isManual = true }
        return v
    }

    func updateNSView(_ v: ResizeHandleNSView, context: Context) {
        v.currentHeight = height
        v.minHeight     = minHeight
    }
}

struct AutoResizingTextArea: View {
    @Binding var text: String
    var placeholder:   String
    var minHeight:     CGFloat = 70
    var maxAutoHeight: CGFloat = 220
    @Environment(\.undoManager) private var undoManager

    @State private var height:    CGFloat
    @State private var isManual   = false
    @State private var viewWidth: CGFloat = 500

    init(text: Binding<String>, placeholder: String,
         minHeight: CGFloat = 70, maxAutoHeight: CGFloat = 220) {
        self._text       = text
        self.placeholder = placeholder
        self.minHeight   = minHeight
        self.maxAutoHeight = maxAutoHeight
        self._height     = State(initialValue: minHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .onDisappear { clearStaleUndo(undoManager) }
                    .padding(4)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear    { viewWidth = geo.size.width; autoSize() }
                            .onChange(of: geo.size.width) { viewWidth = $0; autoSize() }
                    })
            }
            .frame(height: height)

            ResizeHandle(height: $height, isManual: $isManual, minHeight: minHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onChange(of: text) { _ in autoSize() }
    }

    /// Measures natural text height via NSString.boundingRect — matches
    /// NSTextView's layout engine far better than a SwiftUI Text mirror.
    private func autoSize() {
        guard !isManual, viewWidth > 0 else { return }
        let font    = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let str     = text.isEmpty ? " " : text
        let maxW    = max(10, viewWidth - 24)   // subtract TextEditor internal insets
        let rect    = (str as NSString).boundingRect(
            with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let natural = ceil(rect.height) + 22    // add top+bottom inset
        height = min(max(minHeight, natural), maxAutoHeight)
    }
}

func formTextArea(
    _ text: Binding<String>,
    placeholder: String,
    height: CGFloat
) -> some View {
    AutoResizingTextArea(text: text, placeholder: placeholder, minHeight: height)
}

// MARK: - Issue Form Content

/// Reusable form body shared by CreateIssueView and IssueEditSheet.
/// Contains all input fields; does NOT include banners, ScrollView, or bottom bar.
struct IssueFormContent: View {
    @Binding var fields: IssueFormFields
    var showDependencies: Bool = true   // Create only: Parent and Dependencies (set with the issue)
    var showNotes: Bool = true          // the edit sheet shows Notes in its own section

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            formField("Title", required: true) {
                TextField("Brief summary of the issue", text: $fields.title)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Description") {
                formTextArea($fields.description,
                             placeholder: "Explain why this issue exists and what needs to be done\u{2026}",
                             height: 80)
            }
            HStack(alignment: .top, spacing: 20) {
                formField("Type") {
                    Picker("", selection: $fields.issueType) {
                        ForEach(IssueType.allCases) { t in Text(t.label).tag(t) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                formField("Priority") {
                    Picker("", selection: $fields.priority) {
                        ForEach(Priority.allCases) { p in Text(p.label).tag(p) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                formField("Assignee") {
                    TextField("username or email", text: $fields.assignee).textFieldStyle(.roundedBorder)
                }
                formField("Labels") {
                    TextField("urgent, backend, needs-review", text: $fields.labels).textFieldStyle(.roundedBorder)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                formField("External Reference") {
                    TextField("gh-123, jira-ABC-456", text: $fields.externalRef).textFieldStyle(.roundedBorder)
                }
                if showDependencies {
                    formField("Parent") {
                        TextField("bd-a3f8 (epic or issue this belongs under)", text: $fields.parent).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if showDependencies {
                formField("Dependencies") {
                    TextField("discovered-from:bd-20, blocks:bd-15", text: $fields.dependencies).textFieldStyle(.roundedBorder)
                }
            }
            formField("Design Notes") {
                formTextArea($fields.designNotes,
                             placeholder: "Describe the technical approach or design details\u{2026}",
                             height: 70)
            }
            formField("Acceptance Criteria") {
                formTextArea($fields.acceptanceCriteria,
                             placeholder: "List the criteria for completion\u{2026}",
                             height: 70)
            }
            if showNotes {
                formField("Notes") {
                    formTextArea($fields.notes, placeholder: "Add notes\u{2026}", height: 70)
                }
            }
        }
    }
}

// MARK: - Create Issue View

struct CreateIssueView: View {
    @Binding var workingDirectory: String
    var preferredWidth: CGFloat = 600
    var preferredHeight: CGFloat = 700

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var draftManager = FormDraftManager.shared
    @AppStorage("replyInitials") private var storedInitials: String = ""

    /// Describe: a plain-words description that Claude turns into a filled-in form.
    /// Form: the fields themselves (the only mode without an API key).
    private enum Mode: String { case describe, form }

    @State private var mode: Mode       = .form
    @State private var hasKey           = AnthropicKeychain.load() != nil
    @State private var isSubmitting    = false
    @State private var createdIssueID: String? = nil
    @State private var errorMessage:   String? = nil
    @State private var showCopied      = false
    @State private var showDraftBanner = false
    @State private var proposeTask: Task<Void, Never>? = nil
    @State private var proposeStarted: Date? = nil
    @State private var filledByClaude  = false
    @State private var duplicates: [DuplicateCandidate] = []
    @State private var droppedIDs: [String] = []

    private var canSubmit: Bool {
        !draftManager.fields.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !workingDirectory.isEmpty && !isSubmitting
    }

    private var canPropose: Bool {
        !draftManager.fields.freeformText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && proposeTask == nil && !isSubmitting
    }

    /// Describe when Claude is available, unless the form already has content (a resumed
    /// draft, or fields left from last time).
    private var startingMode: Mode {
        hasKey && draftManager.fields.title.isEmpty ? .describe : .form
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet title bar
            HStack {
                Text("New Issue").font(.headline)
                Spacer()
                if hasKey {
                    Picker("", selection: $mode) {
                        Text("Describe").tag(Mode.describe)
                        Text("Form").tag(Mode.form)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(proposeTask != nil || isSubmitting)
                    .help("Describe the issue in your own words for Claude to fill in the form, or fill in the form yourself")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isSubmitting)
            }
            .padding()
            .background(.bar)
            Divider()

            if let id  = createdIssueID { successBanner(issueID: id) }
            if showDraftBanner          { draftBanner }
            if let err = errorMessage   { errorBanner(message: err) }
            if mode == .describe {
                describePane
                Divider()
                describeBottomBar
            } else {
                if filledByClaude { filledBanner }
                if !duplicates.isEmpty { duplicatesBanner }
                ScrollView { IssueFormContent(fields: $draftManager.fields).padding() }
                Divider()
                bottomBar
            }
        }
        .frame(width: max(520, preferredWidth), height: max(560, preferredHeight - 100))
        .onAppear {
            mode = startingMode
            if draftManager.hasDraft() {
                showDraftBanner = true
            }
        }
        .onDisappear { proposeTask?.cancel() }
    }

    // MARK: Describe mode

    private var describePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe the issue in your own words: what\u{2019}s wrong or wanted, how urgent it is, "
                 + "and any issues it relates to or follows on from. Claude fills in the form for you "
                 + "to check; nothing is created until you click Create.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AutoResizingTextArea(text: $draftManager.fields.freeformText,
                                 placeholder: "e.g. Quit hangs when an events tail is running. Pretty urgent; "
                                     + "follow-up to the events watcher work.",
                                 minHeight: 160, maxAutoHeight: 400)
                .disabled(proposeTask != nil)
            Text("Sends your description and a list of this project\u{2019}s issues (ids, titles, the "
                 + "start of each description) to the Anthropic API, using the model in Review settings.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var describeBottomBar: some View {
        HStack {
            Button("Clear") { clearForm() }.buttonStyle(.bordered).disabled(proposeTask != nil || isSubmitting)
            Spacer()
            if let started = proposeStarted, proposeTask != nil {
                ProgressView().scaleEffect(0.75)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("Asking Claude\u{2026} \(Int(context.date.timeIntervalSince(started))) s")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Stop") { proposeTask?.cancel() }.buttonStyle(.bordered)
            }
            Button("Fill In Form") { fillInForm() }
                .buttonStyle(.borderedProminent)
                .disabled(!canPropose)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding().background(.bar)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button("Clear") { clearForm() }.buttonStyle(.bordered).disabled(isSubmitting)
            Spacer()
            if isSubmitting { ProgressView().scaleEffect(0.75).padding(.trailing, 4) }
            // Secondary: create and stay open for batch entry
            Button("Create & Add Another") { submitIssue(keepOpen: true) }
                .buttonStyle(.bordered)
                .disabled(!canSubmit)
            // Primary: create and return to list
            Button("Create Issue") { submitIssue(keepOpen: false) }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding().background(.bar)
    }

    // MARK: Banners

    private var filledBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude filled in this form from your description. Check it, then Create.")
                    .fontWeight(.medium)
                if !droppedIDs.isEmpty {
                    Text("Left out issue ids that weren\u{2019}t in the list sent to Claude: \(droppedIDs.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit Description") { mode = .describe }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.purple.opacity(0.08))
    }

    private var duplicatesBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This may already be covered by:", systemImage: "doc.on.doc")
                .fontWeight(.medium).foregroundStyle(.orange)
            ForEach(duplicates) { d in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        (Text(d.id).font(.system(.body, design: .monospaced))
                         + Text(" (\(d.status.replacingOccurrences(of: "_", with: " "))) ").foregroundColor(.secondary)
                         + Text(d.title))
                        if !d.reason.isEmpty {
                            Text(d.reason).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    let linked = dependencyIDs.contains(d.id)
                    Button(linked ? "Linked" : "Link as Related") { addRelated(d.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(linked)
                        .help("Add related:\(d.id) to Dependencies")
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private var draftBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.clock").foregroundStyle(.blue)
            Text("You have an unsaved draft.").fontWeight(.medium)
            Spacer()
            Button("Resume") {
                draftManager.resumeDraft()
                draftManager.clearDraft()
                showDraftBanner = false
                mode = startingMode
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            Button("Discard") {
                draftManager.clearDraft()
                draftManager.clearFields()
                showDraftBanner = false
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.blue.opacity(0.10))
    }

    @ViewBuilder
    private func successBanner(issueID: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            (Text("Created: ").bold()
             + Text(issueID).font(.system(.body, design: .monospaced)))
            Spacer()
            Button(showCopied ? "Copied!" : "Copy ID") { copyToClipboard(issueID) }
                .buttonStyle(.bordered).controlSize(.small)
            Button("Dismiss") { createdIssueID = nil }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
    }

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { errorMessage = nil }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: Actions

    private func clearFormFields() {
        draftManager.clearFields()
        draftManager.clearDraft()
        errorMessage = nil
        showDraftBanner = false
        filledByClaude = false
        duplicates = []
        droppedIDs = []
    }

    private func clearForm() { clearFormFields(); createdIssueID = nil }

    /// Ids already in the Dependencies field ("type:id" or bare id, comma separated).
    private var dependencyIDs: Set<String> {
        Set(draftManager.fields.dependencies.split(separator: ",").compactMap {
            $0.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }

    private func addRelated(_ id: String) {
        let deps = draftManager.fields.dependencies.trimmingCharacters(in: .whitespaces)
        draftManager.fields.dependencies = deps.isEmpty ? "related:\(id)" : deps + ", related:\(id)"
    }

    /// Asks Claude to turn the description into form fields, then shows the form to check.
    private func fillInForm() {
        let text = draftManager.fields.freeformText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let apiKey = AnthropicKeychain.load() else {
            hasKey = false; mode = .form
            errorMessage = "Add an Anthropic API key in Review settings to describe issues in your own words."
            return
        }
        let issues = WorkspaceStoreRegistry.shared.existing(workingDirectory)?.issues ?? []
        let candidates = FreeformCreate.candidates(from: issues, text: text)
        let current = draftManager.fields
        let initials = replyInitials(storedInitials)
        let model = AnthropicReview.model, effort = AnthropicReview.effort, maxTokens = AnthropicReview.maxTokens
        errorMessage = nil
        proposeStarted = Date()
        proposeTask = Task { @MainActor in
            defer { proposeTask = nil }
            do {
                let proposal = try await FreeformCreate.propose(
                    text: text, current: current, candidates: candidates, initials: initials,
                    model: model, effort: effort, maxTokens: maxTokens, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                draftManager.fields = proposal.fields
                duplicates = proposal.duplicates
                droppedIDs = proposal.droppedIDs
                filledByClaude = true
                mode = .form
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopied = false }
    }

    /// Submit the form.
    /// - Parameter keepOpen: `false` → dismiss after success (Create Issue);
    ///                       `true`  → clear form and stay open (Create & Add Another).
    private func submitIssue(keepOpen: Bool) {
        guard !workingDirectory.isEmpty else { errorMessage = "No repository selected."; return }
        isSubmitting = true; errorMessage = nil; createdIssueID = nil
        let snap = draftManager.fields
        let dir  = workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let id = try BeadsRunner.create(
                    title: snap.title, description: snap.description,
                    type: snap.issueType, priority: snap.priority,
                    assignee: snap.assignee, labels: snap.labels,
                    externalRef: snap.externalRef, designNotes: snap.designNotes,
                    acceptanceCriteria: snap.acceptanceCriteria,
                    dependencies: snap.dependencies,
                    notes: snap.notes, parent: snap.parent.trimmingCharacters(in: .whitespaces),
                    workingDirectory: dir)
                DispatchQueue.main.async {
                    isSubmitting = false
                    createdIssueID = id
                    clearFormFields()
                    mode = startingMode
                    if keepOpen {
                        // Stay open: banner shows briefly, form already cleared
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            createdIssueID = nil
                        }
                    } else {
                        // Dismiss after brief success banner
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            dismiss()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { isSubmitting = false; errorMessage = error.localizedDescription }
            }
        }
    }
}
