//
//  DataMigrationService.swift
//  PluralMac
//

import Foundation
import AppKit
import OSLog

struct MigrationProgress: Sendable {
    let currentFile: String
    let bytesCompleted: Int64
    let bytesTotal: Int64
    let phase: String
}

enum MigrationError: Error, LocalizedError {
    case sourceNotFound(URL)
    case destinationAlreadyPopulated(URL)
    case copyFailed(URL, Error)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case appStillRunning(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let url):
            return "Source not found: \(url.path)"
        case .destinationAlreadyPopulated(let url):
            return "Destination already contains data: \(url.path)"
        case .copyFailed(let url, let error):
            return "Failed to copy \(url.lastPathComponent): \(error.localizedDescription)"
        case .insufficientDiskSpace(let required, let available):
            let req = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let avail = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough disk space. Required: \(req), Available: \(avail)"
        case .appStillRunning(let name):
            return "\(name) is still running. Please quit it before migrating."
        }
    }
}

actor DataMigrationService {

    static let shared = DataMigrationService()

    private let logger = Logger(subsystem: "com.mtech.PluralMac", category: "DataMigrationService")
    private let fm = FileManager.default

    func migrate(
        sources: [DataSource],
        to instance: AppInstance,
        bundleIdentifier: String,
        appName: String,
        progress: @Sendable (MigrationProgress) -> Void
    ) async throws {
        let existingSources = sources.filter { $0.exists }
        guard !existingSources.isEmpty else { return }

        // Pre-flight checks
        try validatePreFlight(sources: existingSources, bundleIdentifier: bundleIdentifier, appName: appName)

        // Use the app type's default isolation method, NOT effectiveIsolationMethod,
        // because the source data layout matches the primary app's natural behavior.
        let usesUserDataDir = instance.targetAppType.isolationMethod == .userDataDir

        // For --user-data-dir isolation, only the Application Support source matters
        // (its contents go directly into dataPath). Other categories (caches, prefs,
        // saved state) live under ~/Library/ which is only relevant for HOME redirection.
        let applicableSources = usesUserDataDir
            ? existingSources.filter { $0.category == .applicationSupport }
            : existingSources

        let totalBytes = applicableSources.reduce(Int64(0)) { $0 + $1.estimatedSize }
        var completedBytes: Int64 = 0

        // Ensure dataPath exists
        if !fm.fileExists(atPath: instance.dataPath.path) {
            try fm.createDirectory(at: instance.dataPath, withIntermediateDirectories: true)
        }

        for source in applicableSources {
            progress(MigrationProgress(
                currentFile: source.category.displayName,
                bytesCompleted: completedBytes,
                bytesTotal: totalBytes,
                phase: "Copying \(source.category.displayName)…"
            ))

            do {
                if usesUserDataDir && source.category == .applicationSupport {
                    // Copy CONTENTS of Application Support/{name}/ directly into dataPath/
                    try copyDirectoryContents(from: source.path, to: instance.dataPath)
                } else {
                    // HOME redirection: copy into the nested Library path
                    let destination = instance.dataPath.appendingPathComponent(source.destinationRelativePath)

                    let parentDir = destination.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parentDir.path) {
                        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    }

                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }

                    try fm.copyItem(at: source.path, to: destination)
                }
                completedBytes += source.estimatedSize
            } catch {
                logger.error("Migration failed at \(source.path.path): \(error.localizedDescription)")
                throw MigrationError.copyFailed(source.path, error)
            }
        }

        progress(MigrationProgress(
            currentFile: "",
            bytesCompleted: totalBytes,
            bytesTotal: totalBytes,
            phase: "Migration complete"
        ))

        logger.info("Migration completed: \(applicableSources.count) sources, \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
    }

    /// Copy the contents of a directory into a destination directory (not the directory itself).
    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items {
            let destItem = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: destItem.path) {
                try fm.removeItem(at: destItem)
            }
            try fm.copyItem(at: item, to: destItem)
        }
    }

    private func validatePreFlight(
        sources: [DataSource],
        bundleIdentifier: String,
        appName: String
    ) throws {
        // Check app is not running
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
        if running {
            throw MigrationError.appStillRunning(appName)
        }

        // Check disk space
        let totalRequired = sources.reduce(Int64(0)) { $0 + $1.estimatedSize }
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = attrs[.systemFreeSize] as? Int64,
           freeSpace < totalRequired {
            throw MigrationError.insufficientDiskSpace(required: totalRequired, available: freeSpace)
        }
    }
}
