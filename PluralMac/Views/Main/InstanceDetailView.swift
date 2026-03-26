//
//  InstanceDetailView.swift
//  PluralMac
//
//  Created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Detail view showing full information about a selected instance.
struct InstanceDetailView: View {
    
    // MARK: - Properties
    
    let instance: AppInstance
    @Bindable var viewModel: InstanceViewModel
    
    @State private var appIcon: NSImage?
    @State private var isRenaming = false
    @State private var newName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var deleteData = false
    @State private var showExportSheet = false
    @State private var showDuplicateSheet = false
    @State private var duplicateName: String = ""
    @State private var showMigrationSheet = false
    @State private var isExportingData = false
    @State private var exportError: String?
    
    @ObservedObject private var runningManager = RunningInstancesManager.shared
    
    /// Check if this instance is running
    private var isRunning: Bool {
        runningManager.isRunning(instance.id)
    }
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection
                
                Divider()
                
                // Info sections
                targetAppSection
                
                Divider()
                
                dataIsolationSection
                
                if !instance.environmentVariables.isEmpty {
                    Divider()
                    environmentSection
                }
                
                if !instance.commandLineArguments.isEmpty {
                    Divider()
                    argumentsSection
                }
                
                Divider()
                
                timestampsSection
                
                Spacer()
            }
            .padding(24)
        }
        .frame(minWidth: 400)
        .toolbar {
            toolbarContent
        }
        .task {
            await loadIcon()
        }
        .alert("Rename Instance", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    try? await viewModel.renameInstance(instance, to: newName)
                }
            }
        }
        .confirmationDialog(
            "Delete Instance",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Shortcut Only", role: .destructive) {
                Task {
                    try? await viewModel.deleteInstance(instance, deleteData: false)
                }
            }
            Button("Delete Shortcut & Data", role: .destructive) {
                Task {
                    try? await viewModel.deleteInstance(instance, deleteData: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to delete just the shortcut, or also delete all isolated data?")
        }
        .sheet(isPresented: $showMigrationSheet) {
            MigrationSheetView(instance: instance, viewModel: viewModel)
        }
        .alert("Duplicate Instance", isPresented: $showDuplicateSheet) {
            TextField("New Name", text: $duplicateName)
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") {
                Task {
                    try? await viewModel.duplicateInstance(instance, newName: duplicateName)
                }
            }
        } message: {
            Text("Enter a name for the duplicated instance:")
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            // Icon
            Group {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Name and type
            VStack(alignment: .leading, spacing: 4) {
                Text(instance.name)
                    .font(.title)
                    .fontWeight(.semibold)
                
                HStack(spacing: 6) {
                    Image(systemName: instance.targetAppType.compatibilityLevel.symbolName)
                        .foregroundStyle(compatibilityColor)
                    
                    Text(instance.targetAppType.displayName)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            
            Spacer()
            
            // Running status indicator
            if isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.15))
                .clipShape(Capsule())
            }
            
            // Launch or Stop button
            if isRunning {
                HStack(spacing: 8) {
                    // Stop button
                    Button(role: .destructive) {
                        Task {
                            _ = await viewModel.terminateInstance(instance)
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
            } else {
                Button {
                    Task {
                        try? await viewModel.launchInstance(instance)
                    }
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
    
    private var compatibilityColor: Color {
        switch instance.targetAppType.compatibilityLevel {
        case .full: return .green
        case .partial: return .yellow
        case .unsupported: return .red
        }
    }
    
    // MARK: - Target App Section
    
    private var targetAppSection: some View {
        DetailSection(title: "Target Application") {
            DetailRow(label: "Application", value: targetAppName)
            DetailRow(label: "Bundle ID", value: instance.targetBundleIdentifier)
            DetailRow(label: "Path", value: instance.targetAppPath.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.targetAppPath.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        LaunchServicesHelper.revealInFinder(instance.targetAppPath)
                    }
                }
        }
    }
    
    private var targetAppName: String {
        instance.targetAppPath.deletingPathExtension().lastPathComponent
    }
    
    // MARK: - Data Isolation Section
    
    private var dataIsolationSection: some View {
        DetailSection(title: "Data Isolation") {
            DetailRow(label: "Method", value: instance.effectiveIsolationMethod.rawValue.capitalized)
            DetailRow(label: "Data Path", value: instance.dataPath.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.dataPath.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        viewModel.revealDataInFinder(instance)
                    }
                }
            DetailRow(label: "Shortcut Path", value: instance.shortcutPath.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.shortcutPath.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        viewModel.revealInFinder(instance)
                    }
                }
        }
    }
    
    // MARK: - Environment Section
    
    private var environmentSection: some View {
        DetailSection(title: "Environment Variables") {
            ForEach(Array(instance.environmentVariables.keys.sorted()), id: \.self) { key in
                DetailRow(label: key, value: instance.environmentVariables[key] ?? "")
            }
        }
    }
    
    // MARK: - Arguments Section
    
    private var argumentsSection: some View {
        DetailSection(title: "Command Line Arguments") {
            ForEach(instance.commandLineArguments, id: \.self) { arg in
                Text(arg)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Timestamps Section
    
    private var timestampsSection: some View {
        DetailSection(title: "Information") {
            DetailRow(label: "Created", value: instance.createdAtFormatted)
            if let lastLaunched = instance.lastLaunchedAtFormatted {
                DetailRow(label: "Last Launched", value: lastLaunched)
            }
            DetailRow(label: "Instance ID", value: instance.id.uuidString)
                .contextMenu {
                    Button("Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.id.uuidString, forType: .string)
                    }
                }
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.revealInFinder(instance)
                } label: {
                    Label("Show Shortcut in Finder", systemImage: "folder")
                }
                
                Button {
                    viewModel.revealDataInFinder(instance)
                } label: {
                    Label("Show Instance Data in Finder", systemImage: "folder.badge.gearshape")
                }

                if instance.targetAppType == .electron || instance.targetAppType == .toDesktop {
                    Button {
                        revealPrimaryDataInFinder()
                    } label: {
                        Label("Show Primary App Data in Finder", systemImage: "folder.badge.person.crop")
                    }
                }
            } label: {
                Label("Finder", systemImage: "folder")
            }
            .help("Reveal in Finder")
            
            Menu {
                Button {
                    newName = instance.name
                    isRenaming = true
                } label: {
                    Label("Rename...", systemImage: "pencil")
                }
                
                Button {
                    duplicateName = "\(instance.name) Copy"
                    showDuplicateSheet = true
                } label: {
                    Label("Duplicate...", systemImage: "plus.square.on.square")
                }
                
                Divider()
                
                Button {
                    exportInstance()
                } label: {
                    Label("Export...", systemImage: "square.and.arrow.up")
                }

                if instance.targetAppType == .electron || instance.targetAppType == .toDesktop {
                    Divider()

                    Button {
                        showMigrationSheet = true
                    } label: {
                        Label("Migrate Data from Primary…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(isRunning)

                    Button {
                        backupPrimaryAppData()
                    } label: {
                        Label("Backup Primary App Data…", systemImage: "arrow.down.doc")
                    }
                    .disabled(isExportingData)
                }

                Button {
                    exportInstanceData()
                } label: {
                    Label("Export Instance Data…", systemImage: "archivebox")
                }
                .disabled(isExportingData || !instance.dataDirectoryExists)

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete...", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
    
    // MARK: - Actions
    
    private func exportInstance() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(instance.name).pluralmac.json"
        panel.title = "Export Instance"
        panel.message = "Choose a location to export the instance configuration"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                try? await viewModel.exportInstances([instance], to: url)
            }
        }
    }
    
    private func revealPrimaryDataInFinder() {
        guard let app = try? Application(from: instance.targetAppPath),
              let dirName = ElectronDataLocator.resolveApplicationSupportDirName(for: app) else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dirName)
        if FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
        }
    }

    private func backupPrimaryAppData() {
        guard let app = try? Application(from: instance.targetAppPath) else { return }
        let sources = ElectronDataLocator.locateDataSources(for: app)
        guard let mainSource = sources.first(where: { $0.category == .applicationSupport }) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(app.name) - Primary Backup.zip"
        panel.title = "Backup Primary App Data"
        panel.message = "Choose a location to save the backup"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingData = true
        exportError = nil
        Task {
            defer { isExportingData = false }
            do {
                try await zipDirectory(mainSource.path, to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportInstanceData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(instance.name) - Data.zip"
        panel.title = "Export Instance Data"
        panel.message = "Choose a location to save the instance data"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingData = true
        exportError = nil
        Task {
            defer { isExportingData = false }
            do {
                try await zipDirectory(instance.dataPath, to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func zipDirectory(_ source: URL, to destination: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "PluralMac", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create zip archive"])
            }
        }.value
    }

    // MARK: - Icon Loading
    
    @MainActor
    private func loadIcon() async {
        if instance.shortcutExists {
            appIcon = NSWorkspace.shared.icon(forFile: instance.shortcutPath.path)
        } else {
            appIcon = NSWorkspace.shared.icon(forFile: instance.targetAppPath.path)
        }
    }
}

// MARK: - Detail Section

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
            
            Spacer()
        }
        .font(.body)
    }
}

// MARK: - Migration Sheet

struct MigrationSheetView: View {
    let instance: AppInstance
    @Bindable var viewModel: InstanceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [DataSource] = []
    @State private var isDiscovering = true
    @State private var targetAppRunning = false
    @State private var migrationError: String?

    var body: some View {
        NavigationStack {
            Form {
                if isDiscovering {
                    Section {
                        ProgressView("Scanning for app data…")
                            .padding(.vertical, 4)
                    }
                } else if sources.isEmpty {
                    Section {
                        Label("No existing data found for this app.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Data Sources") {
                        ForEach(sources, id: \.path) { source in
                            HStack {
                                Image(systemName: iconForCategory(source.category))
                                    .foregroundStyle(.secondary)
                                Text(source.category.displayName)
                                Spacer()
                                Text(source.formattedSize)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        let totalSize = sources.reduce(Int64(0)) { $0 + $1.estimatedSize }
                        HStack {
                            Text("Total")
                                .fontWeight(.medium)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                                .fontWeight(.medium)
                        }
                    }

                    if targetAppRunning {
                        Section {
                            Label("The app is running. Quit it before migrating.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Quit App") {
                                for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == instance.targetBundleIdentifier {
                                    app.terminate()
                                }
                                Task {
                                    try? await Task.sleep(for: .seconds(1))
                                    targetAppRunning = NSWorkspace.shared.runningApplications.contains {
                                        $0.bundleIdentifier == instance.targetBundleIdentifier
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    } else {
                        Section {
                            Label("Data will be copied, not moved. The original app will not be affected.", systemImage: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if viewModel.isMigrating, let progress = viewModel.migrationProgress {
                        Section("Progress") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(progress.phase)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ProgressView(value: Double(progress.bytesCompleted), total: max(Double(progress.bytesTotal), 1))
                            }
                        }
                    }
                }

                if let error = migrationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 450, minHeight: 300)
            .navigationTitle("Migrate Data")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isMigrating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Migrate") {
                        Task { await performMigration() }
                    }
                    .disabled(sources.isEmpty || targetAppRunning || viewModel.isMigrating)
                }
            }
            .task { await discover() }
        }
    }

    private func discover() async {
        isDiscovering = true
        targetAppRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == instance.targetBundleIdentifier
        }
        let app = try? Application(from: instance.targetAppPath)
        if let app {
            sources = await Task.detached {
                ElectronDataLocator.locateDataSources(for: app)
            }.value
        }
        isDiscovering = false
    }

    private func performMigration() async {
        migrationError = nil
        do {
            try await viewModel.migrateInstance(instance, sources: sources)
            dismiss()
        } catch {
            migrationError = error.localizedDescription
        }
    }

    private func iconForCategory(_ category: DataCategory) -> String {
        switch category {
        case .applicationSupport: return "folder.fill"
        case .caches: return "internaldrive"
        case .preferences: return "gearshape"
        case .savedApplicationState: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Preview

#Preview {
    let mockInstance = AppInstance(
        name: "Chrome Work",
        application: try! Application(from: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    )
    
    return InstanceDetailView(
        instance: mockInstance,
        viewModel: InstanceViewModel()
    )
}
