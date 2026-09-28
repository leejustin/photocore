import Foundation
import PhotoEnginePersistence

final class CancelFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()

    func cancel(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}

actor JobQueue {
    private let catalog: PhotoCatalog
    private let cancel: CancelFlags
    private var pending: [String] = []
    private var work: [String: @Sendable () async throws -> Data] = [:]
    private var listeners: [String: [UUID: AsyncStream<JobRecord>.Continuation]] = [:]
    private var draining = false

    init(catalog: PhotoCatalog, cancel: CancelFlags) {
        self.catalog = catalog
        self.cancel = cancel
    }

    func enqueue(_ record: JobRecord, work: @escaping @Sendable () async throws -> Data) throws -> JobRecord {
        try catalog.insertJob(record)
        self.work[record.id] = work
        pending.append(record.id)
        if !draining {
            draining = true
            Task { await self.drain() }
        }
        return record
    }

    func job(id: String) throws -> JobRecord? {
        try catalog.job(id: id)
    }

    func jobs(limit: Int, state: String?) throws -> [JobRecord] {
        try catalog.jobs(limit: limit, state: state)
    }

    func cancel(id: String) throws -> JobRecord? {
        guard var record = try catalog.job(id: id) else { return nil }
        cancel.cancel(id)
        if record.state == "queued" {
            record.state = "cancelled"
            record.finishedAt = Date()
            record.errorCode = nil
            record.errorMessage = nil
            try catalog.updateJob(id: id) { $0 = record }
            pending.removeAll { $0 == id }
            work[id] = nil
            publish(record)
        }
        return try catalog.job(id: id)
    }

    func noteProgress(id: String, stage: String, completed: Int, total: Int, message: String) {
        guard var record = try? catalog.job(id: id), record.state == "running" else { return }
        record.stage = stage
        record.completed = completed
        record.total = total
        record.message = message
        try? catalog.updateJob(id: id) { $0 = record }
        publish(record)
    }

    func subscribe(id: String) -> AsyncStream<JobRecord> {
        AsyncStream { continuation in
            let token = UUID()
            if listeners[id] == nil { listeners[id] = [:] }
            listeners[id]?[token] = continuation
            if let current = try? catalog.job(id: id) {
                continuation.yield(current)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id: id, token: token) }
            }
        }
    }

    private func removeListener(id: String, token: UUID) {
        listeners[id]?[token] = nil
    }

    private func drain() async {
        while !pending.isEmpty {
            let id = pending.removeFirst()
            guard let operation = work.removeValue(forKey: id) else { continue }
            await run(id: id, work: operation)
        }
        draining = false
        if !pending.isEmpty {
            draining = true
            Task { await self.drain() }
        }
    }

    private func run(id: String, work: @Sendable () async throws -> Data) async {
        guard var record = try? catalog.job(id: id) else { return }
        if cancel.contains(id) || record.state == "cancelled" {
            record.state = "cancelled"
            record.finishedAt = Date()
            try? catalog.updateJob(id: id) { $0 = record }
            publish(record)
            return
        }
        record.state = "running"
        record.startedAt = Date()
        try? catalog.updateJob(id: id) { $0 = record }
        publish(record)
        do {
            let result = try await work()
            if cancel.contains(id) {
                record.state = "cancelled"
                record.finishedAt = Date()
            } else {
                record.state = "succeeded"
                record.result = result
                record.finishedAt = Date()
                if let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                   let sessionID = object["sessionID"] as? String {
                    record.sessionID = sessionID
                }
            }
        } catch is CancellationError {
            record.state = "cancelled"
            record.finishedAt = Date()
        } catch {
            record.state = "failed"
            record.errorCode = "internal"
            record.errorMessage = error.localizedDescription
            record.finishedAt = Date()
        }
        try? catalog.updateJob(id: id) { stored in
            stored.state = record.state
            stored.result = record.result
            stored.finishedAt = record.finishedAt
            stored.errorCode = record.errorCode
            stored.errorMessage = record.errorMessage
            stored.sessionID = record.sessionID
            stored.stage = record.stage
            stored.completed = record.completed
            stored.total = record.total
            stored.message = record.message
        }
        if let stored = try? catalog.job(id: id) {
            publish(stored)
        }
    }

    private func publish(_ record: JobRecord) {
        listeners[record.id]?.values.forEach { $0.yield(record) }
        if ["succeeded", "failed", "cancelled"].contains(record.state) {
            listeners[record.id]?.values.forEach { $0.finish() }
            listeners[record.id] = nil
        }
    }
}
