//
//  AppCloneBuilder.swift
//  PluralMac
//

import Foundation
import AppKit
import OSLog

/// Clones an entire .app bundle with a unique CFBundleIdentifier and
/// re-signs it with the original entitlements preserved. This gives
/// the clone its own process identity, Dock entry, singleton lock,
/// and foreground scheduling — unlike a trampoline that exec's.
struct AppCloneBuilder: Sendable {

    private static let logger = Logger(subsystem: "com.mtech.PluralMac", category: "AppCloneBuilder")
    private static let fm = FileManager.default

    /// Clone the original app bundle for an instance.
    /// - Parameter patchBundle: When true, modifies Info.plist (bundle ID, name),
    ///   replaces the icon, and re-signs. When false, creates a pure unmodified copy
    ///   preserving the original signature. Default is false because apps like Claude
    ///   Desktop validate their own signature and crash if it's broken.
    static func build(for instance: AppInstance, application: Application, patchBundle: Bool = false) throws {
        // When there's a custom icon and no patching, the clone goes to a
        // hidden path and the wrapper takes the user-facing shortcutPath.
        let needsWrapper = !patchBundle && instance.customIconPath != nil
        let clonePath = needsWrapper ? cloneBundlePath(for: instance) : instance.shortcutPath
        let sourcePath = application.path

        logger.info("Cloning \(sourcePath.path) → \(clonePath.path) (patch: \(patchBundle))")

        // Clean existing bundle
        if fm.fileExists(atPath: clonePath.path) {
            try fm.removeItem(at: clonePath)
        }

        // Ensure parent directory exists
        let parent = clonePath.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // Copy the entire bundle
        try fm.copyItem(at: sourcePath, to: clonePath)

        // Replace icon if custom icon is set — resource-only changes
        // don't trigger Electron's code signature validation.
        if let customPath = instance.customIconPath, fm.fileExists(atPath: customPath.path) {
            replaceIcon(in: clonePath, with: customPath, application: application)
        }

        if patchBundle {
            // Patch Info.plist with unique bundle ID and instance name
            let plistPath = clonePath.appendingPathComponent("Contents/Info.plist")
            try patchInfoPlist(at: plistPath, instanceId: instance.id, instanceName: instance.name)

            // Re-sign with original entitlements
            try resignBundle(clone: clonePath, original: sourcePath, application: application)
        }

        // If there's a custom icon and we're NOT patching the bundle,
        // build a trampoline wrapper with the custom icon + unique bundle ID
        // that exec's into the clone's binary. This gives us a custom Dock icon
        // without breaking the clone's original code signature.
        if needsWrapper {
            try buildWrapper(for: instance, clonePath: clonePath, application: application, at: instance.shortcutPath)
            LaunchServicesHelper.register(instance.shortcutPath)
        }

        LaunchServicesHelper.register(clonePath)
        logger.info("Clone built: \(clonePath.path)")
    }

    /// Path to the trampoline wrapper that sits in front of the clone.
    /// The wrapper lives at shortcutPath (user-facing name in Dock).
    /// The clone gets a ".clone" suffix (hidden from Dock).
    static func cloneWrapperPath(for instance: AppInstance) -> URL {
        instance.shortcutPath
    }

    /// Actual clone path — the full app copy with intact signature.
    static func cloneBundlePath(for instance: AppInstance) -> URL {
        instance.shortcutPath.deletingLastPathComponent()
            .appendingPathComponent(
                instance.shortcutPath.deletingPathExtension().lastPathComponent + ".clone.app"
            )
    }

    /// Whether a wrapper+clone pair exists (vs a direct clone at shortcutPath).
    static func hasWrapper(for instance: AppInstance) -> Bool {
        fm.fileExists(atPath: cloneBundlePath(for: instance).path)
    }

    /// Remove the clone bundle and wrapper if present.
    static func remove(for instance: AppInstance) throws {
        // Remove wrapper (at shortcutPath)
        if fm.fileExists(atPath: instance.shortcutPath.path) {
            try fm.removeItem(at: instance.shortcutPath)
        }
        // Remove clone (at hidden .clone path)
        let clone = cloneBundlePath(for: instance)
        if fm.fileExists(atPath: clone.path) {
            try fm.removeItem(at: clone)
        }
    }

    /// Build a minimal trampoline wrapper with custom icon that exec's the clone.
    private static func buildWrapper(
        for instance: AppInstance,
        clonePath: URL,
        application: Application,
        at wrapperPath: URL
    ) throws {
        if fm.fileExists(atPath: wrapperPath.path) {
            try fm.removeItem(at: wrapperPath)
        }

        let contentsPath = wrapperPath.appendingPathComponent("Contents")
        let macOSPath = contentsPath.appendingPathComponent("MacOS")
        let resourcesPath = contentsPath.appendingPathComponent("Resources")

        try fm.createDirectory(at: macOSPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesPath, withIntermediateDirectories: true)

        // Info.plist with unique bundle ID
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.mtech.pluralmac.wrapper.\(instance.id.uuidString.lowercased())</string>
            <key>CFBundleName</key>
            <string>\(escapeXML(instance.name))</string>
            <key>CFBundleDisplayName</key>
            <string>\(escapeXML(instance.name))</string>
            <key>CFBundleExecutable</key>
            <string>launcher</string>
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
        try plist.write(to: contentsPath.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // Native launcher that exec's the clone's binary
        let appName = clonePath.deletingPathExtension().lastPathComponent
        let execPath = clonePath
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(application.executablePath.lastPathComponent)

        let source = """
        #include <unistd.h>
        int main(int argc, char *argv[]) {
            argv[0] = "\(execPath.path)";
            return execv("\(execPath.path)", argv);
        }
        """
        let tempSource = fm.temporaryDirectory.appendingPathComponent("wrapper_launcher.c")
        try source.write(to: tempSource, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tempSource) }

        let launcherPath = macOSPath.appendingPathComponent("launcher")
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-arch", "x86_64", "-arch", "arm64", "-O2", "-o", launcherPath.path, tempSource.path]
        clang.standardOutput = nil
        clang.standardError = nil
        try clang.run()
        clang.waitUntilExit()

        // Custom icon
        if let customPath = instance.customIconPath, fm.fileExists(atPath: customPath.path) {
            replaceIcon(in: wrapperPath, with: customPath, application: application,
                        iconFileName: "AppIcon.icns")
        }

        // Ad-hoc sign
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", wrapperPath.path]
        sign.standardOutput = nil
        sign.standardError = nil
        try sign.run()
        sign.waitUntilExit()

        logger.info("Built wrapper at \(wrapperPath.path)")
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Check if the clone needs rebuilding (original app updated).
    static func needsRebuild(instance: AppInstance) -> Bool {
        guard let storedVersion = instance.originalAppVersion else { return false }
        guard let bundle = Bundle(url: instance.targetAppPath),
              let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return false
        }
        return storedVersion != currentVersion
    }

    // MARK: - Private

    private static func patchInfoPlist(at path: URL, instanceId: UUID, instanceName: String) throws {
        guard var plist = NSDictionary(contentsOf: path) as? [String: Any] else {
            throw NSError(domain: "AppCloneBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to read Info.plist"])
        }

        plist["CFBundleIdentifier"] = "com.mtech.pluralmac.clone.\(instanceId.uuidString.lowercased())"
        plist["CFBundleName"] = instanceName
        plist["CFBundleDisplayName"] = instanceName

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: path)
    }

    private static func replaceIcon(in clonePath: URL, with customPath: URL, application: Application, iconFileName: String? = nil) {
        let icnsName: String
        if let override = iconFileName {
            icnsName = override
        } else {
            let bundle = Bundle(url: application.path)
            let iconName = bundle?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleIconName") as? String
                ?? "AppIcon"
            icnsName = iconName.hasSuffix(".icns") ? iconName : "\(iconName).icns"
        }

        let destPath = clonePath
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(icnsName)

        if customPath.pathExtension.lowercased() == "icns" {
            try? fm.removeItem(at: destPath)
            try? fm.copyItem(at: customPath, to: destPath)
            return
        }

        // Convert PNG to ICNS
        guard let image = NSImage(contentsOf: customPath) else { return }
        let tempIconset = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
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

    /// Re-sign the clone bundle preserving the original's entitlements.
    /// Signs nested components individually (not --deep) then the outer bundle.
    private static func resignBundle(clone: URL, original: URL, application: Application) throws {
        // Extract entitlements from the original binary
        let entitlementsFile = fm.temporaryDirectory.appendingPathComponent("clone-entitlements.plist")
        defer { try? fm.removeItem(at: entitlementsFile) }

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        extract.arguments = ["-d", "--entitlements", entitlementsFile.path, "--xml", application.executablePath.path]
        extract.standardOutput = nil
        extract.standardError = nil
        try extract.run()
        extract.waitUntilExit()

        let hasEntitlements = fm.fileExists(atPath: entitlementsFile.path)

        // Sign nested frameworks
        let frameworksPath = clone.appendingPathComponent("Contents/Frameworks")
        if let contents = try? fm.contentsOfDirectory(atPath: frameworksPath.path) {
            for item in contents {
                let itemPath = frameworksPath.appendingPathComponent(item)
                try sign(itemPath, entitlements: hasEntitlements ? entitlementsFile : nil)
            }
        }

        // Sign the top-level bundle
        try sign(clone, entitlements: hasEntitlements ? entitlementsFile : nil)

        logger.info("Re-signed clone at \(clone.path)")
    }

    private static func sign(_ path: URL, entitlements: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        var args = ["--force", "--sign", "-"]
        if let ent = entitlements {
            args += ["--entitlements", ent.path]
        }
        args.append(path.path)
        process.arguments = args
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            logger.warning("codesign failed for \(path.lastPathComponent) with status \(process.terminationStatus)")
        }
    }
}
