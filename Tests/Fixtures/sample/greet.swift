#!/usr/bin/env -S swx run
// swx-dependencies:
// .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
// .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")

import ArgumentParser
import DequeModule

struct Greet: ParsableCommand {
    @Argument var names: [String]

    func run() {
        var queue = Deque(names)
        while let name = queue.popFirst() { print("Hello, \(name)!") }
    }
}

Greet.main()
