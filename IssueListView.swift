// IssueListView.swift
// IssueListView, IssueRow, IssueDetailSheet, IssueEditSheet.

import SwiftUI
import AppKit
import WebKit

// MARK: - Search Scope

enum SearchScope: String, CaseIterable {
    case title       = "Title"
    case description = "Description"
    case notes       = "Notes"

    var flag: String {
        switch self {
        case .title:       return "--title-contains"
        case .description: return "--desc-contains"
        case .notes:       return "--notes-contains"
        }
    }
}

// MARK: - Issue List View

struct IssueListView: View {
    let workingDirectory: String
    var refreshTrigger: Int = 0
    @Binding var detailPanelWidth: Double

    @State private var issues:       [BeadsIssue] = []
    @State private var isLoading     = false
    @State private var loadingCount  = 0
    @State private var errorMessage: String? = nil
    @State private var copiedID:     String? = nil
    @State private var detailIssue:  BeadsIssue? = nil
    @State private var editIssue:    BeadsIssue? = nil

    // Persistent state (SceneStorage for per-window persistence across quit/reopen)
    @SceneStorage("expandedIDsJSON") private var expandedIDsJSON: String = "[]"
    @SceneStorage("selectedIDsJSON") private var selectedIDsJSON: String = "[]"
    
    // Selection state: @State intermediary synced with @SceneStorage
    // (needed because List selection binding requires the state to be applied AFTER rows render)
    @State private var selectedIDs: Set<String> = []
    @State private var selectedStatuses:  Set<String> = ["open"]
    @State private var selectedPriorities: Set<String> = ["0", "1", "2", "3", "4"]
    @State private var selectedTypes:      Set<String> = ["bug", "feature", "task", "epic", "chore", "decision"]
    @State private var titleSearch: String = ""
    @State private var searchScope: SearchScope = .title
    @State private var searchDebounceTask: DispatchWorkItem? = nil
    
    // Expanded state: computed property works fine with DisclosureGroup
    private var expandedIDs: Set<String> {
        get { decodeIDSet(expandedIDsJSON) }
        nonmutating set { expandedIDsJSON = encodeIDSet(newValue) }
    }

    private var statusFilterArgs: [String] {
        let all: Set<String> = ["open", "in_progress", "blocked", "deferred", "closed"]
        if selectedStatuses.isEmpty || selectedStatuses == all {
            return ["--all"]
        }
        return ["--status", selectedStatuses.sorted().joined(separator: ",")]
    }

    private var priorityFilterArgs: [String] {
        let all: Set<String> = ["0", "1", "2", "3", "4"]
        if selectedPriorities.isEmpty || selectedPriorities == all { return [] }
        if selectedPriorities.count == 1 {
            return ["--priority", selectedPriorities.first!]
        }
        // Use --priority-min/--priority-max; for non-contiguous selections this is
        // an approximation (bd list does not support multi-value --priority).
        let sorted = selectedPriorities.compactMap { Int($0) }.sorted()
        return ["--priority-min", String(sorted.first!), "--priority-max", String(sorted.last!)]
    }

    private var typeFilterArgs: [String] {
        let allMenuTypes: Set<String> = ["bug", "feature", "task", "epic", "chore", "decision"]
        if selectedTypes.isEmpty || selectedTypes == allMenuTypes { return [] }
        // --type does not support comma-separated; use --exclude-type (which does) with
        // the inverse set of the user's selection.
        let excluded = allMenuTypes.subtracting(selectedTypes)
        return ["--exclude-type", excluded.sorted().joined(separator: ",")]
    }

    private var titleFilterArgs: [String] {
        let q = titleSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return [searchScope.flag, q]
    }

    private var allFilterArgs: [String] {
        statusFilterArgs + priorityFilterArgs + typeFilterArgs + titleFilterArgs
    }

    // Copy details toolbar feedback
    @State private var isCopyingDetails = false
    @State private var showCopied = false

    // Detail panel
    @State private var showDetailPanel = true
    @State private var panelContents: [BeadsIssueDetail] = []
    @State private var panelLoading = false
    @State private var panelLoadingProgress: Int = 0
    @State private var panelError: String? = nil
    @State private var detailLoadTask: Task<Void, Never>? = nil
    @FocusState private var listFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                listToolbar
                Divider()
                filterBar
                Divider()
                listContent
            }
            .frame(minWidth: 200)

            if showDetailPanel {
                // Drag handle
                ZStack {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 16)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newWidth = detailPanelWidth - value.translation.width
                                    detailPanelWidth = max(280, min(1100, newWidth))
                                }
                        )
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() }
                            else { NSCursor.pop() }
                        }
                }
                .frame(width: 16)

                detailPanel
                    .frame(width: CGFloat(detailPanelWidth))
            }
        }
        .task { await loadIssues() }
        .onChange(of: workingDirectory) { newDir in Task { await loadIssues(dir: newDir) } }
        .onChange(of: refreshTrigger) { _ in Task { await loadIssues() } }
        .onChange(of: selectedStatuses)  { _ in Task { await loadIssues() } }
        .onChange(of: searchScope)        { _ in Task { await loadIssues() } }
        .onChange(of: selectedPriorities) { _ in Task { await loadIssues() } }
        .onChange(of: selectedTypes)      { _ in Task { await loadIssues() } }
        .onChange(of: titleSearch) { _ in
            searchDebounceTask?.cancel()
            let work = DispatchWorkItem { Task { await self.loadIssues() } }
            searchDebounceTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        .onChange(of: selectedIDs) { newSelection in
            // Persist selection to SceneStorage
            selectedIDsJSON = encodeIDSet(newSelection)
            
            // Debounced detail panel update
            detailLoadTask?.cancel()
            detailLoadTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
                guard !Task.isCancelled else { return }
                await loadPanelDetails()
            }
        }
        .sheet(item: $detailIssue) { issue in
            IssueDetailSheet(issue: issue, workingDirectory: workingDirectory)
        }
        .sheet(item: $editIssue) { issue in
            let w = NSApp.mainWindow?.frame.size.width ?? NSApp.keyWindow?.frame.size.width ?? 920
            IssueEditSheet(
                issue: issue,
                workingDirectory: workingDirectory,
                preferredWidth: w,
                onSaved: { Task { await loadIssues() } }
            )
        }
    }

    // MARK: - Toolbar

    private var listToolbar: some View {
        HStack {
            if !issues.isEmpty {
                Text("\(issues.count) issue\(issues.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary).font(.subheadline)
            }
            Spacer()

            // Copy feedback
            if isCopyingDetails {
                ProgressView().scaleEffect(0.7).padding(.trailing, 2)
            } else if showCopied {
                Text("Copied!").font(.caption).foregroundStyle(.green)
            }

            Button {
                Task { await copyDetailsAsMarkdown(ids: Array(selectedIDs)) }
            } label: {
                Label("Copy Details", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(selectedIDs.isEmpty || isCopyingDetails)
            .help("Copy details of selected issues as Markdown")

            Button {
                withAnimation { showDetailPanel.toggle() }
            } label: {
                Label(showDetailPanel ? "Hide Details" : "Show Details", systemImage: "sidebar.right")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help(showDetailPanel ? "Hide detail panel" : "Show detail panel")

            Button { Task { await loadIssues() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(isLoading || workingDirectory.isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - List Content

    @ViewBuilder
    private var listContent: some View {
        if workingDirectory.isEmpty {
            emptyState(icon: "folder.badge.questionmark",
                       title: "No Repository Selected",
                       message: "Use the Choose\u{2026} button to select a beads repository.")
        } else if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text(loadingCount > 0 ? "Loading issues\u{2026} (\(loadingCount) found)" : "Loading issues\u{2026}")
                    .foregroundStyle(.secondary).font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Retry") { Task { await loadIssues() } }.buttonStyle(.bordered)
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if issues.isEmpty {
            emptyState(icon: "tray",
                       title: "No Issues",
                       message: "This repository has no open issues.")
        } else {
            List(selection: $selectedIDs) {
                ForEach(issues) { issue in
                    issueRowRecursive(issue)
                }
            }
            .listStyle(.plain)
            .focused($listFocused)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        VStack(spacing: 0) {
            // Panel header bar
            HStack {
                Text("Detail")
                    .font(.subheadline).fontWeight(.semibold)
                if selectedIDs.count > 1 {
                    Text("\(selectedIDs.count)")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()

                if !panelContents.isEmpty && !panelLoading {
                    Button {
                        let markdown = panelContents.map { detailToMarkdown($0) }.joined(separator: "\n\n---\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Copy loaded details as Markdown")
                }
                Button {
                    Task { await loadPanelDetails() }
                } label: {
                    if panelLoading {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(panelLoading || selectedIDs.isEmpty)
                .help("Refresh detail panel")
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)

            Divider()

            if selectedIDs.isEmpty {
                VStack {
                    Text("Select an issue to view details")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if panelLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading... (\(panelLoadingProgress)/\(selectedIDs.count))")
                        .foregroundStyle(.secondary).font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = panelError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28)).foregroundStyle(.orange)
                    Text(err)
                        .foregroundStyle(.secondary).font(.caption)
                        .multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if panelContents.isEmpty {
                // Brief transitional state while debounce fires
                VStack { ProgressView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(panelContents, id: \.id) { detail in
                            IssueDetailCard(detail: detail)
                            if detail.id != panelContents.last?.id {
                                Divider().padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            // N.B. explicit frame height prevents Menu(borderlessButton) from expanding the bar
            StatusFilterMenu(selectedStatuses: $selectedStatuses)
            PriorityFilterMenu(selectedPriorities: $selectedPriorities)
            TypeFilterMenu(selectedTypes: $selectedTypes)
            Spacer()
            HStack(spacing: 0) {
                // Leading separator to visually separate from left-side filter menus
                Rectangle().frame(width: 0.5).foregroundStyle(.separator)

                // Scope picker — label is plain text; borderlessButton adds its own chevron
                Menu {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Button(scope.rawValue) { searchScope = scope }
                    }
                } label: {
                    Text(searchScope.rawValue).font(.subheadline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)

                // Mid separator between scope and search field
                Rectangle().frame(width: 0.5).foregroundStyle(.separator)

                // Search field + clear button
                HStack(spacing: 4) {
                    TextField("Search\u{2026}", text: $titleSearch)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !titleSearch.isEmpty {
                        Button { titleSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 180, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
    }

    // MARK: - Helpers

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyDetailsAsMarkdown(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let issueMap = flatIssues()
        let dir = workingDirectory
        isCopyingDetails = true
        showCopied = false
        var results: [(String, String, String)] = []
        await withTaskGroup(of: (String, String, String)?.self) { group in
            for id in ids {
                let title = issueMap[id]?.title ?? id
                group.addTask {
                    guard let text = try? BeadsRunner.show(id: id, workingDirectory: dir) else { return nil }
                    return (id, title, text)
                }
            }
            for await result in group {
                if let r = result { results.append(r) }
            }
        }
        let ordered = ids.compactMap { id in results.first { $0.0 == id } }
        let markdown = ordered.map { "# \($0.0): \($0.1)\n\($0.2)" }.joined(separator: "\n\n---\n\n")
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            isCopyingDetails = false
            showCopied = true
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await MainActor.run { showCopied = false }
    }

    private func loadPanelDetails() async {
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else {
            await MainActor.run { panelContents = [] }
            return
        }
        await MainActor.run { panelLoading = true; panelLoadingProgress = 0; panelError = nil }
        let dir = workingDirectory
        var results: [(String, BeadsIssueDetail)] = []
        await withTaskGroup(of: (String, BeadsIssueDetail)?.self) { group in
            for id in ids {
                group.addTask {
                    guard let detail = try? BeadsRunner.showDetail(id: id, workingDirectory: dir) else { return nil }
                    return (id, detail)
                }
            }
            for await result in group {
                if let r = result {
                    results.append(r)
                    await MainActor.run { panelLoadingProgress += 1 }
                }
            }
        }
        let ordered = ids.compactMap { id in results.first { $0.0 == id }?.1 }
        await MainActor.run {
            panelContents = ordered
            panelLoading = false
        }
    }

    private func detailToMarkdown(_ detail: BeadsIssueDetail) -> String {
        var parts: [String] = []
        parts.append("# \(detail.id): \(detail.title)")
        parts.append("Status: \(detail.status) \u{00B7} Priority: P\(detail.priority)" +
            (detail.issueType.map { " \u{00B7} \($0)" } ?? ""))
        if let desc = detail.description, !desc.isEmpty { parts.append("## Description\n\(desc)") }
        if let ac = detail.acceptanceCriteria, !ac.isEmpty { parts.append("## Acceptance Criteria\n\(ac)") }
        if let notes = detail.notes, !notes.isEmpty { parts.append("## Notes\n\(notes)") }
        return parts.joined(separator: "\n\n")
    }

    private func flatIssues(_ list: [BeadsIssue]? = nil) -> [String: BeadsIssue] {
        var map: [String: BeadsIssue] = [:]
        func walk(_ items: [BeadsIssue]) {
            for i in items { map[i.id] = i; if let c = i.children { walk(c) } }
        }
        walk(list ?? issues)
        return map
    }

    private func claimIssue(_ issue: BeadsIssue) async {
        let dir = workingDirectory
        do {
            try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.claim(id: issue.id, workingDirectory: dir)
            }.value
            await loadIssues()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeIssue(_ issue: BeadsIssue) async {
        let dir = workingDirectory
        do {
            try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.close(id: issue.id, workingDirectory: dir)
            }.value
            await loadIssues()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadIssues(dir explicitDir: String? = nil) async {
        let dir = explicitDir ?? workingDirectory
        guard !dir.isEmpty else { return }
        isLoading = true; loadingCount = 0; errorMessage = nil
        let (progressStream, bgTask) = BeadsRunner.listWithProgress(workingDirectory: dir, extraArgs: allFilterArgs)
        for await count in progressStream { loadingCount = count }
        do {
            issues = try await bgTask.value
            // Clean up persisted state: remove IDs that no longer exist
            let validIDs = allIssueIDs(in: issues)
            
            // Restore selection from SceneStorage (after issues are loaded)
            let restoredSelection = decodeIDSet(selectedIDsJSON).intersection(validIDs)
            selectedIDs = restoredSelection
            
            // Clean up expanded IDs
            expandedIDs = expandedIDs.intersection(validIDs)
            
            // Persist cleaned selection back to SceneStorage
            selectedIDsJSON = encodeIDSet(selectedIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    // MARK: - Recursive Issue Row Rendering
    
    private func issueRowRecursive(_ issue: BeadsIssue) -> AnyView {
        if let children = issue.children, !children.isEmpty {
            return AnyView(
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedIDs.contains(issue.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedIDs.insert(issue.id)
                            } else {
                                expandedIDs.remove(issue.id)
                            }
                        }
                    )
                ) {
                    ForEach(children) { child in
                        issueRowRecursive(child)
                    }
                } label: {
                    issueRowContent(issue)
                }
            )
        } else {
            return AnyView(issueRowContent(issue))
        }
    }
    
    @ViewBuilder
    private func issueRowContent(_ issue: BeadsIssue) -> some View {
        IssueRow(issue: issue, copiedID: $copiedID,
                 showDetailPanel: showDetailPanel,
                 onEdit: { editIssue = issue },
                 onShowDetail: { detailIssue = issue },
                 onClaim: { Task { await claimIssue(issue) } },
                 onClose: { Task { await closeIssue(issue) } },
                 onCopyDetails: {
                     let ids: [String]
                     if selectedIDs.contains(issue.id) {
                         ids = Array(selectedIDs)
                     } else {
                         ids = [issue.id]
                     }
                     Task { await copyDetailsAsMarkdown(ids: ids) }
                 },
                 onSelect: {
                     let cmdHeld = NSEvent.modifierFlags.contains(.command)
                     if cmdHeld {
                         if selectedIDs.contains(issue.id) {
                             var newSelection = selectedIDs
                             if newSelection.contains(issue.id) {
                                 newSelection.remove(issue.id)
                             } else {
                                 newSelection.insert(issue.id)
                             }
                             selectedIDs = newSelection
                         } else {
                             selectedIDs.remove(issue.id)
                         }
                     } else {
                         selectedIDs = [issue.id]
                     }
                     listFocused = true
                 })
    }
    
    // MARK: - SceneStorage Helpers
    
    private func encodeIDSet(_ set: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(Array(set)),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
    
    private func decodeIDSet(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }
    
    private func allIssueIDs(in list: [BeadsIssue]) -> Set<String> {
        var ids = Set<String>()
        func walk(_ items: [BeadsIssue]) {
            for issue in items {
                ids.insert(issue.id)
                if let children = issue.children {
                    walk(children)
                }
            }
        }
        walk(list)
        return ids
    }
}

// MARK: - Status Filter Menu

private struct StatusFilterMenu: View {
    @Binding var selectedStatuses: Set<String>

    private let statuses: [(value: String, display: String)] = [
        ("open",        "Open"),
        ("in_progress", "In Progress"),
        ("blocked",     "Blocked"),
        ("deferred",    "Deferred"),
        ("closed",      "Closed"),
    ]
    private var allSet: Set<String> { Set(statuses.map(\.value)) }

    private var label: String {
        if selectedStatuses.isEmpty || selectedStatuses == allSet { return "All Statuses" }
        if selectedStatuses.count == 1,
           let name = statuses.first(where: { selectedStatuses.contains($0.value) })?.display {
            return name
        }
        return "\(selectedStatuses.count) Statuses"
    }

    var body: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { selectedStatuses.isEmpty || selectedStatuses == allSet },
                set: { on in if on { selectedStatuses = allSet } }
            )) {
                Text("All Statuses")
            }
            Divider()
            ForEach(statuses, id: \.value) { item in
                Toggle(isOn: Binding(
                    get: { selectedStatuses.contains(item.value) },
                    set: { on in
                        if on { selectedStatuses.insert(item.value) }
                        else  { selectedStatuses.remove(item.value) }
                    }
                )) {
                    Text(item.display)
                }
            }
        } label: {
            Label(label, systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.regular)
    }
}

// MARK: - Priority Filter Menu

private struct PriorityFilterMenu: View {
    @Binding var selectedPriorities: Set<String>

    private let priorities: [(value: String, display: String)] = [
        ("0", "P0 \u{2014} Critical"),
        ("1", "P1 \u{2014} High"),
        ("2", "P2 \u{2014} Normal"),
        ("3", "P3 \u{2014} Low"),
        ("4", "P4 \u{2014} Trivial"),
    ]
    private var allSet: Set<String> { Set(priorities.map(\.value)) }

    private var label: String {
        if selectedPriorities.isEmpty || selectedPriorities == allSet { return "Priority" }
        if selectedPriorities.count == 1 { return "P" + selectedPriorities.first! }
        let sorted = selectedPriorities.compactMap { Int($0) }.sorted()
        let isContiguous = !sorted.isEmpty && sorted.last! - sorted.first! + 1 == sorted.count
        if isContiguous { return "P\(sorted.first!)\u{2013}P\(sorted.last!)" }
        return "\(selectedPriorities.count) Priorities"
    }

    var body: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { selectedPriorities.isEmpty || selectedPriorities == allSet },
                set: { on in if on { selectedPriorities = allSet } }
            )) {
                Text("All Priorities")
            }
            Divider()
            ForEach(priorities, id: \.value) { item in
                Toggle(isOn: Binding(
                    get: { selectedPriorities.contains(item.value) },
                    set: { on in
                        if on { selectedPriorities.insert(item.value) }
                        else  { selectedPriorities.remove(item.value) }
                    }
                )) {
                    Text(item.display)
                }
            }
        } label: {
            Label(label, systemImage: "flag")
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.regular)
    }
}

// MARK: - Type Filter Menu

private struct TypeFilterMenu: View {
    @Binding var selectedTypes: Set<String>

    private let types: [(value: String, display: String)] = [
        ("bug",      "Bug"),
        ("feature",  "Feature"),
        ("task",     "Task"),
        ("epic",     "Epic"),
        ("chore",    "Chore"),
        ("decision", "Decision"),
    ]
    private var allSet: Set<String> { Set(types.map(\.value)) }

    private var label: String {
        if selectedTypes.isEmpty || selectedTypes == allSet { return "Type" }
        if selectedTypes.count == 1,
           let name = types.first(where: { selectedTypes.contains($0.value) })?.display {
            return name
        }
        return "\(selectedTypes.count) Types"
    }

    var body: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { selectedTypes.isEmpty || selectedTypes == allSet },
                set: { on in if on { selectedTypes = allSet } }
            )) {
                Text("All Types")
            }
            Divider()
            ForEach(types, id: \.value) { item in
                Toggle(isOn: Binding(
                    get: { selectedTypes.contains(item.value) },
                    set: { on in
                        if on { selectedTypes.insert(item.value) }
                        else  { selectedTypes.remove(item.value) }
                    }
                )) {
                    Text(item.display)
                }
            }
        } label: {
            Label(label, systemImage: "tag")
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.regular)
    }
}

// MARK: - Issue Detail Card (rich panel renderer)

struct IssueDetailCard: View {
    let detail: BeadsIssueDetail
    @State private var isHoveringID = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: ID + title
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text(detail.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if isHoveringID {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(detail.id, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Copy issue ID")
                        }
                    }
                    .onHover { inside in isHoveringID = inside }
                    statusBadge
                    priorityBadge
                    if let type_ = detail.issueType {
                        Text(type_)
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                    Spacer()
                }
                Text(detail.title)
                    .font(.headline)
                    .textSelection(.enabled)
            }

            // Metadata row
            if detail.owner != nil || detail.assignee != nil || !(detail.labels ?? []).isEmpty {
                HStack(spacing: 12) {
                    if let person = detail.assignee ?? detail.owner {
                        Label(person, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let labels = detail.labels, !labels.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "tag").font(.caption2)
                            Text(labels.joined(separator: ", ")).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // Description
            if let desc = detail.description, !desc.isEmpty {
                MarkdownSection(title: "Description", markdown: desc)
            }

            // Design notes
            if let design = detail.design, !design.isEmpty {
                MarkdownSection(title: "Design", markdown: design)
            }

            // Acceptance Criteria
            if let ac = detail.acceptanceCriteria, !ac.isEmpty {
                MarkdownSection(title: "Acceptance Criteria", markdown: ac)
            }

            // Notes
            if let notes = detail.notes, !notes.isEmpty {
                MarkdownSection(title: "Notes", markdown: notes)
            }

            // Parent
            let parent = detail.dependencies?.first(where: { $0.dependencyType == "parent-child" })
            if let parent {
                RelationSection(title: "Parent", items: [parent], symbol: "arrow.up")
            }

            // Blocks (things this issue blocks — in dependents)
            let blocks = detail.dependents?.filter { $0.dependencyType == "blocks" } ?? []
            if !blocks.isEmpty {
                RelationSection(title: "Blocks", items: blocks, symbol: "arrow.backward")
            }

            // Children (parent-child dependents)
            let children = detail.dependents?.filter { $0.dependencyType == "parent-child" } ?? []
            if !children.isEmpty {
                RelationSection(title: "Children", items: children, symbol: "arrow.down")
            }

            // Other dependencies (non-parent upstream)
            let otherDeps = detail.dependencies?.filter { $0.dependencyType != "parent-child" } ?? []
            if !otherDeps.isEmpty {
                RelationSection(title: "Dependencies", items: otherDeps, symbol: "link")
            }

            // Comments
            if let comments = detail.comments, !comments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Comments")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(comment.author).font(.caption).fontWeight(.medium)
                                Spacer()
                                Text(comment.createdAt).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(comment.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBadge: some View {
        let (symbol, color): (String, Color) = {
            switch detail.status {
            case "open":        return ("\u{25CB}", .primary)
            case "in_progress": return ("\u{25D0}", .blue)
            case "closed":      return ("\u{2713}", .green)
            case "deferred":    return ("\u{2744}", .purple)
            default:            return ("\u{25CF}", .orange)
            }
        }()
        return Text(symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var priorityBadge: some View {
        let color: Color = {
            switch detail.priority {
            case 0: return .red
            case 1: return .orange
            case 2: return .blue
            case 3: return .teal
            default: return .secondary
            }
        }()
        return Text("P\(detail.priority)")
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

struct MarkdownSection: View {
    let title: String
    let markdown: String
    @State private var renderedHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            MarkdownWebView(markdown: markdown, height: $renderedHeight)
                .frame(height: renderedHeight)
        }
    }
}

// MARK: - Markdown Web Renderer

/// WKWebView subclass that forwards scroll events to the parent ScrollView
/// instead of consuming them, so the SwiftUI ScrollView stays in control.
class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> NonScrollingWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        let webView = NonScrollingWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: NonScrollingWebView, context: Context) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.loadHTMLString(markdownHTML(markdown, dark: isDark), baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var height: CGFloat
        init(height: Binding<CGFloat>) { _height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                if let h = result as? CGFloat {
                    DispatchQueue.main.async { self.height = max(20, h) }
                }
            }
        }
    }
}

// MARK: - Markdown → HTML

private func markdownHTML(_ md: String, dark: Bool) -> String {
    """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
  font-size: 13px;
  line-height: 1.55;
  color: \(dark ? "#ddd" : "#222");
  background: transparent;
  padding: 0;
  word-wrap: break-word;
}
p { margin: 0.5em 0; }
h1 { font-size: 1.3em; font-weight: 700; margin: 0.8em 0 0.3em; }
h2 { font-size: 1.1em; font-weight: 600; margin: 0.8em 0 0.3em; }
h3 { font-size: 1.0em; font-weight: 600; margin: 0.6em 0 0.2em; color: \(dark ? "#aaa" : "#555"); }
ul, ol { padding-left: 1.4em; margin: 0.4em 0; }
li { margin: 0.15em 0; }
code {
  font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace;
  font-size: 0.88em;
  background: \(dark ? "#2d2d2d" : "#f0f0f0");
  padding: 0.1em 0.3em;
  border-radius: 3px;
}
pre {
  background: \(dark ? "#1e1e1e" : "#f5f5f5");
  border: 1px solid \(dark ? "#3a3a3a" : "#e0e0e0");
  border-radius: 5px;
  padding: 0.7em 0.9em;
  margin: 0.5em 0;
  overflow-x: auto;
  white-space: pre-wrap;
  word-break: break-all;
}
pre code {
  background: none;
  padding: 0;
  border-radius: 0;
  font-size: 0.85em;
  color: \(dark ? "#ccc" : "#333");
}
blockquote {
  border-left: 3px solid \(dark ? "#555" : "#ccc");
  padding-left: 0.8em;
  color: \(dark ? "#999" : "#666");
  margin: 0.4em 0;
}
strong { font-weight: 600; }
em { font-style: italic; }
a { color: \(dark ? "#7ab3f5" : "#0066cc"); text-decoration: none; }
</style>
</head>
<body>\(convertMarkdownToHTML(md))</body>
</html>
"""
}

private func convertMarkdownToHTML(_ md: String) -> String {
    var html = ""
    let lines = md.components(separatedBy: "\n")
    var i = 0
    var inUL = false
    var inOL = false

    func closeLists() {
        if inUL { html += "</ul>\n"; inUL = false }
        if inOL { html += "</ol>\n"; inOL = false }
    }

    while i < lines.count {
        let raw = lines[i]
        let line = raw

        // Fenced code block
        if line.hasPrefix("```") {
            closeLists()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count && !lines[i].hasPrefix("```") {
                codeLines.append(lines[i])
                i += 1
            }
            let escaped = codeLines.joined(separator: "\n")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            html += "<pre><code class=\"language-\(htmlEscape(lang))\">\(escaped)</code></pre>\n"
            i += 1
            continue
        }

        // ATX headings
        if line.hasPrefix("### ") {
            closeLists()
            html += "<h3>\(inlineMarkdown(String(line.dropFirst(4))))</h3>\n"
        } else if line.hasPrefix("## ") {
            closeLists()
            html += "<h2>\(inlineMarkdown(String(line.dropFirst(3))))</h2>\n"
        } else if line.hasPrefix("# ") {
            closeLists()
            html += "<h1>\(inlineMarkdown(String(line.dropFirst(2))))</h1>\n"
        }
        // Unordered list
        else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            if inOL { html += "</ol>\n"; inOL = false }
            if !inUL { html += "<ul>\n"; inUL = true }
            let content = line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line.dropFirst(2))
            html += "<li>\(inlineMarkdown(content))</li>\n"
        }
        // Ordered list
        else if let match = line.range(of: #"^\d+\. "#, options: .regularExpression) {
            if inUL { html += "</ul>\n"; inUL = false }
            if !inOL { html += "<ol>\n"; inOL = true }
            let content = String(line[match.upperBound...])
            html += "<li>\(inlineMarkdown(content))</li>\n"
        }
        // Blockquote
        else if line.hasPrefix("> ") {
            closeLists()
            html += "<blockquote>\(inlineMarkdown(String(line.dropFirst(2))))</blockquote>\n"
        }
        // Blank line
        else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            closeLists()
            html += "<p></p>\n"
        }
        // Regular paragraph line
        else {
            closeLists()
            html += "<p>\(inlineMarkdown(line))</p>\n"
        }

        i += 1
    }
    closeLists()
    return html
}

/// Convert inline markdown within a single line (bold, italic, inline code, links).
private func inlineMarkdown(_ text: String) -> String {
    var s = htmlEscape(text)
    // Inline code (must come before bold/italic to avoid double-processing)
    s = applyPattern(s, pattern: "`([^`]+)`", template: "<code>$1</code>")
    // Bold+italic
    s = applyPattern(s, pattern: "\\*\\*\\*(.+?)\\*\\*\\*", template: "<strong><em>$1</em></strong>")
    // Bold
    s = applyPattern(s, pattern: "\\*\\*(.+?)\\*\\*", template: "<strong>$1</strong>")
    s = applyPattern(s, pattern: "__(.+?)__", template: "<strong>$1</strong>")
    // Italic
    s = applyPattern(s, pattern: "\\*([^*]+)\\*", template: "<em>$1</em>")
    s = applyPattern(s, pattern: "(?<![\\w])_([^_]+)_(?![\\w])", template: "<em>$1</em>")
    // Links
    s = applyPattern(s, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", template: "<a href=\"$2\">$1</a>")
    return s
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

private func applyPattern(_ input: String, pattern: String, template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
}

struct RelationSection: View {
    let title: String
    let items: [BeadsDependency]
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary)
                    Text(item.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(item.title)
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Text("P\(item.priority)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Issue Row

struct IssueRow: View {
    let issue: BeadsIssue
    @Binding var copiedID: String?
    var showDetailPanel: Bool = false
    var onEdit: () -> Void = {}
    var onShowDetail: () -> Void = {}
    var onClaim: () -> Void = {}
    var onClose: () -> Void = {}
    var onCopyDetails: () -> Void = {}
    var onSelect: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text(issue.statusSymbol)
                .foregroundStyle(issue.statusColor)
                .frame(width: 16)

            Text(issue.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)

            priorityBadge(issue.priorityLabel)

            if issue.dependencyCount + issue.dependentCount > 0 {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("\(issue.dependencyCount) dependenc\(issue.dependencyCount == 1 ? "y" : "ies"), \(issue.dependentCount) dependent\(issue.dependentCount == 1 ? "" : "s")")
            }

            Text(issue.title).lineLimit(1)

            Spacer()

            if copiedID == issue.id {
                Text("Copied!").font(.caption).foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
        .onTapGesture {
            if showDetailPanel {
                onSelect()
            } else {
                copyID()
            }
        }
        .contextMenu {
            Button("Edit\u{2026}") { onEdit() }
            Button("View Detail") { onShowDetail() }
            Divider()
            Button("Copy ID") { copyID() }
            Button("Copy Title") { copyTitle() }
            Button("Copy Details as Markdown") { onCopyDetails() }
            Divider()
            Menu("Status") {
                Button("Claim") { onClaim() }
                Divider()
                Button("Close") { onClose() }
            }
        }
        .help(showDetailPanel
            ? "Click to select \u{00B7} Double-click to edit"
            : "Click to copy ID \u{00B7} Double-click to edit")
        .padding(.vertical, 2)
    }

    private func priorityBadge(_ p: String) -> some View {
        let color: Color = {
            switch p {
            case "P0": return .red
            case "P1": return .orange
            case "P2": return .blue
            case "P3": return .teal
            default:   return .secondary
            }
        }()
        return Text(p)
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func copyID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.id, forType: .string)
        withAnimation { copiedID = issue.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedID == issue.id { withAnimation { copiedID = nil } }
        }
    }

    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.title, forType: .string)
    }
}

// MARK: - Issue Detail Sheet

struct IssueDetailSheet: View {
    let issue: BeadsIssue
    let workingDirectory: String

    @Environment(\.dismiss) private var dismiss
    @State private var output    = ""
    @State private var isLoading = true
    @State private var error: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(issue.id)
                    .font(.system(.headline, design: .monospaced))
                Text("\u{2013}")
                Text(issue.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(.bar)
            Divider()
            if isLoading {
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32)).foregroundStyle(.orange)
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(output)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .task { await loadDetail() }
    }

    private func loadDetail() async {
        let dir = workingDirectory
        let id  = issue.id
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.show(id: id, workingDirectory: dir)
            }.value
            output = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Issue Edit Sheet

struct IssueEditSheet: View {
    let issue: BeadsIssue
    let workingDirectory: String
    let preferredWidth: CGFloat
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fields         = IssueFormFields()
    @State private var originalFields = IssueFormFields()   // snapshot at load time
    @State private var isLoading = true
    @State private var isSaving  = false
    @State private var error: String? = nil
    @State private var comments: [BeadsComment] = []
    @State private var dependencies: [BeadsDependency] = []
    @State private var dependents:   [BeadsDependency] = []
    @State private var newCommentText: String = ""
    @State private var isAddingComment = false
    @State private var commentError: String? = nil
    @State private var newDepID: String = ""
    @State private var newDepType: String = "blocks"
    @State private var isAddingDep = false
    @State private var depError: String? = nil

    private var canSave: Bool {
        !fields.title.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(issue.id)
                    .font(.system(.headline, design: .monospaced))
                Text("\u{2013}")
                Text(issue.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
            }
            .padding()
            .background(.bar)
            Divider()

            if isLoading {
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32)).foregroundStyle(.orange)
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Dismiss") { dismiss() }.buttonStyle(.bordered)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        IssueFormContent(fields: $fields, showDependencies: false).padding()

                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            // Children subsection (parent-child dependents, read-only)
                            let children = dependents.filter { $0.dependencyType == "parent-child" }
                            if !children.isEmpty {
                                Text("Children").font(.subheadline).fontWeight(.medium)
                                ForEach(children) { child in
                                    HStack(spacing: 6) {
                                        Text(child.status == "closed" ? "\u{2713}" : child.status == "in_progress" ? "\u{25D0}" : "\u{25CB}")
                                            .font(.caption)
                                            .foregroundStyle(child.status == "closed" ? Color.green : child.status == "in_progress" ? Color.blue : Color.primary)
                                        Text(child.id)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(child.title).font(.subheadline).lineLimit(1)
                                        Spacer()
                                        Text("P\(child.priority)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Divider().padding(.vertical, 4)
                            }

                            Text("Dependencies").font(.subheadline).fontWeight(.medium)

                            if dependencies.isEmpty {
                                Text("No dependencies.").foregroundStyle(.secondary).font(.subheadline)
                            } else {
                                ForEach(dependencies) { dep in
                                    HStack(spacing: 6) {
                                        Text(dep.dependencyType ?? "depends-on")
                                            .font(.caption2).fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.teal, in: Capsule())
                                        Text(dep.id)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(dep.title).font(.subheadline).lineLimit(1)
                                        Spacer()
                                        Text("P\(dep.priority)").font(.caption2).foregroundStyle(.secondary)
                                        Button { Task { await removeDep(dep) } } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove this dependency")
                                    }
                                }
                            }

                            if let err = depError {
                                Text(err).foregroundStyle(.red).font(.caption)
                            }

                            HStack(spacing: 6) {
                                TextField("Issue ID", text: $newDepID)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                                Picker("", selection: $newDepType) {
                                    Text("blocks").tag("blocks")
                                    Text("tracks").tag("tracks")
                                    Text("related").tag("related")
                                    Text("parent-child").tag("parent-child")
                                    Text("discovered-from").tag("discovered-from")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 160)
                                Button(isAddingDep ? "Adding\u{2026}" : "Add") {
                                    Task { await addDep() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(newDepID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingDep)
                            }
                        }
                        .padding(.horizontal).padding(.top, 8)

                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes").font(.subheadline).fontWeight(.medium)
                            formTextArea($fields.notes, placeholder: "Add notes\u{2026}", height: 80)
                            Text("Notes are saved along with other fields when you click Save.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal).padding(.top, 8)

                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Comments").font(.subheadline).fontWeight(.medium)

                            if comments.isEmpty {
                                Text("No comments yet.").foregroundStyle(.secondary).font(.subheadline)
                            } else {
                                ForEach(comments) { comment in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(comment.author).fontWeight(.medium).font(.subheadline)
                                            Spacer()
                                            Text(comment.createdAt).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(comment.text).font(.body).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(8)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            if let err = commentError {
                                Text(err).foregroundStyle(.red).font(.caption)
                            }
                            HStack(alignment: .bottom, spacing: 8) {
                                formTextArea($newCommentText, placeholder: "Add a comment\u{2026}", height: 60)
                                Button(isAddingComment ? "Adding\u{2026}" : "Add") {
                                    Task { await addComment() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 8)
                    }
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if isSaving { ProgressView().scaleEffect(0.75).padding(.trailing, 4) }
                Button("Save") { saveIssue() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: max(520, preferredWidth - 80))
        .frame(minHeight: 540, maxHeight: .infinity)
        .task { await loadDetail() }
    }

    private func loadDetail() async {
        let dir = workingDirectory
        let id  = issue.id
        do {
            let detail = try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.showDetail(id: id, workingDirectory: dir)
            }.value
            fields = IssueFormFields.from(detail)
            originalFields = fields
            comments = detail.comments ?? []
            dependencies = detail.dependencies ?? []
            dependents   = detail.dependents   ?? []
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func addComment() async {
        let text = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAddingComment = true
        commentError = nil
        let dir = workingDirectory
        let id = issue.id
        do {
            try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.addComment(id: id, text: text, workingDirectory: dir)
            }.value
            let detail = try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.showDetail(id: id, workingDirectory: dir)
            }.value
            comments = detail.comments ?? []
            newCommentText = ""
        } catch {
            commentError = error.localizedDescription
        }
        isAddingComment = false
    }

    private func addDep() async {
        let depID = newDepID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !depID.isEmpty else { return }
        isAddingDep = true
        depError = nil
        let dir = workingDirectory
        let id = issue.id
        let dtype = newDepType
        do {
            try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.addDependency(issueID: id, depID: depID, type: dtype, workingDirectory: dir)
            }.value
            let detail = try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.showDetail(id: id, workingDirectory: dir)
            }.value
            dependencies = detail.dependencies ?? []
            dependents   = detail.dependents   ?? []
            newDepID = ""
        } catch {
            depError = error.localizedDescription
        }
        isAddingDep = false
    }

    private func removeDep(_ dep: BeadsDependency) async {
        depError = nil
        let dir = workingDirectory
        let id = issue.id
        let depID = dep.id
        do {
            try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.removeDependency(issueID: id, depID: depID, workingDirectory: dir)
            }.value
            let detail = try await Task.detached(priority: .userInitiated) {
                try BeadsRunner.showDetail(id: id, workingDirectory: dir)
            }.value
            dependencies = detail.dependencies ?? []
            dependents   = detail.dependents   ?? []
        } catch {
            depError = error.localizedDescription
        }
    }

    private func saveIssue() {
        guard canSave else { return }
        isSaving = true
        let snap     = fields
        let origSnap = originalFields
        let dir      = workingDirectory
        let id       = issue.id
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BeadsRunner.update(id: id, fields: snap, original: origSnap, workingDirectory: dir)
                DispatchQueue.main.async {
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isSaving = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
