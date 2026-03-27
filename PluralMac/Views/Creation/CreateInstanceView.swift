//
//  CreateInstanceView.swift
//  PluralMac
//
//  Created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// View for creating a new app instance.
/// Guides the user through selecting an app, naming the instance,
/// and configuring optional settings.
struct CreateInstanceView: View {
    
    // MARK: - Properties
    
    @Bindable var viewModel: InstanceViewModel
    @Environment(\.dismiss) private var dismiss
    
    // Form state
    @State private var selectedAppURL: URL?
    @State private var instanceName: String = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var detectedApp: Application?
    
    // Advanced options
    @State private var showAdvancedOptions = false
    @State private var environmentVariables: [String: String] = [:]
    @State private var commandLineArguments: [String] = []
    @State private var customIconPath: URL?
    @State private var selectedIcon: NSImage?

    // Advanced isolation
    @State private var enableAdvancedIsolation = false
    @State private var advancedIsolationMethod: AdvancedIsolationMethod = .noSingleton

    // Migration
    @State private var migrateFromPrimary = false
    @State private var discoveredSources: [DataSource] = []
    @State private var isDiscoveringSources = false
    @State private var targetAppIsRunning = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            Form {
                // App Selection Section
                appSelectionSection
                
                // Instance Name Section
                if detectedApp != nil {
                    instanceNameSection
                }
                
                // App Info Section
                if let app = detectedApp {
                    appInfoSection(app: app)
                }

                // Advanced Isolation + Migration (Electron/toDesktop only)
                if let app = detectedApp, app.appType == .electron || app.appType == .toDesktop {
                    advancedIsolationSection
                    migrationSection(app: app)
                }

                // Advanced Options
                if detectedApp != nil {
                    advancedOptionsSection
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 500, minHeight: 400)
            .navigationTitle("Create Instance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(viewModel.isMigrating)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createInstance()
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }
    
    // MARK: - App Selection Section
    
    private var appSelectionSection: some View {
        Section {
            HStack {
                if let url = selectedAppURL {
                    // Show selected app
                    HStack(spacing: 12) {
                        appIcon(for: url)
                        
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .fontWeight(.medium)
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    Button("Change") {
                        selectApp()
                    }
                } else {
                    // No app selected
                    Button {
                        selectApp()
                    } label: {
                        HStack {
                            Image(systemName: "plus.app")
                                .font(.title)
                            Text("Select Application")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if let error = validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("Application")
        } footer: {
            Text("Select the macOS application you want to create an instance of.")
        }
    }
    
    // MARK: - Instance Name Section
    
    private var instanceNameSection: some View {
        Section {
            TextField("Instance Name", text: $instanceName, prompt: Text("My Instance"))
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Instance Name")
        } footer: {
            Text("Give your instance a unique name to identify it.")
        }
    }
    
    // MARK: - App Info Section
    
    private func appInfoSection(app: Application) -> some View {
        Section {
            LabeledContent("App Type") {
                HStack {
                    Image(systemName: app.appType.compatibilityLevel.symbolName)
                        .foregroundStyle(compatibilityColor(for: app.appType.compatibilityLevel))
                    Text(app.appType.displayName)
                }
            }
            
            LabeledContent("Data Isolation") {
                Text(app.appType.isolationMethod.rawValue.capitalized)
            }
            
            LabeledContent("Bundle ID") {
                Text(app.bundleIdentifier)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Detected Configuration")
        }
    }
    
    // MARK: - Advanced Options Section
    
    private var advancedOptionsSection: some View {
        Section(isExpanded: $showAdvancedOptions) {
            // Environment Variables
            DisclosureGroup("Environment Variables") {
                environmentVariablesEditor
            }
            
            // Command Line Arguments
            DisclosureGroup("Command Line Arguments") {
                argumentsEditor
            }
            
            // Custom Icon (disabled for No-Singleton — Dock always shows original icon)
            VStack(alignment: .leading, spacing: 8) {
                Text("Instance Icon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if enableAdvancedIsolation && advancedIsolationMethod == .noSingleton {
                    Text("Custom Dock icon is only available with the Isolated Bundle method.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    IconPickerView(
                        selectedIcon: $selectedIcon,
                        customIconPath: $customIconPath,
                        sourceAppURL: selectedAppURL
                    )
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Advanced Options")
        }
    }
    
    // MARK: - Environment Variables Editor
    
    private var environmentVariablesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(environmentVariables.keys.sorted()), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                    Text("=")
                        .foregroundStyle(.secondary)
                    Text(environmentVariables[key] ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        environmentVariables.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Button {
                // TODO: Show add env var sheet
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Arguments Editor
    
    private var argumentsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(commandLineArguments, id: \.self) { arg in
                HStack {
                    Text(arg)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        commandLineArguments.removeAll { $0 == arg }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Button {
                // TODO: Show add argument sheet
            } label: {
                Label("Add Argument", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private func appIcon(for url: URL) -> some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func compatibilityColor(for level: CompatibilityLevel) -> Color {
        switch level {
        case .full: return .green
        case .partial: return .yellow
        case .unsupported: return .red
        }
    }
    
    // MARK: - Advanced Isolation Section

    private var advancedIsolationSection: some View {
        Section {
            Toggle("Enable Advanced Isolation", isOn: $enableAdvancedIsolation)

            if enableAdvancedIsolation {
                Picker("Method", selection: $advancedIsolationMethod) {
                    ForEach(AdvancedIsolationMethod.allCases, id: \.self) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(advancedIsolationMethod.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if advancedIsolationMethod == .noSingleton {
                    Label("Custom Dock icon is not available with No-Singleton. The instance will share the original app's Dock icon.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Advanced Isolation")
        } footer: {
            if !enableAdvancedIsolation {
                Text("Extra methods to ensure that complex processes do not collide at runtime.")
            }
        }
    }

    // MARK: - Data Migration Section

    private func migrationSection(app: Application) -> some View {
        Section {
            Toggle("Migrate data from primary app", isOn: $migrateFromPrimary)
                .onChange(of: migrateFromPrimary) { _, enabled in
                    if enabled {
                        discoverSources(for: app)
                    } else {
                        discoveredSources = []
                    }
                }

            if migrateFromPrimary {
                if isDiscoveringSources {
                    ProgressView("Scanning for app data…")
                        .padding(.vertical, 4)
                } else if discoveredSources.isEmpty {
                    Label("No existing data found for \(app.name).", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discoveredSources, id: \.path) { source in
                        HStack {
                            Image(systemName: iconForCategory(source.category))
                                .foregroundStyle(.secondary)
                            Text(source.category.displayName)
                            Spacer()
                            Text(source.formattedSize)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let totalSize = discoveredSources.reduce(Int64(0)) { $0 + $1.estimatedSize }
                    HStack {
                        Text("Total")
                            .fontWeight(.medium)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                            .fontWeight(.medium)
                    }
                }

                if targetAppIsRunning {
                    Label("\(app.name) is running. Quit it before creating.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Quit \(app.name)") {
                        quitTargetApp(bundleId: app.bundleIdentifier)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if !discoveredSources.isEmpty {
                    Label("Data will be copied, not moved. The original app will not be affected.", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isMigrating, let progress = viewModel.migrationProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(progress.bytesCompleted), total: max(Double(progress.bytesTotal), 1))
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Data Migration")
        } footer: {
            if migrateFromPrimary && !discoveredSources.isEmpty {
                Text("The new instance will start with a copy of \(app.name)'s existing data, including settings and logins.")
            }
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

    private func discoverSources(for app: Application) {
        isDiscoveringSources = true
        targetAppIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleIdentifier
        }
        Task.detached {
            let sources = ElectronDataLocator.locateDataSources(for: app)
            await MainActor.run {
                discoveredSources = sources
                isDiscoveringSources = false
            }
        }
    }

    private func quitTargetApp(bundleId: String) {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleId {
            app.terminate()
        }
        // Re-check after a short delay
        Task {
            try? await Task.sleep(for: .seconds(1))
            targetAppIsRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == bundleId
            }
        }
    }

    // MARK: - Computed Properties

    private var canCreate: Bool {
        guard detectedApp != nil, !instanceName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if viewModel.isMigrating { return false }
        if migrateFromPrimary && targetAppIsRunning { return false }
        return true
    }
    
    // MARK: - Actions
    
    private func selectApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Select"
        panel.message = "Choose an application to create an instance of"
        
        if panel.runModal() == .OK, let url = panel.url {
            selectedAppURL = url
            validateApp(at: url)
        }
    }
    
    private func validateApp(at url: URL) {
        isValidating = true
        validationError = nil
        detectedApp = nil
        
        do {
            let app = try Application(from: url)
            try app.validate()
            
            detectedApp = app
            
            // Auto-generate instance name
            if instanceName.isEmpty {
                instanceName = "\(app.name) Instance"
            }
        } catch {
            validationError = error.localizedDescription
        }
        
        isValidating = false
    }
    
    private func createInstance() async {
        guard let app = detectedApp else { return }

        let trimmedName = instanceName.trimmingCharacters(in: .whitespaces)

        do {
            // Translate advanced isolation choice into the instance flags
            let useTrampoline = enableAdvancedIsolation && advancedIsolationMethod == .trampolineBundle
            var extraArgs = commandLineArguments
            if enableAdvancedIsolation && advancedIsolationMethod == .noSingleton {
                extraArgs.append("--no-singleton")
            }

            try await viewModel.createInstance(
                name: trimmedName,
                application: app,
                environmentVariables: environmentVariables,
                arguments: extraArgs,
                customIconPath: customIconPath,
                useTrampolineBundle: useTrampoline,
                migrateFromPrimary: migrateFromPrimary,
                migrationSources: discoveredSources
            )
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

// MARK: - Advanced Isolation Method

enum AdvancedIsolationMethod: String, CaseIterable {
    case noSingleton
    case trampolineBundle

    var label: String {
        switch self {
        case .noSingleton: return "No-Singleton Flag"
        case .trampolineBundle: return "Isolated Bundle"
        }
    }

    var description: String {
        switch self {
        case .noSingleton:
            return "Passes --no-singleton to bypass the app's single-instance lock. Simpler, but not all Electron apps support this flag."
        case .trampolineBundle:
            return "Creates a wrapper app with a unique identity. Fully isolates the process from the original. Works with all Electron apps."
        }
    }
}

// MARK: - Preview

#Preview {
    CreateInstanceView(viewModel: InstanceViewModel())
}
