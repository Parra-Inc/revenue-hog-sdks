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

    /// Writes the queue. Returns whether the write landed: a full disk fails
    /// an atomic write while reads still succeed.
    @discardableResult
    func save(_ items: [PendingRequest]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    /// Appends `item`, keeping the queue to `maxCount`. Event batches make the
    /// room, oldest first; only when none is queued does the oldest request
    /// go. A batch never makes room for itself: a full queue drops it instead.
    /// So a backlog of events can never cost a purchase's attribution, an
    /// identify, or feedback its place. Returns whether `item` was written.
    @discardableResult
    func append(_ item: PendingRequest) -> Bool {
        var items = load()
        if items.count >= maxCount, item.isEventBatch { return false }
        items.append(item)
        while items.count > maxCount {
            items.remove(at: items.firstIndex(where: \.isEventBatch) ?? 0)
        }
        return save(items)
    }

    /// Removes the head if it is still `item`. A flush only ever delivers the
    /// head and nothing is put in front of it, so a different head means an
    /// append over the cap evicted `item` while it was out for delivery; an
    /// equal copy further back has not been delivered, and stays. Returns
    /// false only when the removal could not be written.
    @discardableResult
    func removeHead(_ item: PendingRequest) -> Bool {
        var items = load()
        guard items.first == item else { return true }
        items.removeFirst()
        return save(items)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
