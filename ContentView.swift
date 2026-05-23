// ContentView.swift
// App entry point (@main), ContentView, top bar, project picker logic.

import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct BeadsTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Explicitly set regular activation policy so the app appears
        // in the Dock and ⌘-Tab switcher when built outside of Xcode.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Beads Tracker") {
            ContentView()
        }
        .defaultSize(width: 920, height: 780)
    }
}

// MARK: - Content View

struct ContentView: View {
    @SceneStorage("workingDirectory") private var workingDirectory: String = ""
    @SceneStorage("detailPanelWidth") private var detailPanelWidth: Double = 400
    @AppStorage("recentProjects") private var recentProjectsJSON: String = "[]"
    @State private var showingCreateSheet = false
    @State private var issueRefreshTrigger = 0
    @State private var createSheetWidth: CGFloat = 600

    private var windowTitle: String {
        workingDirectory.isEmpty
            ? "Beads Tracker"
            : URL(fileURLWithPath: workingDirectory).lastPathComponent + " \u{2014} Beads"
    }

    private var recentProjects: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentProjectsJSON.utf8))) ?? []
    }

    private func addToRecents(_ path: String) {
        var list = recentProjects
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recentProjectsJSON = (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }

    private func clearRecents() { recentProjectsJSON = "[]" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            IssueListView(workingDirectory: workingDirectory, refreshTrigger: issueRefreshTrigger, detailPanelWidth: $detailPanelWidth)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            if !workingDirectory.isEmpty { addToRecents(workingDirectory) }
        }
        .background(WindowTitleSetter(title: windowTitle))
        .sheet(isPresented: $showingCreateSheet, onDismiss: {
            issueRefreshTrigger += 1
        }) {
            CreateIssueView(workingDirectory: $workingDirectory, preferredWidth: createSheetWidth)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // Left: project-scoped Create action
            Button {
                createSheetWidth = (NSApp.keyWindow?.frame.size.width ?? 680) - 80
                showingCreateSheet = true
            } label: {
                Label("Create", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(workingDirectory.isEmpty)
            .help(workingDirectory.isEmpty ? "Select a repository first" : "Create a new issue")

            Spacer()

            // Right: cross-project controls
            Image(systemName: "folder").foregroundStyle(.secondary)
            projectSelector
            Button("Choose\u{2026}") { pickWorkingDirectory() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var projectSelector: some View {
        let recents = recentProjects
        if recents.isEmpty {
            if workingDirectory.isEmpty {
                Text("No repository selected")
                    .foregroundStyle(.secondary).italic().font(.subheadline)
            } else {
                Text(URL(fileURLWithPath: workingDirectory).lastPathComponent)
                    .font(.subheadline).lineLimit(1)
                    .help(workingDirectory)
            }
        } else {
            Menu {
                ForEach(recents, id: \.self) { path in
                    Button {
                        workingDirectory = path
                    } label: {
                        if path == workingDirectory {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark")
                        } else {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                        }
                    }
                    .help(path)
                }
                Divider()
                Button("Clear Recents") { clearRecents() }
            } label: {
                HStack(spacing: 4) {
                    Text(workingDirectory.isEmpty ? "No repository" :
                         URL(fileURLWithPath: workingDirectory).lastPathComponent)
                        .font(.subheadline)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(workingDirectory)
        }
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Beads Repository"; panel.prompt = "Select"
        if !workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
            addToRecents(url.path)
        }
    }
}

// MARK: - Window Title Setter

/// Sets the NSWindow title reactively from SwiftUI state.
/// Using NSViewRepresentable guarantees we have the correct window reference
/// (NSApp.keyWindow is unreliable during onAppear / scene restore).
struct WindowTitleSetter: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = self.title
        }
    }
}
