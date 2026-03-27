//
//  AppInstance.swift
//  PluralMac
//
//  Created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation

/// How the instance is launched relative to the original app.
enum LaunchMethod: String, Codable, Sendable, CaseIterable {
    /// Launch the original app directly (with createsNewApplicationInstance)
    case direct
    /// Pass --no-singleton to bypass Electron's single-instance lock
    case noSingleton
    /// Create a minimal wrapper .app that exec's the original binary
    case trampolineBundle
    /// Copy the entire .app bundle with a unique CFBundleIdentifier
    case fullClone

    var label: String {
        switch self {
        case .direct: return "Direct Launch"
        case .noSingleton: return "No-Singleton Flag"
        case .trampolineBundle: return "Isolated Bundle"
        case .fullClone: return "Full App Clone"
        }
    }

    var description: String {
        switch self {
        case .direct:
            return "Launches the original app directly. Simplest, but may conflict with the original when both run."
        case .noSingleton:
            return "Passes --no-singleton to bypass the app's single-instance lock. Custom Dock icon not available."
        case .trampolineBundle:
            return "Creates a lightweight wrapper app. May have issues with some Electron apps under Rosetta."
        case .fullClone:
            return "Copies the entire app with a unique identity. Best isolation for Electron apps like Claude Desktop."
        }
    }

    /// Whether this method requires a bundle at shortcutPath
    var requiresBundle: Bool {
        self == .trampolineBundle || self == .fullClone
    }
}

/// Represents a configured instance of an application with isolated data storage.
/// Each instance can have its own environment variables, command-line arguments,
/// custom icon, and data directory.
struct AppInstance: Identifiable, Codable, Hashable, Sendable {
    
    // MARK: - Properties
    
    /// Unique identifier for this instance
    let id: UUID
    
    /// User-defined display name for this instance
    var name: String
    
    /// Bundle identifier of the target application
    let targetBundleIdentifier: String
    
    /// Path to the original target application
    let targetAppPath: URL
    
    /// Type of the target application (for data isolation strategy)
    let targetAppType: AppType
    
    /// Path to the created shortcut bundle
    /// `~/Library/PluralMac/Instances/{name}.app`
    var shortcutPath: URL
    
    /// Path to the isolated data directory for this instance
    /// `~/Library/PluralMac/Data/{id}/`
    var dataPath: URL
    
    /// Custom environment variables for this instance
    var environmentVariables: [String: String]
    
    /// Custom command-line arguments for this instance
    var commandLineArguments: [String]
    
    /// Path to custom icon (nil = use original app icon)
    var customIconPath: URL?
    
    /// Data isolation method override (nil = use default for app type)
    var isolationMethodOverride: DataIsolationMethod?
    
    /// Whether to erase data when the shortcut quits (for labs/education)
    var eraseDataOnQuit: Bool
    
    /// Whether to show a menu bar icon when running
    var showMenuBarIcon: Bool
    
    /// Optional notes/description for this instance
    var notes: String?

    /// How this instance is launched relative to the original app.
    var launchMethod: LaunchMethod

    /// Whether to pass --user-data-dir to redirect app data to PluralMac's data directory.
    /// Independent of launch method — can be combined with any method.
    var useUserDataDir: Bool

    /// Whether the clone bundle should be patched (bundle ID, name, icon, re-signed).
    /// Default false — preserves original signature for apps that validate it.
    /// When true, enables custom Dock icon and unique bundle identity.
    var patchCloneBundle: Bool

    /// Version of the original app at clone time (for detecting updates).
    var originalAppVersion: String?

    /// Whether this instance was created with data migrated from the primary app
    var migratedFromPrimary: Bool
    
    /// Creation date
    let createdAt: Date
    
    /// Last modification date
    var modifiedAt: Date
    
    /// Last launch date (nil if never launched)
    var lastLaunchedAt: Date?
    
    // MARK: - Initialization
    
    /// Create a new app instance configuration
    /// - Parameters:
    ///   - name: Display name for the instance
    ///   - application: The target application to create an instance of
    ///   - baseDirectory: Base directory for PluralMac data (default: ~/Library/PluralMac)
    init(
        name: String,
        application: Application,
        baseDirectory: URL = Self.defaultBaseDirectory
    ) {
        self.id = UUID()
        self.name = name
        self.targetBundleIdentifier = application.bundleIdentifier
        self.targetAppPath = application.path
        self.targetAppType = application.appType
        
        // Generate paths
        let sanitizedName = Self.sanitizeFileName(name)
        self.shortcutPath = baseDirectory
            .appendingPathComponent("Instances")
            .appendingPathComponent("\(sanitizedName).app")
        
        self.dataPath = baseDirectory
            .appendingPathComponent("Data")
            .appendingPathComponent(id.uuidString)
        
        // Defaults
        self.environmentVariables = [:]
        self.commandLineArguments = []
        self.customIconPath = nil
        self.isolationMethodOverride = nil
        self.eraseDataOnQuit = false
        self.showMenuBarIcon = false
        self.notes = nil
        self.launchMethod = .direct
        self.useUserDataDir = false
        self.patchCloneBundle = false
        self.originalAppVersion = nil
        self.migratedFromPrimary = false

        // Timestamps
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.lastLaunchedAt = nil
    }
    
    // MARK: - Computed Properties
    
    /// The effective data isolation method (override or default for app type)
    var effectiveIsolationMethod: DataIsolationMethod {
        isolationMethodOverride ?? targetAppType.isolationMethod
    }
    
    /// Check if the shortcut bundle exists
    var shortcutExists: Bool {
        FileManager.default.fileExists(atPath: shortcutPath.path)
    }
    
    /// Check if the data directory exists
    var dataDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: dataPath.path)
    }
    
    /// Environment variable names that must never be set by user-provided config.
    /// These could alter process loading, library resolution, or escalate privilege.
    private static let deniedEnvironmentVariablePrefixes = ["DYLD_", "LD_", "CFNETWORK_"]
    private static let deniedEnvironmentVariableNames: Set<String> = [
        "PATH", "SHELL", "USER", "LOGNAME", "TMPDIR",
        "NSUnbufferedIO", "COMMAND_MODE", "TERM_PROGRAM",
    ]

    /// Get the complete environment variables including HOME override if needed
    var effectiveEnvironmentVariables: [String: String] {
        var env = environmentVariables.filter { key, _ in
            let isDeniedPrefix = Self.deniedEnvironmentVariablePrefixes.contains { key.hasPrefix($0) }
            let isDeniedName = Self.deniedEnvironmentVariableNames.contains(key)
            return !isDeniedPrefix && !isDeniedName
        }

        // Full clones should NEVER redirect HOME — they need access to
        // the real ~/Library/Keychains for safeStorage/Keychain access.
        // --user-data-dir handles data isolation without HOME redirection.
        let needsHomeRedirection = launchMethod != .fullClone
        if needsHomeRedirection {
            env["HOME"] = dataPath.path
            env["XDG_CONFIG_HOME"] = dataPath.appendingPathComponent(".config").path
            env["XDG_DATA_HOME"] = dataPath.appendingPathComponent(".local/share").path
            env["XDG_CACHE_HOME"] = dataPath.appendingPathComponent(".cache").path
        }

        return env
    }
    
    /// Get the complete command-line arguments including data isolation args
    var effectiveCommandLineArguments: [String] {
        var args = commandLineArguments

        // Inject --no-singleton when that launch method is selected
        if launchMethod == .noSingleton && !args.contains("--no-singleton") {
            args.append("--no-singleton")
        }

        // Check for app-specific arguments first
        let bundleId = targetBundleIdentifier.lowercased()

        if bundleId.contains("spotify") {
            args.append("--mu=\(id.uuidString)")
            return args
        }

        if bundleId.contains("discord") {
            args.append("--multi-instance")
            return args
        }

        if bundleId.contains("slack") {
            if useUserDataDir {
                args.append("--user-data-dir=\(dataPath.path)")
            }
            return args
        }

        // Explicit --user-data-dir toggle (independent of launch method)
        if useUserDataDir {
            args.append("--user-data-dir=\(dataPath.path)")
            // Use file-based password store so each instance has independent
            // Chromium credential storage (not shared via macOS Keychain).
            if targetAppType == .electron || targetAppType == .toDesktop {
                if !args.contains("--password-store=basic") {
                    args.append("--password-store=basic")
                }
            }
            return args
        }

        // Default behavior based on isolation method (for non-clone, non-explicit methods)
        if launchMethod == .direct {
            switch effectiveIsolationMethod {
            case .userDataDir:
                args.append("--user-data-dir=\(dataPath.path)")
            case .profileArgument:
                args.append(contentsOf: ["-profile", dataPath.path])
            case .homeRedirection, .none:
                break
            }
        }

        return args
    }
    
    /// Default base directory for PluralMac data
    static var defaultBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("PluralMac")
    }
    
    // MARK: - Methods
    
    /// Update the modification timestamp
    mutating func touch() {
        modifiedAt = Date()
    }
    
    /// Record that the instance was launched
    mutating func recordLaunch() {
        lastLaunchedAt = Date()
        touch()
    }
    
    /// Rename the instance (updates name and shortcut path)
    mutating func rename(to newName: String, baseDirectory: URL = Self.defaultBaseDirectory) {
        name = newName
        let sanitizedName = Self.sanitizeFileName(newName)
        shortcutPath = baseDirectory
            .appendingPathComponent("Instances")
            .appendingPathComponent("\(sanitizedName).app")
        touch()
    }
    
    /// Set a custom environment variable
    mutating func setEnvironmentVariable(_ key: String, value: String) {
        environmentVariables[key] = value
        touch()
    }
    
    /// Remove an environment variable
    mutating func removeEnvironmentVariable(_ key: String) {
        environmentVariables.removeValue(forKey: key)
        touch()
    }
    
    /// Add a command-line argument
    mutating func addArgument(_ argument: String) {
        if !commandLineArguments.contains(argument) {
            commandLineArguments.append(argument)
            touch()
        }
    }
    
    /// Remove a command-line argument
    mutating func removeArgument(_ argument: String) {
        commandLineArguments.removeAll { $0 == argument }
        touch()
    }
    
    // MARK: - Private Helpers
    
    /// Sanitize a string to be used as a file name
    private static func sanitizeFileName(_ name: String) -> String {
        // Remove/replace characters that are problematic in file names
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure non-empty
        return sanitized.isEmpty ? "Instance" : sanitized
    }
}

// MARK: - Codable Conformance

extension AppInstance {
    enum CodingKeys: String, CodingKey {
        case id, name, targetBundleIdentifier, targetAppPath, targetAppType
        case shortcutPath, dataPath, environmentVariables, commandLineArguments
        case customIconPath, isolationMethodOverride, eraseDataOnQuit, showMenuBarIcon
        case launchMethod, useUserDataDir, patchCloneBundle, originalAppVersion
        case useTrampolineBundle // legacy, read-only for migration
        case migratedFromPrimary, notes, createdAt, modifiedAt, lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        targetBundleIdentifier = try container.decode(String.self, forKey: .targetBundleIdentifier)
        targetAppPath = try container.decode(URL.self, forKey: .targetAppPath)
        targetAppType = try container.decode(AppType.self, forKey: .targetAppType)
        shortcutPath = try container.decode(URL.self, forKey: .shortcutPath)
        dataPath = try container.decode(URL.self, forKey: .dataPath)
        environmentVariables = try container.decode([String: String].self, forKey: .environmentVariables)
        commandLineArguments = try container.decode([String].self, forKey: .commandLineArguments)
        customIconPath = try container.decodeIfPresent(URL.self, forKey: .customIconPath)
        isolationMethodOverride = try container.decodeIfPresent(DataIsolationMethod.self, forKey: .isolationMethodOverride)
        eraseDataOnQuit = try container.decode(Bool.self, forKey: .eraseDataOnQuit)
        showMenuBarIcon = try container.decode(Bool.self, forKey: .showMenuBarIcon)

        // Backward compat: migrate old useTrampolineBundle -> launchMethod
        if let method = try container.decodeIfPresent(LaunchMethod.self, forKey: .launchMethod) {
            launchMethod = method
        } else if let oldTrampoline = try container.decodeIfPresent(Bool.self, forKey: .useTrampolineBundle), oldTrampoline {
            launchMethod = .trampolineBundle
        } else {
            launchMethod = .direct
        }

        useUserDataDir = try container.decodeIfPresent(Bool.self, forKey: .useUserDataDir) ?? false
        patchCloneBundle = try container.decodeIfPresent(Bool.self, forKey: .patchCloneBundle) ?? false
        originalAppVersion = try container.decodeIfPresent(String.self, forKey: .originalAppVersion)
        migratedFromPrimary = try container.decodeIfPresent(Bool.self, forKey: .migratedFromPrimary) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)

        // Migrate --no-singleton from args to launch method
        if launchMethod == .direct && commandLineArguments.contains("--no-singleton") {
            launchMethod = .noSingleton
            commandLineArguments.removeAll { $0 == "--no-singleton" }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(targetBundleIdentifier, forKey: .targetBundleIdentifier)
        try container.encode(targetAppPath, forKey: .targetAppPath)
        try container.encode(targetAppType, forKey: .targetAppType)
        try container.encode(shortcutPath, forKey: .shortcutPath)
        try container.encode(dataPath, forKey: .dataPath)
        try container.encode(environmentVariables, forKey: .environmentVariables)
        try container.encode(commandLineArguments, forKey: .commandLineArguments)
        try container.encodeIfPresent(customIconPath, forKey: .customIconPath)
        try container.encodeIfPresent(isolationMethodOverride, forKey: .isolationMethodOverride)
        try container.encode(eraseDataOnQuit, forKey: .eraseDataOnQuit)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(launchMethod, forKey: .launchMethod)
        try container.encode(useUserDataDir, forKey: .useUserDataDir)
        try container.encode(patchCloneBundle, forKey: .patchCloneBundle)
        try container.encodeIfPresent(originalAppVersion, forKey: .originalAppVersion)
        try container.encode(migratedFromPrimary, forKey: .migratedFromPrimary)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
        // Note: useTrampolineBundle is NOT encoded — it's legacy read-only
    }
}

// MARK: - Display Helpers

extension AppInstance {
    /// Formatted creation date string
    var createdAtFormatted: String {
        Self.dateFormatter.string(from: createdAt)
    }
    
    /// Formatted last launch date string
    var lastLaunchedAtFormatted: String? {
        guard let date = lastLaunchedAt else { return nil }
        return Self.dateFormatter.string(from: date)
    }
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
