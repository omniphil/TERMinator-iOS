import Foundation
import UIKit
import UniformTypeIdentifiers
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Manages import/export of BBS connection configurations.
class ImportExportManager {

    static let shared = ImportExportManager()

    private init() {}

    // MARK: - Export

    /// Export all connections to a ZIP file containing connections.xml and snapshots.
    /// - Returns: URL of the created ZIP file, or nil on failure
    func exportConnections() -> URL? {
        let entries = BBSEntryStore.shared.entries

        guard !entries.isEmpty else {
            print("ImportExportManager: No connections to export")
            return nil
        }

        do {
            // Create temp directory for export
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Generate XML content
            let xmlContent = generateXML(from: entries)
            let xmlFile = tempDir.appendingPathComponent("connections.xml")
            try xmlContent.write(to: xmlFile, atomically: true, encoding: .utf8)

            // Export snapshots
            let snapshotsDir = tempDir.appendingPathComponent("snapshots")
            try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

            for entry in entries {
                if let snapshotData = entry.snapshotData {
                    let snapshotFile = snapshotsDir.appendingPathComponent("\(entry.id.uuidString).png")
                    try snapshotData.write(to: snapshotFile)
                }
            }

            // Create ZIP archive
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let zipFile = documentsDir.appendingPathComponent("TERMinator_Export_\(timestamp).zip")

            // Remove existing file if needed
            try? FileManager.default.removeItem(at: zipFile)

            try FileManager.default.zipItem(at: tempDir, to: zipFile)

            // Cleanup temp directory
            try? FileManager.default.removeItem(at: tempDir)

            print("ImportExportManager: Exported to \(zipFile.path)")
            return zipFile

        } catch {
            print("ImportExportManager: ZIP export failed (\(error)), falling back to XML")
            return exportConnectionsXML()
        }
    }

    /// Export connections to XML only (legacy format).
    /// - Returns: URL of the created XML file, or nil on failure
    func exportConnectionsXML() -> URL? {
        let entries = BBSEntryStore.shared.entries

        guard !entries.isEmpty else {
            return nil
        }

        do {
            let xmlContent = generateXML(from: entries)
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let xmlFile = documentsDir.appendingPathComponent("TERMinator_Connections_\(timestamp).xml")

            try xmlContent.write(to: xmlFile, atomically: true, encoding: .utf8)
            return xmlFile

        } catch {
            print("ImportExportManager: XML export failed - \(error)")
            return nil
        }
    }

    // MARK: - Import

    /// Import connections from a file (ZIP or XML).
    /// - Parameters:
    ///   - url: URL of the file to import
    ///   - replace: If true, replace all existing connections; if false, merge
    /// - Returns: Number of connections imported, or -1 on failure
    func importConnections(from url: URL, replace: Bool = false) -> Int {
        let ext = url.pathExtension.lowercased()

        if ext == "zip" {
            return importFromZIP(url, replace: replace)
        } else if ext == "xml" {
            return importFromXML(url, replace: replace)
        } else {
            print("ImportExportManager: Unsupported file type: \(ext)")
            return -1
        }
    }

    private func importFromZIP(_ url: URL, replace: Bool) -> Int {
        do {
            // Create temp directory for extraction
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Extract ZIP
            try FileManager.default.unzipItem(at: url, to: tempDir)

            // Find and parse connections.xml
            let xmlFile = tempDir.appendingPathComponent("connections.xml")
            guard FileManager.default.fileExists(atPath: xmlFile.path) else {
                print("ImportExportManager: connections.xml not found in ZIP")
                try? FileManager.default.removeItem(at: tempDir)
                return -1
            }

            let xmlContent = try String(contentsOf: xmlFile, encoding: .utf8)
            var entries = parseXML(xmlContent)

            // Load snapshots
            let snapshotsDir = tempDir.appendingPathComponent("snapshots")
            if FileManager.default.fileExists(atPath: snapshotsDir.path) {
                for i in 0..<entries.count {
                    let snapshotFile = snapshotsDir.appendingPathComponent("\(entries[i].id.uuidString).png")
                    if let snapshotData = try? Data(contentsOf: snapshotFile) {
                        entries[i].snapshotData = snapshotData
                    }
                }
            }

            // Import entries
            BBSEntryStore.shared.importEntries(entries, replace: replace)

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)

            print("ImportExportManager: Imported \(entries.count) connections from ZIP")
            return entries.count

        } catch {
            print("ImportExportManager: ZIP import failed - \(error)")
            return -1
        }
    }

    private func importFromXML(_ url: URL, replace: Bool) -> Int {
        do {
            let xmlContent = try String(contentsOf: url, encoding: .utf8)
            let entries = parseXML(xmlContent)

            guard !entries.isEmpty else {
                print("ImportExportManager: No connections found in XML")
                return 0
            }

            BBSEntryStore.shared.importEntries(entries, replace: replace)

            print("ImportExportManager: Imported \(entries.count) connections from XML")
            return entries.count

        } catch {
            print("ImportExportManager: XML import failed - \(error)")
            return -1
        }
    }

    // MARK: - XML Generation

    private func generateXML(from entries: [BBSEntry]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<connections>\n"

        for entry in entries {
            xml += "  <connection>\n"
            xml += "    <id>\(xmlEscape(entry.id.uuidString))</id>\n"
            xml += "    <name>\(xmlEscape(entry.name))</name>\n"
            xml += "    <host>\(xmlEscape(entry.host))</host>\n"
            xml += "    <port>\(entry.port)</port>\n"
            xml += "    <protocol>\(entry.connectionProtocol.rawValue)</protocol>\n"
            xml += "    <username>\(xmlEscape(entry.username))</username>\n"
            xml += "    <screenMode>\(entry.screenMode.rawValue)</screenMode>\n"
            xml += "    <font>\(entry.font.rawValue)</font>\n"
            xml += "    <zoomLevel>\(entry.zoomLevel)</zoomLevel>\n"
            xml += "    <showStatusBar>\(entry.showStatusBar)</showStatusBar>\n"
            xml += "    <autoConnect>\(entry.autoConnect)</autoConnect>\n"

            // Note: We do NOT export passwords for security
            // <password> tag is intentionally omitted

            // Include snapshot image as base64
            if let snapshotData = entry.snapshotData {
                xml += "    <snapshot>\(snapshotData.base64EncodedString())</snapshot>\n"
            }

            xml += "  </connection>\n"
        }

        xml += "</connections>\n"
        return xml
    }

    // MARK: - XML Parsing

    private func parseXML(_ xmlContent: String) -> [BBSEntry] {
        var entries: [BBSEntry] = []

        // Simple XML parsing using regex (for robustness, could use XMLParser)
        let connectionPattern = "<connection>(.*?)</connection>"
        guard let connectionRegex = try? NSRegularExpression(pattern: connectionPattern, options: .dotMatchesLineSeparators) else {
            return entries
        }

        let range = NSRange(xmlContent.startIndex..., in: xmlContent)
        let matches = connectionRegex.matches(in: xmlContent, options: [], range: range)

        for match in matches {
            if let connectionRange = Range(match.range(at: 1), in: xmlContent) {
                let connectionXML = String(xmlContent[connectionRange])
                if let entry = parseConnectionXML(connectionXML) {
                    entries.append(entry)
                }
            }
        }

        return entries
    }

    private func parseConnectionXML(_ xml: String) -> BBSEntry? {
        func extractValue(_ tag: String) -> String? {
            let pattern = "<\(tag)>(.*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
                return nil
            }
            let range = NSRange(xml.startIndex..., in: xml)
            if let match = regex.firstMatch(in: xml, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: xml) {
                return xmlUnescape(String(xml[valueRange]))
            }
            return nil
        }

        // Required fields
        guard let name = extractValue("name"),
              let host = extractValue("host"),
              !host.isEmpty else {
            return nil
        }

        // Parse ID or generate new one
        let id: UUID
        if let idString = extractValue("id"), let parsedId = UUID(uuidString: idString) {
            id = parsedId
        } else {
            id = UUID()
        }

        // Parse optional fields with defaults
        let port = Int(extractValue("port") ?? "") ?? 23
        let protocolValue = Int(extractValue("protocol") ?? "") ?? ConnectionProtocol.telnet.rawValue
        let connectionProtocol = ConnectionProtocol(rawValue: protocolValue) ?? .telnet
        let username = extractValue("username") ?? ""
        let screenModeValue = Int(extractValue("screenMode") ?? "") ?? ScreenMode.mode80x25.rawValue
        let screenMode = ScreenMode(rawValue: screenModeValue) ?? .mode80x25
        let fontValue = Int(extractValue("font") ?? "") ?? TerminalFont.cp437.rawValue
        let font = TerminalFont(rawValue: fontValue) ?? .cp437
        let zoomLevel = Int(extractValue("zoomLevel") ?? "") ?? 100
        // Support both new showStatusBar and legacy hideStatusLine tags
        let showStatusBar: Bool
        if let value = extractValue("showStatusBar") {
            showStatusBar = value == "true"
        } else if let value = extractValue("hideStatusLine") {
            showStatusBar = value != "true"  // Invert legacy value
        } else {
            showStatusBar = true  // Default: shown
        }
        let autoConnect = extractValue("autoConnect") == "true"

        // Decode snapshot image from base64
        var snapshotData: Data? = nil
        if let base64String = extractValue("snapshot") {
            snapshotData = Data(base64Encoded: base64String)
        }

        return BBSEntry(
            id: id,
            name: name,
            host: host,
            port: port,
            connectionProtocol: connectionProtocol,
            username: username,
            screenMode: screenMode,
            font: font,
            zoomLevel: zoomLevel,
            showStatusBar: showStatusBar,
            autoConnect: autoConnect,
            snapshotData: snapshotData
        )
    }

    // MARK: - XML Escaping

    private func xmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func xmlUnescape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - File Picker

    /// Present a document picker for importing files.
    /// - Parameters:
    ///   - viewController: The view controller to present from
    ///   - completion: Completion handler with imported URL or nil
    func presentImportPicker(from viewController: UIViewController, completion: @escaping (URL?) -> Void) {
        let types: [UTType] = [.zip, .xml, UTType(filenameExtension: "xml")!]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = false
        let delegate = DocumentPickerDelegate(completion: completion)
        picker.delegate = delegate

        // Store delegate reference to prevent deallocation
        objc_setAssociatedObject(picker, &AssociatedKeys.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        viewController.present(picker, animated: true)
    }

    /// Present a share sheet for exporting files.
    /// - Parameters:
    ///   - url: The URL of the file to share
    ///   - viewController: The view controller to present from
    func presentExportShareSheet(for url: URL, from viewController: UIViewController) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        // For iPad, set the popover location
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(x: viewController.view.bounds.midX,
                                        y: viewController.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        viewController.present(activityVC, animated: true)
    }
}

// MARK: - Document Picker Delegate

private enum AssociatedKeys {
    static var delegateKey: UInt8 = 0
}

private class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: (URL?) -> Void

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}

// MARK: - ZIPFoundation stub (if not using external package)

#if !canImport(ZIPFoundation)
extension FileManager {
    func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
        // Fallback: just copy the directory if ZIPFoundation is not available
        // For a full implementation, add ZIPFoundation via SPM
        throw NSError(domain: "ImportExportManager", code: -1,
                     userInfo: [NSLocalizedDescriptionKey: "ZIP support requires ZIPFoundation package"])
    }

    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        throw NSError(domain: "ImportExportManager", code: -1,
                     userInfo: [NSLocalizedDescriptionKey: "ZIP support requires ZIPFoundation package"])
    }
}
#endif
