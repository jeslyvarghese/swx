/// A subset of one package's known versions, stored as a bitset over the domain's indices.
///
/// The solver only works with versions it has seen (from `git ls-remote`), so every
/// set is finite and set algebra is exact. SwiftPM's pre-release rules are applied once,
/// when a `VersionRequirement` is converted into a set.
struct VersionSet: Sendable, Hashable {
    private static let bitsPerWord = UInt64.bitWidth

    private(set) var words: [UInt64]
    let count: Int

    /// The empty set over a domain of `count` versions.
    init(empty count: Int) {
        self.count = count
        self.words = Array(repeating: 0, count: (count + Self.bitsPerWord - 1) / Self.bitsPerWord)
    }

    /// The full set over a domain of `count` versions.
    init(full count: Int) {
        self.init(empty: count)
        for index in 0..<count {
            self.insert(index)
        }
    }

    init(count: Int, indices: some Sequence<Int>) {
        self.init(empty: count)
        for index in indices {
            self.insert(index)
        }
    }

    mutating func insert(_ index: Int) {
        self.words[index / Self.bitsPerWord] |= 1 << UInt64(index % Self.bitsPerWord)
    }

    func contains(_ index: Int) -> Bool {
        self.words[index / Self.bitsPerWord] & (1 << UInt64(index % Self.bitsPerWord)) != 0
    }

    var isEmpty: Bool {
        self.words.allSatisfy { $0 == 0 }
    }

    var cardinality: Int {
        self.words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    // MARK: Set algebra (domains always match: sets of one package share its domain).

    func intersection(_ other: VersionSet) -> VersionSet {
        var result = self
        for index in result.words.indices {
            result.words[index] &= other.words[index]
        }
        return result
    }

    func union(_ other: VersionSet) -> VersionSet {
        var result = self
        for index in result.words.indices {
            result.words[index] |= other.words[index]
        }
        return result
    }

    func subtracting(_ other: VersionSet) -> VersionSet {
        var result = self
        for index in result.words.indices {
            result.words[index] &= ~other.words[index]
        }
        return result
    }

    func isSubset(of other: VersionSet) -> Bool {
        for index in self.words.indices where self.words[index] & ~other.words[index] != 0 {
            return false
        }
        return true
    }

    func isDisjoint(with other: VersionSet) -> Bool {
        for index in self.words.indices where self.words[index] & other.words[index] != 0 {
            return false
        }
        return true
    }

    var ascendingIndices: some Sequence<Int> {
        (0..<self.count).lazy.filter { self.contains($0) }
    }

    var lowestIndex: Int? {
        (0..<self.count).first { self.contains($0) }
    }

    var highestIndex: Int? {
        (0..<self.count).reversed().first { self.contains($0) }
    }
}
