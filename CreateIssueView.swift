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
    var showDependencies: Bool = true

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
                    formField("Dependencies") {
                        TextField("discovered-from:bd-20, blocks:bd-15", text: $fields.dependencies).textFieldStyle(.roundedBorder)
                    }
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

    @State private var isSubmitting    = false
    @State private var createdIssueID: String? = nil
    @State private var errorMessage:   String? = nil
    @State private var showCopied      = false
    @State private var showDraftBanner = false

    private var canSubmit: Bool {
        !draftManager.fields.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !workingDirectory.isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet title bar
            HStack {
                Text("New Issue").font(.headline)
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
            ScrollView { IssueFormContent(fields: $draftManager.fields).padding() }
            Divider()
            bottomBar
        }
        .frame(width: max(520, preferredWidth), height: max(560, preferredHeight - 100))
        .onAppear {
            if draftManager.hasDraft() {
                showDraftBanner = true
            }
        }
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
    }

    private func clearForm() { clearFormFields(); createdIssueID = nil }

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
                    workingDirectory: dir)
                DispatchQueue.main.async {
                    isSubmitting = false
                    createdIssueID = id
                    clearFormFields()
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
