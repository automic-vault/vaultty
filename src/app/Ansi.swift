import Foundation

enum Ansi {
    static func alternateScreenSwitches(in text: String) -> [Bool] {
        let bytes = Array(text.utf8)
        var switches: [Bool] = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x1B,
                  index + 2 < bytes.count,
                  bytes[index + 1] == 0x5B
            else {
                index += 1
                continue
            }

            var cursor = index + 2
            var parameters: [UInt8] = []
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte >= 0x40 && byte <= 0x7E {
                    if byte == 0x68 || byte == 0x6C,
                       isAlternateScreenMode(parameters) {
                        switches.append(byte == 0x68)
                    }
                    index = cursor + 1
                    break
                }
                parameters.append(byte)
                cursor += 1
            }

            if cursor >= bytes.count {
                break
            }
        }

        return switches
    }

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

    private static func isAlternateScreenMode(_ parameters: [UInt8]) -> Bool {
        guard parameters.first == 0x3F,
              let body = String(bytes: parameters.dropFirst(), encoding: .ascii)
        else {
            return false
        }
        return body.split(separator: ";").contains { mode in
            mode == "47" || mode == "1047" || mode == "1049"
        }
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
