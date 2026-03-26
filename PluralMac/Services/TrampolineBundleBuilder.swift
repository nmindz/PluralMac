//
//  TrampolineBundleBuilder.swift
//  PluralMac
//

import Foundation
import OSLog

/// Builds minimal .app trampoline bundles with unique CFBundleIdentifiers.
/// This gives Electron apps a separate process identity so their
/// single-instance lock (requestSingleInstanceLock) doesn't conflict
/// with the original app or other instances.
struct TrampolineBundleBuilder: Sendable {

    private static let logger = Logger(subsystem: "com.mtech.PluralMac", category: "TrampolineBundleBuilder")
    private static let fm = FileManager.default

    /// Build a trampoline .app bundle for an instance.
    /// - Parameters:
    ///   - instance: The app instance (provides shortcutPath, targetAppPath, id)
    ///   - application: The original application (provides executablePath, name, iconFileName)
    static func build(for instance: AppInstance, application: Application) throws {
        let bundlePath = instance.shortcutPath
        let contentsPath = bundlePath.appendingPathComponent("Contents")
        let macOSPath = contentsPath.appendingPathComponent("MacOS")
        let resourcesPath = contentsPath.appendingPathComponent("Resources")

        logger.info("Building trampoline at \(bundlePath.path)")

        // Clean existing bundle
        if fm.fileExists(atPath: bundlePath.path) {
            try fm.removeItem(at: bundlePath)
        }

        // Create directory structure
        try fm.createDirectory(at: macOSPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesPath, withIntermediateDirectories: true)

        // Write Info.plist
        let plist = buildInfoPlist(
            bundleIdentifier: "com.mtech.pluralmac.instance.\(instance.id.uuidString.lowercased())",
            name: instance.name,
            executableName: "launcher"
        )
        let plistPath = contentsPath.appendingPathComponent("Info.plist")
        try plist.write(to: plistPath, atomically: true, encoding: .utf8)

        // Write launcher script
        let script = buildLauncherScript(executablePath: application.executablePath)
        let scriptPath = macOSPath.appendingPathComponent("launcher")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Copy icon from original app if available
        copyIcon(from: application, to: resourcesPath)

        // Ad-hoc code sign
        try codesign(bundlePath)

        logger.info("Trampoline built: \(bundlePath.path)")
    }

    /// Remove a trampoline bundle.
    static func remove(at path: URL) throws {
        if fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
    }

    // MARK: - Private

    private static func buildInfoPlist(bundleIdentifier: String, name: String, executableName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleName</key>
            <string>\(escapeXML(name))</string>
            <key>CFBundleDisplayName</key>
            <string>\(escapeXML(name))</string>
            <key>CFBundleExecutable</key>
            <string>\(executableName)</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>LSUIElement</key>
            <false/>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    /// The launcher script only contains the path to the original executable.
    /// All arguments (including --user-data-dir) and environment variables are
    /// passed by NSWorkspace.OpenConfiguration and forwarded via exec + "$@".
    private static func buildLauncherScript(executablePath: URL) -> String {
        // The executable path is a system path (/Applications/X.app/Contents/MacOS/X)
        // and does not contain user input — safe to embed directly.
        """
        #!/bin/bash
        exec "\(executablePath.path)" "$@"
        """
    }

    private static func copyIcon(from application: Application, to resourcesPath: URL) {
        // Try to find the original app's .icns file
        let bundle = Bundle(url: application.path)
        let iconName = bundle?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleIconName") as? String

        if let iconName = iconName {
            let icnsName = iconName.hasSuffix(".icns") ? iconName : "\(iconName).icns"
            let sourcePath = application.path
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(icnsName)

            if fm.fileExists(atPath: sourcePath.path) {
                let destPath = resourcesPath.appendingPathComponent("AppIcon.icns")
                try? fm.copyItem(at: sourcePath, to: destPath)
            }
        }
    }

    private static func codesign(_ bundlePath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundlePath.path]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            logger.warning("Ad-hoc codesign failed with status \(process.terminationStatus), trampoline may still work unsigned")
        }
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
