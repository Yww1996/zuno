import XCTest
@testable import PeaZip27

final class ArchiveEntryExportTests: XCTestCase {
    func testSelectedDocxWithLeadingSpaceCanBeDeliveredAndExportedWithoutOverwrite() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("2026-11")
        let desktop = root.appendingPathComponent("Desktop")
        for folder in [nested, desktop] { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
        let name = " 2、检测报告 [1].docx"
        let document = nested.appendingPathComponent(name)
        let payload = Data("selected".utf8)
        try payload.write(to: document)
        try Data("sibling".utf8).write(to: nested.appendingPathComponent("未选中.docx"))
        let archive = root.appendingPathComponent("reports.zip")
        let created = ArchiveEngine.add(sources: [nested], to: archive, format: .zip, onLine: nil)
        XCTAssertTrue(created.ok, created.output)
        let selected = try XCTUnwrap(ArchiveEngine.entries(in: archive).first { $0.path.hasSuffix("[1].docx") })
        XCTAssertEqual(selected.path, "2026-11/\(name)")

        let promised = desktop.appendingPathComponent(name)
        try ArchiveEntryExport.withExtractedEntry(archive, path: selected.path) { source in
            try ArchiveEntryExport.deliverPromise(source, to: promised)
        }
        XCTAssertEqual(try Data(contentsOf: promised), payload)

        var outputs: [URL] = []
        try ArchiveEntryExport.export(archive, paths: [selected.path], to: desktop) { outputs.append($0) }
        let second = try XCTUnwrap(outputs.first)
        XCTAssertEqual(second.lastPathComponent, " 2、检测报告 [1] (2).docx")
        XCTAssertEqual(try Data(contentsOf: second), payload)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: desktop.path).count, 2)
        XCTAssertEqual(try Data(contentsOf: promised), payload)
    }
}
