//
//  ElectronDataLocator.swift
//  PluralMac
//

import Foundation
import OSLog

enum DataCategory: String, Sendable, CaseIterable {
    case applicationSupport
    case caches
    case preferences
    case savedApplicationState

    var displayName: String {
        switch self {
        case .applicationSupport: return "Application Support"
        case .caches: return "Caches"
        case .preferences: return "Preferences"
        case .savedApplicationState: return "Saved Application State"
        }
    }
}

struct DataSource: Sendable {
    let path: URL
    let category: DataCategory
    let estimatedSize: Int64
    let exists: Bool
    let destinationRelativePath: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: estimatedSize, countStyle: .file)
    }
}

struct ElectronDataLocator: Sendable {

    private static let logger = Logger(subsystem: "com.mtech.PluralMac", category: "ElectronDataLocator")
    private static let fm = FileManager.default

    static func locateDataSources(for application: Application) -> [DataSource] {
        let home = fm.homeDirectoryForCurrentUser
        var sources: [DataSource] = []

        guard let dirName = resolveApplicationSupportDirName(for: application) else {
            logger.info("Could not resolve Application Support dir name for \(application.bundleIdentifier)")
            return sources
        }

        logger.info("Resolved Application Support dir name: \(dirName) for \(application.name)")

        // Application Support
        let appSupportPath = home
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dirName)
        sources.append(DataSource(
            path: appSupportPath,
            category: .applicationSupport,
            estimatedSize: directorySize(appSupportPath),
            exists: fm.fileExists(atPath: appSupportPath.path),
            destinationRelativePath: "Library/Application Support/\(dirName)"
        ))

        // Caches
        let cachesPath = home
            .appendingPathComponent("Library/Caches")
            .appendingPathComponent(dirName)
        if fm.fileExists(atPath: cachesPath.path) {
            sources.append(DataSource(
                path: cachesPath,
                category: .caches,
                estimatedSize: directorySize(cachesPath),
                exists: true,
                destinationRelativePath: "Library/Caches/\(dirName)"
            ))
        }

        // Preferences .plist
        let prefsPath = home
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(application.bundleIdentifier).plist")
        if fm.fileExists(atPath: prefsPath.path) {
            let size = (try? fm.attributesOfItem(atPath: prefsPath.path)[.size] as? Int64) ?? 0
            sources.append(DataSource(
                path: prefsPath,
                category: .preferences,
                estimatedSize: size,
                exists: true,
                destinationRelativePath: "Library/Preferences/\(application.bundleIdentifier).plist"
            ))
        }

        // Saved Application State
        let savedStatePath = home
            .appendingPathComponent("Library/Saved Application State")
            .appendingPathComponent("\(application.bundleIdentifier).savedState")
        if fm.fileExists(atPath: savedStatePath.path) {
            sources.append(DataSource(
                path: savedStatePath,
                category: .savedApplicationState,
                estimatedSize: directorySize(savedStatePath),
                exists: true,
                destinationRelativePath: "Library/Saved Application State/\(application.bundleIdentifier).savedState"
            ))
        }

        return sources.filter { $0.exists }
    }

    /// Resolve the Application Support directory name for an app using multiple strategies.
    static func resolveApplicationSupportDirName(for application: Application) -> String? {
        let home = fm.homeDirectoryForCurrentUser
        let appSupportBase = home.appendingPathComponent("Library/Application Support")

        // Strategy 1: Compatibility database hint (synchronous check of known names)
        if let knownName = knownApplicationSupportDirName(for: application.bundleIdentifier) {
            let path = appSupportBase.appendingPathComponent(knownName)
            if fm.fileExists(atPath: path.path) {
                return knownName
            }
        }

        // Strategy 2: CFBundleName from the bundle
        if let bundle = Bundle(url: application.path),
           let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            let path = appSupportBase.appendingPathComponent(bundleName)
            if fm.fileExists(atPath: path.path) && isElectronDataDirectory(path) {
                return bundleName
            }
        }

        // Strategy 3: Display name
        let displayPath = appSupportBase.appendingPathComponent(application.name)
        if fm.fileExists(atPath: displayPath.path) && isElectronDataDirectory(displayPath) {
            return application.name
        }

        // Strategy 4: Bundle identifier last component (e.g., "claudefordesktop" from com.anthropic.claudefordesktop)
        let components = application.bundleIdentifier.components(separatedBy: ".")
        if let lastComponent = components.last {
            let capitalized = lastComponent.prefix(1).uppercased() + lastComponent.dropFirst()
            for candidate in [lastComponent, capitalized] {
                let path = appSupportBase.appendingPathComponent(candidate)
                if fm.fileExists(atPath: path.path) && isElectronDataDirectory(path) {
                    return candidate
                }
            }
        }

        // Strategy 5: Scan Application Support for directories matching bundle ID fragments
        if let contents = try? fm.contentsOfDirectory(atPath: appSupportBase.path) {
            let idFragments = application.bundleIdentifier.lowercased()
                .components(separatedBy: ".")
                .filter { $0.count > 3 }

            for entry in contents {
                let entryLower = entry.lowercased()
                let entryPath = appSupportBase.appendingPathComponent(entry)
                for fragment in idFragments {
                    if entryLower.contains(fragment) && isElectronDataDirectory(entryPath) {
                        return entry
                    }
                }
            }
        }

        return nil
    }

    /// Check if a directory contains Electron app artifacts.
    static func isElectronDataDirectory(_ path: URL) -> Bool {
        let electronMarkers = [
            "Local Storage",
            "Session Storage",
            "Preferences",
            "Cookies",
            "IndexedDB",
            "GPUCache",
        ]

        for marker in electronMarkers {
            let markerPath = path.appendingPathComponent(marker)
            if fm.fileExists(atPath: markerPath.path) {
                return true
            }
        }
        return false
    }

    /// Known Application Support directory names from the compatibility database.
    private static func knownApplicationSupportDirName(for bundleId: String) -> String? {
        let known: [String: String] = [
            "com.tinyspeck.slackmacgap": "Slack",
            "com.hnc.Discord": "discord",
            "com.microsoft.VSCode": "Code",
            "com.todesktop.230313mzl4w4u92": "Cursor",
            "com.spotify.client": "Spotify",
            "com.figma.Desktop": "Figma",
            "notion.id": "Notion",
            "com.linear": "Linear",
            "com.anthropic.claudefordesktop": "Claude",
        ]
        return known[bundleId]
    }

    /// Calculate total size of a directory.
    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               values.isDirectory == false {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
