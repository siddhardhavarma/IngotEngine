//
//  Log.swift
//  IngotEngine
//
//  §4.2 Core/Foundation — Logging & assertions.
//
//  A minimal logging system with severity levels. All engine output
//  goes through here so it can be filtered, redirected to the chat
//  panel, or suppressed in release builds.
//

import Foundation

enum Log {

    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The minimum level to print. Messages below this are silenced.
    /// Set to .warning in release builds to reduce noise.
    static var minimumLevel: Level = .debug

    /// Optional sink for routing log messages to the editor's chat panel.
    static var editorSink: ((String) -> Void)?

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        emit(.debug, message, file: file, line: line)
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        emit(.info, message, file: file, line: line)
    }

    static func warning(_ message: String, file: String = #file, line: Int = #line) {
        emit(.warning, message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        emit(.error, message, file: file, line: line)
    }

    private static func emit(_ level: Level, _ message: String, file: String, line: Int) {
        guard level >= minimumLevel else { return }

        let fileName = (file as NSString).lastPathComponent
        let prefix: String
        switch level {
        case .debug:   prefix = "🔍"
        case .info:    prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error:   prefix = "❌"
        }

        let formatted = "\(prefix) [\(fileName):\(line)] \(message)"
        print(formatted)
        editorSink?(formatted)
    }
}
