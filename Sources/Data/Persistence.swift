import Foundation

/// Tiny JSON-file store. The app's user data is small (progress records, library index,
/// recording index, settings) so a document store would be overkill; one file per collection
/// written atomically is plenty and keeps everything inspectable.
enum FileStore {
    static var supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PracticeRoom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for name: String) -> URL {
        supportDirectory.appendingPathComponent("\(name).json")
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = url(for: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // A decode failure here means a schema change shipped without a migration. Move the
            // bad file aside rather than crashing or silently wiping it.
            let quarantine = url.appendingPathExtension("bad-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url(for: name), options: .atomic)
        } catch {
            print("[PracticeRoom] failed to save \(name): \(error)")
        }
    }
}

/// Where imported media and recorded takes live on disk.
enum MediaStore {
    static var mediaDirectory: URL = {
        let dir = FileStore.supportDirectory.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var recordingsDirectory: URL = {
        let dir = FileStore.supportDirectory.appendingPathComponent("Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var scratchDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PracticeRoomScratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func mediaURL(_ filename: String) -> URL {
        mediaDirectory.appendingPathComponent(filename)
    }

    static func recordingURL(_ filename: String) -> URL {
        recordingsDirectory.appendingPathComponent(filename)
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func byteSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func totalBytesUsed() -> Int64 {
        var total: Int64 = 0
        for dir in [mediaDirectory, recordingsDirectory] {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            total += items.reduce(0) { $0 + byteSize(of: $1) }
        }
        return total
    }
}
