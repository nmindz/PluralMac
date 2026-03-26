//
//  TrampolineBundleBuilder.swift
//  PluralMac
//

import Foundation
import AppKit
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

        // Use custom icon if set, otherwise copy from original app
        if let customPath = instance.customIconPath,
           fm.fileExists(atPath: customPath.path) {
            copyCustomIcon(from: customPath, to: resourcesPath)
        } else {
            copyIcon(from: application, to: resourcesPath)
        }

        // Ad-hoc code sign
        try codesign(bundlePath)

        // Register with Launch Services so macOS recognizes the trampoline
        // as a distinct app (separate Dock icon, name, identity)
        LaunchServicesHelper.register(bundlePath)

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
        // Run as child process (not exec) so the trampoline remains the
        // registered app with macOS. This keeps the Dock icon, name, and
        // network identity associated with the trampoline bundle.
        """
        #!/bin/bash
        "\(executablePath.path)" "$@" &
        wait $!
        """
    }

    private static func copyCustomIcon(from sourcePath: URL, to resourcesPath: URL) {
        let destPath = resourcesPath.appendingPathComponent("AppIcon.icns")

        // If the source is already .icns, copy directly
        if sourcePath.pathExtension.lowercased() == "icns" {
            try? fm.copyItem(at: sourcePath, to: destPath)
            return
        }

        // Convert PNG/other image to ICNS via iconutil
        guard let image = NSImage(contentsOf: sourcePath) else { return }
        let tempIconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
        try? fm.createDirectory(at: tempIconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempIconset) }

        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]

        for (name, size) in sizes {
            let resized = NSImage(size: NSSize(width: size, height: size))
            resized.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            resized.unlockFocus()

            if let tiff = resized.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: tempIconset.appendingPathComponent("\(name).png"))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", "-o", destPath.path, tempIconset.path]
        try? process.run()
        process.waitUntilExit()
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
