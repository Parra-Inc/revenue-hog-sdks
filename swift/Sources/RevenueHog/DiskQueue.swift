import Foundation

/// FIFO queue of undelivered requests, persisted as a single JSON file.
/// Only ever touched from inside the `HogClient` actor.
struct DiskQueue {
    let fileURL: URL
    let maxCount: Int

    init(directory: URL, maxCount: Int = 100) {
        self.fileURL = directory.appendingPathComponent("revenuehog-queue.json")
        self.maxCount = maxCount
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    func load() -> [PendingRequest] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([PendingRequest].self, from: data)
        else { return [] }
        return items
    }

    func save(_ items: [PendingRequest]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Appends, dropping the oldest entries beyond `maxCount`.
    func append(_ item: PendingRequest) {
        var items = load()
        items.append(item)
        if items.count > maxCount {
            items.removeFirst(items.count - maxCount)
        }
        save(items)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
