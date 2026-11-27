import Foundation
import UniformTypeIdentifiers

/// Extract away from both the protected source directory and the destination.
enum ArchiveEntryExport {
    static func promiseType(for item: FileItem) -> String {
        if item.isDirectory { return UTType.folder.identifier }
        // Dynamic and third-party types need not conform to public.data, which
        // AppKit requires for a file promise even if the filename has an extension.
        if let type = UTType(filenameExtension: item.url.pathExtension), type.conforms(to: .data) {
            return type.identifier
        }
        return UTType.data.identifier
    }

    enum Failure: LocalizedError {
        case invalidPath
        case extraction(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath: return "压缩包里的文件路径不安全。"
            case .extraction(let detail): return "无法从压缩包中提取文件。\n\(detail)"
            case .missing(let path): return "压缩工具未输出选中的项目：\(path)"
            }
        }
    }

    static func withExtractedEntry(_ archive: URL, path: String,
                                   onProgress: ((Int, String?) -> Void)? = nil,
                                   _ use: (URL) throws -> Void) throws {
        try withExtractedEntries(archive, paths: [path], onProgress: onProgress) { files in
            try use(files[0])
        }
    }

    private static func withExtractedEntries(_ archive: URL, paths: [String],
                                             onProgress: ((Int, String?) -> Void)?,
                                             _ use: ([URL]) throws -> Void) throws {
        guard !paths.isEmpty, paths.allSatisfy({ path in
            !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
                && !path.split(separator: "/").contains("..")
                && !path.split(separator: "/").contains(".")
        }) else { throw Failure.invalidPath }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("zuno-entry-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let result = ArchiveEngine.extractEntries(archive, paths: paths, to: scratch,
                                                   onLine: nil, onProgress: onProgress)
        guard result.ok else { throw Failure.extraction(result.output.split(separator: "\n").suffix(10).joined(separator: "\n")) }
        let root = scratch.resolvingSymlinksInPath().path + "/"
        let sources = try paths.map { path in
            let file = scratch.appendingPathComponent(path)
            guard fm.fileExists(atPath: file.path) else { throw Failure.missing(path) }
            guard file.resolvingSymlinksInPath().path.hasPrefix(root) else { throw Failure.invalidPath }
            return file
        }
        try use(sources)
    }

    static func deliverPromise(_ source: URL, to destination: URL) throws {
        // Finder supplies the final URL, including any collision handling. Apple
        // requires the provider to coordinate its write before calling completion.
        var coordinationError: NSError?
        var copyError: Error?
        var coordinated = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { url in
            coordinated = true
            do { try FileManager.default.copyItem(at: source, to: url) }
            catch { copyError = error }
        }
        if let error = coordinationError {
            // Some launch contexts cannot reach the coordination service. When
            // it never ran the accessor, try the same no-overwrite copy directly;
            // a missing Desktop grant still fails and reports the actual error.
            guard !coordinated, error.domain == NSCocoaErrorDomain,
                  error.code == NSFileWriteUnknownError else { throw error }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        if let error = copyError { throw error }
    }

    static func export(_ archive: URL, paths: [String], to desktop: URL,
                       onProgress: ((Int, String?) -> Void)? = nil,
                       didExport: (URL) -> Void) throws {
        try withExtractedEntries(archive, paths: paths, onProgress: onProgress) { sources in
            for source in sources {
                let fm = FileManager.default
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                let ext = values.isDirectory == true ? "" : source.pathExtension
                let base = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
                var saved = false
                for index in 1...10_000 {
                    let name = base + (index == 1 ? "" : " (\(index))") + (ext.isEmpty ? "" : ".\(ext)")
                    let target = desktop.appendingPathComponent(name)
                    do {
                        try fm.copyItem(at: source, to: target)
                        didExport(target)
                        saved = true
                        break
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        continue
                    }
                }
                if !saved { throw CocoaError(.fileWriteFileExists) }
            }
        }
    }
}
