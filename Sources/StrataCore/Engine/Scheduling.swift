import Foundation

struct SimulationRandom {
    var state: UInt64

    mutating func unit() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var bits = state
        bits = (bits ^ (bits >> 30)) &* 0xbf58476d1ce4e5b9
        bits = (bits ^ (bits >> 27)) &* 0x94d049bb133111eb
        bits ^= bits >> 31
        return (Double(bits >> 12) + 0.5) * 0x1p-52
    }

    mutating func occurs(_ probability: Double) -> Bool {
        probability >= 1 || (probability > 0 && unit() < probability)
    }

    mutating func sample(_ distribution: Dist) -> Double {
        switch distribution {
        case .fixed(let seconds): return seconds
        case .jitter(let mean): return mean * (0.75 + unit() * 0.5)
        case .uniform(let start, let end): return start + (end - start) * unit()
        case .exponential(let mean): return -log(unit()) * mean
        case .lognormal(let median, let p99):
            let normal = sqrt(-2 * log(unit())) * cos(2 * .pi * unit())
            return median * exp(normal * log(max(1, p99 / max(median, 1e-9))) / 2.326347874)
        }
    }
}

struct EventQueue {
    struct Entry {
        let time: Double
        let sequence: Int
        let event: SimulationEvent

        func precedes(_ other: Self) -> Bool {
            time == other.time ? sequence < other.sequence : time < other.time
        }
    }

    private var heap: [Entry] = []
    private(set) var nextSequence = 0
    var first: Entry? { heap.first }

    mutating func insert(_ event: SimulationEvent, at time: Double) {
        let entry = Entry(time: time, sequence: nextSequence, event: event)
        nextSequence += 1
        var index = heap.count
        heap.append(entry)
        while index > 0 {
            let parent = (index - 1) / 2
            guard entry.precedes(heap[parent]) else { break }
            heap[index] = heap[parent]
            index = parent
        }
        heap[index] = entry
    }

    mutating func pop() -> Entry {
        let first = heap[0]
        let last = heap.removeLast()
        guard !heap.isEmpty else { return first }
        var index = 0
        while index * 2 + 1 < heap.count {
            var child = index * 2 + 1
            if child + 1 < heap.count, heap[child + 1].precedes(heap[child]) { child += 1 }
            guard heap[child].precedes(last) else { break }
            heap[index] = heap[child]
            index = child
        }
        heap[index] = last
        return first
    }
}

struct FIFO<Element> {
    private var storage: [Element] = []
    private var head = 0
    var count: Int { storage.count - head }
    var first: Element? { head < storage.count ? storage[head] : nil }
    var elements: ArraySlice<Element> { storage[head...] }

    mutating func append(_ element: Element) { storage.append(element) }

    mutating func pop() -> Element? {
        guard let first else { return nil }
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head >= count {
            storage.removeFirst(head)
            head = 0
        }
        return first
    }
}

struct RecordID: Hashable, Comparable {
    let index: Int
    let generation: Int

    static func < (a: Self, b: Self) -> Bool { a.generation < b.generation }
}

// An event may outlive its request. A generation prevents it from touching a reused record.
struct RecordPool<Record> {
    private struct Entry {
        var record: Record?
        let generation: Int
    }

    private var entries: [Entry] = []
    private var free: [Int] = []
    private var generation = 0

    subscript(_ id: RecordID) -> Record? {
        get { entries[id.index].generation == id.generation ? entries[id.index].record : nil }
        set {
            precondition(entries[id.index].generation == id.generation && newValue != nil)
            entries[id.index].record = newValue
        }
        _modify {
            precondition(entries[id.index].generation == id.generation && entries[id.index].record != nil)
            yield &entries[id.index].record
        }
    }

    mutating func insert(_ record: Record) -> RecordID {
        generation += 1
        let entry = Entry(record: record, generation: generation)
        if let index = free.popLast() {
            entries[index] = entry
            return RecordID(index: index, generation: generation)
        }
        let index = entries.count
        entries.append(entry)
        return RecordID(index: index, generation: generation)
    }

    mutating func remove(_ id: RecordID) {
        guard self[id] != nil else { return }
        entries[id.index].record = nil
        free.append(id.index)
    }
}
