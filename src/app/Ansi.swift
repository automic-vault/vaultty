import Foundation

enum Ansi {
    static func visibleText(from text: String) -> String {
        var output = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            if ch == "\u{1B}" {
                consumeEscape(&iterator)
                continue
            }
            if ch == "\r" {
                output.append("\n")
                continue
            }
            output.append(ch)
        }
        return output
    }

    private static func consumeEscape(_ iterator: inout String.Iterator) {
        guard let first = iterator.next() else { return }
        if first == "]" {
            while let ch = iterator.next() {
                if ch == "\u{7}" { return }
                if ch == "\u{1B}" {
                    _ = iterator.next()
                    return
                }
            }
            return
        }
        if first == "[" {
            while let ch = iterator.next() {
                if ("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~").contains(ch) {
                    return
                }
            }
        }
    }
}
