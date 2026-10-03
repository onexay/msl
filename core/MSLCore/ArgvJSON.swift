// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Edits the `"enable-proposed-api"` list in an IDE's `argv.json`
/// (`msl --manage-ide`). The file is JSON with comments, and the IDE owns
/// other keys in it (crash reporter id, …), so it is edited as text: only the
/// one member changes, and comments and formatting elsewhere are kept.
public enum ArgvJSON {
    public static let key = "enable-proposed-api"
    static let marker = "// Added by msl --manage-ide: lets the MSL extension use the proposed resolvers API."

    /// Whether `id` is in the enable-proposed-api list.
    public static func isEnabled(_ id: String, in text: String?) -> Bool {
        guard let text, let m = Scanner(text).member(key) else { return false }
        return m.ids.contains(id)
    }

    /// `text` with `id` added to the list (the key is created if needed; a
    /// missing or empty file becomes a minimal object). Unchanged if present.
    public static func enabling(_ id: String, in text: String?) throws -> String {
        let text = text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "{\n\t\(marker)\n\t\"\(key)\": [\"\(id)\"]\n}\n"
        }
        let s = Scanner(text)
        guard let obj = s.topObject() else { throw EditError.notAnObject }
        if let m = s.member(key) {
            if m.ids.contains(id) { return text }
            guard let arr = m.array else { throw EditError.notAnArray }
            let insert = m.ids.isEmpty ? "\"\(id)\"" : ", \"\(id)\""
            return s.replacing(arr.close..<arr.close, with: insert)
        }
        let entry = "\n\t\(marker)\n\t\"\(key)\": [\"\(id)\"]\n"
        guard let last = s.lastSignificant(before: obj.close, after: obj.open) else {
            return s.replacing(obj.close..<obj.close, with: entry)  // {}
        }
        if s.chars[last] == "," {
            return s.replacing(obj.close..<obj.close, with: entry)  // trailing comma already there
        }
        // Comma and the new member right after the last value; whatever
        // followed it (comments, blank lines) stays as it was.
        // A comment after the value on the same line stays with the value.
        let lastEnd = s.chars[last] == "\"" ? s.skipString(last) : last + 1
        let eol = s.lineEnd(lastEnd)
        let restOfLine = s.string(lastEnd..<eol).trimmingCharacters(in: .whitespaces)
        let at = restOfLine.isEmpty || restOfLine.hasPrefix("//") ? eol : lastEnd
        return s.string(0..<lastEnd) + "," + s.string(lastEnd..<at)
            + "\n\n\t\(marker)\n\t\"\(key)\": [\"\(id)\"]" + s.string(at..<s.chars.count)
    }

    /// `text` without `id` in the list; the member (and the marker comment
    /// msl added) is removed when no ids are left. Unchanged if absent.
    public static func disabling(_ id: String, in text: String?) throws -> String? {
        guard let text else { return nil }
        let s = Scanner(text)
        guard let m = s.member(key), m.ids.contains(id) else { return text }
        guard let arr = m.array else { throw EditError.notAnArray }
        let rest = m.ids.filter { $0 != id }
        if !rest.isEmpty {
            let list = rest.map { "\"\($0)\"" }.joined(separator: ", ")
            return s.replacing(arr.open..<(arr.close + 1), with: "[\(list)]")
        }
        // Remove the whole member (on whole lines when it has lines of its
        // own) with one separating comma: the one after it, or, for the last
        // member, the one before it. Then the marker line and the blank line
        // that enabling added above it.
        var start = m.keyStart
        var end = arr.close + 1
        var dropComma: Int?
        if let next = s.nextSignificant(from: end), s.chars[next] == "," {
            end = next + 1
        } else if let prev = s.lastSignificant(before: start, after: s.topObject()?.open ?? -1), s.chars[prev] == "," {
            dropComma = prev
        }
        let lineStart = s.lineStart(start)
        if s.string(lineStart..<start).allSatisfy({ $0 == " " || $0 == "\t" }) { start = lineStart }
        let lineEnd = s.lineEnd(end)
        if start == lineStart, s.string(end..<lineEnd).allSatisfy({ $0 == " " || $0 == "\t" }) {
            end = min(lineEnd + 1, s.chars.count)
        }
        var head = s.string(0..<start)
        if let c = dropComma { head = s.string(0..<c) + s.string((c + 1)..<start) }
        let lines = head.components(separatedBy: "\n")
        if lines.count >= 2, lines[lines.count - 2].trimmingCharacters(in: .whitespaces) == marker, lines.last == "" {
            var kept = Array(lines.dropLast(2))
            if kept.count >= 2 && kept.last == "" { kept.removeLast() }  // the blank line above it
            head = kept.joined(separator: "\n") + "\n"
        }
        return head + s.string(end..<s.chars.count)
    }

    public enum EditError: Error, Equatable {
        case notAnObject
        case notAnArray
    }

    /// A minimal JSONC scanner: strings, // and /* */ comments, and nesting.
    struct Scanner {
        let chars: [Character]
        init(_ text: String) { chars = Array(text) }

        func string(_ r: Range<Int>) -> String { String(chars[r]) }
        func replacing(_ r: Range<Int>, with s: String) -> String { string(0..<r.lowerBound) + s + string(r.upperBound..<chars.count) }

        /// Index just past a string starting at `i` (a `"`).
        func skipString(_ i: Int) -> Int {
            var j = i + 1
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "\"" { return j + 1 }
                j += 1
            }
            return j
        }

        /// Index past a comment at `i`, or nil if there is none.
        func skipComment(_ i: Int) -> Int? {
            guard i + 1 < chars.count, chars[i] == "/" else { return nil }
            if chars[i + 1] == "/" {
                var j = i + 2
                while j < chars.count, chars[j] != "\n" { j += 1 }
                return j
            }
            if chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                return min(j + 2, chars.count)
            }
            return nil
        }

        /// Significant (non-space, non-comment) token starts, with nesting depth.
        func tokens() -> [(index: Int, depth: Int)] {
            var out: [(Int, Int)] = []
            var depth = 0
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if let j = skipComment(i) { i = j; continue }
                if c == "}" || c == "]" { depth -= 1 }
                out.append((i, depth))
                if c == "{" || c == "[" { depth += 1 }
                i = c == "\"" ? skipString(i) : i + 1
            }
            return out
        }

        func topObject() -> (open: Int, close: Int)? {
            let t = tokens()
            guard let first = t.first, chars[first.index] == "{",
                  let close = t.last(where: { $0.depth == 0 && chars[$0.index] == "}" }) else { return nil }
            return (first.index, close.index)
        }

        struct Member {
            var keyStart: Int
            var array: (open: Int, close: Int)?
            var ids: [String]
        }

        /// A top-level member named `name`, with its array value's bounds and strings.
        func member(_ name: String) -> Member? {
            let t = tokens()
            for (n, tok) in t.enumerated() where tok.depth == 1 && chars[tok.index] == "\"" {
                let end = skipString(tok.index)
                guard string((tok.index + 1)..<(end - 1)) == name,
                      n + 2 < t.count, chars[t[n + 1].index] == ":" else { continue }
                let v = t[n + 2]
                guard chars[v.index] == "[" else { return Member(keyStart: tok.index, array: nil, ids: []) }
                var ids: [String] = []
                var k = n + 3
                while k < t.count, !(chars[t[k].index] == "]" && t[k].depth == 1) {
                    if chars[t[k].index] == "\"" {
                        ids.append(string((t[k].index + 1)..<(skipString(t[k].index) - 1)))
                    }
                    k += 1
                }
                guard k < t.count else { return nil }
                return Member(keyStart: tok.index, array: (v.index, t[k].index), ids: ids)
            }
            return nil
        }

        func lastSignificant(before i: Int, after lower: Int) -> Int? {
            tokens().last { $0.index < i && $0.index > lower }?.index
        }

        func nextSignificant(from i: Int) -> Int? {
            tokens().first { $0.index >= i }?.index
        }

        func lineStart(_ i: Int) -> Int {
            var j = i
            while j > 0, chars[j - 1] != "\n" { j -= 1 }
            return j
        }

        func lineEnd(_ i: Int) -> Int {
            var j = i
            while j < chars.count, chars[j] != "\n" { j += 1 }
            return j
        }
    }
}
