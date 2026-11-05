import Foundation

struct PlacementEvent: Codable, Sendable, Equatable {
    let placement_id: String
    let page: String
    let type: String
    let target: String
    let occurred_at: Date

    static func validName(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

/// One tracker per presentation; page state never leaks between placements.
@MainActor
final class PresentationAnalytics {
    private let placementID: String
    private let record: (PlacementEvent) -> Void
    private var page = ""
    private var shown = false
    private var closed = false

    init(placementID: String, record: @escaping (PlacementEvent) -> Void) {
        self.placementID = placementID
        self.record = record
    }

    func appear() {
        guard !shown, !closed else { return }
        shown = true
        send("impression", page: "")
    }

    func visit(_ name: String) {
        guard !closed, PlacementEvent.validName(name) else { return }
        page = name
        send("impression", page: page)
    }

    func click(_ target: String) {
        guard !closed, PlacementEvent.validName(target) else { return }
        send("click", page: page, target: target)
    }

    func close() {
        guard !closed else { return }
        closed = true
        send("close", page: page)
    }

    private func send(_ type: String, page: String, target: String = "") {
        record(.init(placement_id: placementID, page: page, type: type, target: target, occurred_at: Date()))
    }
}

actor EventQueue {
    private struct Batch: Codable { let events: [PlacementEvent] }
    private struct Receipt: Decodable { let accepted: Int }
    private let configuration: FlowdeckConfiguration
    private let transport: any HTTPTransport
    private let file: URL
    private let capacity: Int
    private var events: [PlacementEvent] = []
    private var loaded = false
    private var sending = false
    private var retryAfter = Date.distantPast

    init(configuration: FlowdeckConfiguration, transport: (any HTTPTransport)? = nil, capacity: Int = 1000) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionTransport(protocolClasses: configuration.protocolClasses)
        self.capacity = capacity
        let namespace = PackageCache.hash(Data((configuration.baseURL.absoluteString + "\n" + configuration.apiKey).utf8))
        file = configuration.cacheDirectory.appendingPathComponent(namespace).appendingPathComponent("events.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let batch = try? JSONDecoder().decode(Batch.self, from: data) {
            events = Array(batch.events.prefix(capacity))
        }
    }

    private func save() {
        // Disk work runs on this actor, never on the presentation's main actor.
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Batch(events: events)).write(to: file, options: .atomic)
        } catch { /* Retain the in-memory queue if storage is unavailable. */ }
    }

    func enqueue(_ event: PlacementEvent) {
        load()
        guard Placement.validID(event.placement_id), PlacementEvent.validName(event.page),
              PlacementEvent.validName(event.target), ["impression", "click", "close"].contains(event.type),
              event.type == "click" || event.target.isEmpty, events.count < capacity else { return }
        events.append(event)
        save()
    }

    func flush(now: Date = Date()) async {
        load()
        guard !sending, now >= retryAfter else { return }
        // Leave a small margin for server clock/network latency at the 30-day boundary.
        let previousCount = events.count
        events.removeAll { now.timeIntervalSince($0.occurred_at) >= 29 * 86400 }
        if events.count != previousCount { save() }
        guard !events.isEmpty else { return }
        sending = true
        defer { sending = false }
        let batch = Array(events.prefix(100))
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/sdk/events"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(Batch(events: batch))
            let response = try await transport.get(request)
            guard response.status == 200,
                  try JSONDecoder().decode(Receipt.self, from: response.data).accepted == batch.count else {
                throw FlowdeckError.invalidResponse
            }
            events.removeFirst(batch.count)
            save()
        } catch {
            retryAfter = now.addingTimeInterval(30)
        }
    }
}
