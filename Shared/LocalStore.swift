import Foundation

struct Library: Codable {
    var sessions: [FieldSession] = []
    var markedSpot: SpotReading?
    var presets: [Preset] = []
    var selectedPreset: Preset?
    var haptics = false
    var milestones = Milestones()
    var review = ReviewGate()
    var coreReviewProgress: CoreReviewProgress?

    var latestComparison: FieldSession? {
        sessions.first { $0.preset.mode == .compare && $0.spots.filter(\.comparable).count >= 2 }
    }
}

enum LocalFailure: Error { case unavailable, invalidPreset }

actor LocalStore {
    private let test: Bool
    private let namespace: String
    private var lastRevision = 0

    init(test: Bool, namespace: String) {
        self.test = test
        self.namespace = namespace
    }

    private func location() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let name = test ? "magmeter-ui-\(namespace).json" : "magmeter.json"
        return folder.appendingPathComponent(name)
    }

    func load(reset: Bool) throws -> Library {
        let url = try location()
        if test && reset && FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
    }

    func save(_ library: Library, revision: Int) throws {
        guard revision > lastRevision else { return }
        let data = try JSONEncoder().encode(library)
        try data.write(to: location(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastRevision = revision
    }

    func presetCode(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<String, Error> = .failure(LocalFailure.invalidPreset)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { path in
            result = Result {
                let file = try FileHandle(forReadingFrom: path)
                defer { try? file.close() }
                let data = try file.read(upToCount: Preset.maxLength + 1) ?? Data()
                guard data.count <= Preset.maxLength, let code = String(data: data, encoding: .utf8),
                      Preset.decode(code) != nil else { throw LocalFailure.invalidPreset }
                return code
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    func export(_ data: Data, extension suffix: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MagMeterExports", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeExport(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
