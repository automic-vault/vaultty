import Foundation

enum Ansi {
    struct TerminalScreenState {
        let text: String
        let isAlternateScreenActive: Bool
        let isApplicationCursorModeActive: Bool
    }

    final class TerminalScreen {
        private var rows: Int
        private var cols: Int
        private var cells: [[String]]
        private var cursorRow = 0
        private var cursorCol = 0
        private var savedCursorRow = 0
        private var savedCursorCol = 0
        private var pending = ""
        private var isAlternateScreenActive = false
        private var isApplicationCursorModeActive = false
        private var wrapsAtRightMargin = true

        init(rows: Int, cols: Int) {
            self.rows = max(1, rows)
            self.cols = max(1, cols)
            self.cells = Array(
                repeating: Array(repeating: " ", count: self.cols),
                count: self.rows
            )
        }

        func resize(rows newRows: Int, cols newCols: Int) {
            let clampedRows = max(1, newRows)
            let clampedCols = max(1, newCols)
            guard clampedRows != rows || clampedCols != cols else { return }

            var resized = Array(
                repeating: Array(repeating: " ", count: clampedCols),
                count: clampedRows
            )
            for row in 0..<min(rows, clampedRows) {
                for col in 0..<min(cols, clampedCols) {
                    resized[row][col] = cells[row][col]
                }
            }
            rows = clampedRows
            cols = clampedCols
            cells = resized
            cursorRow = min(cursorRow, rows - 1)
            cursorCol = min(cursorCol, cols - 1)
            savedCursorRow = min(savedCursorRow, rows - 1)
            savedCursorCol = min(savedCursorCol, cols - 1)
        }

        func resetForCommand() {
            clear()
            cursorRow = 0
            cursorCol = 0
            savedCursorRow = 0
            savedCursorCol = 0
            pending.removeAll()
            isAlternateScreenActive = false
            isApplicationCursorModeActive = false
            wrapsAtRightMargin = true
        }

        @discardableResult
        func process(_ text: String) -> TerminalScreenState {
            let scalars = Array((pending + text).unicodeScalars)
            pending.removeAll()

            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                switch scalar.value {
                case 0x1B:
                    guard processEscape(scalars, index: &index) else {
                        pending = String(String.UnicodeScalarView(scalars[index...]))
                        index = scalars.count
                        continue
                    }
                case 0x07:
                    index += 1
                case 0x08:
                    cursorCol = max(0, cursorCol - 1)
                    index += 1
                case 0x09:
                    cursorCol = min(cols - 1, cursorCol + (8 - cursorCol % 8))
                    index += 1
                case 0x0A, 0x0B, 0x0C:
                    lineFeed()
                    index += 1
                case 0x0D:
                    cursorCol = 0
                    index += 1
                case 0x00..<0x20, 0x7F:
                    index += 1
                default:
                    put(String(scalar))
                    index += 1
                }
            }

            return state
        }

        var state: TerminalScreenState {
            TerminalScreenState(
                text: renderedText(),
                isAlternateScreenActive: isAlternateScreenActive,
                isApplicationCursorModeActive: isApplicationCursorModeActive
            )
        }

        private func processEscape(_ scalars: [Unicode.Scalar], index: inout Int) -> Bool {
            guard index + 1 < scalars.count else { return false }
            let introducer = scalars[index + 1]

            if introducer == "[" {
                var cursor = index + 2
                while cursor < scalars.count {
                    let value = scalars[cursor].value
                    if value >= 0x40 && value <= 0x7E {
                        let body = String(String.UnicodeScalarView(scalars[(index + 2)..<cursor]))
                        handleCSI(body: body, final: Character(String(scalars[cursor])))
                        index = cursor + 1
                        return true
                    }
                    cursor += 1
                }
                return false
            }

            if introducer == "]" {
                var cursor = index + 2
                while cursor < scalars.count {
                    if scalars[cursor].value == 0x07 {
                        index = cursor + 1
                        return true
                    }
                    if scalars[cursor].value == 0x1B,
                       cursor + 1 < scalars.count,
                       scalars[cursor + 1] == "\\" {
                        index = cursor + 2
                        return true
                    }
                    cursor += 1
                }
                return false
            }

            switch introducer {
            case "7":
                saveCursor()
            case "8":
                restoreCursor()
            case "D":
                lineFeed()
            case "E":
                cursorCol = 0
                lineFeed()
            case "M":
                reverseIndex()
            case "c":
                resetForCommand()
            default:
                break
            }
            index += 2
            return true
        }

        private func handleCSI(body: String, final: Character) {
            let privateMode = body.first == "?"
            let parameters = parseParameters(privateMode ? String(body.dropFirst()) : body)

            if privateMode {
                handlePrivateMode(parameters: parameters, final: final)
                return
            }

            switch final {
            case "A":
                cursorRow = max(0, cursorRow - parameter(parameters, at: 0, defaultValue: 1))
            case "B":
                cursorRow = min(rows - 1, cursorRow + parameter(parameters, at: 0, defaultValue: 1))
            case "C":
                cursorCol = min(cols - 1, cursorCol + parameter(parameters, at: 0, defaultValue: 1))
            case "D":
                cursorCol = max(0, cursorCol - parameter(parameters, at: 0, defaultValue: 1))
            case "E":
                cursorRow = min(rows - 1, cursorRow + parameter(parameters, at: 0, defaultValue: 1))
                cursorCol = 0
            case "F":
                cursorRow = max(0, cursorRow - parameter(parameters, at: 0, defaultValue: 1))
                cursorCol = 0
            case "G":
                cursorCol = clamp(parameter(parameters, at: 0, defaultValue: 1) - 1, max: cols - 1)
            case "H", "f":
                cursorRow = clamp(parameter(parameters, at: 0, defaultValue: 1) - 1, max: rows - 1)
                cursorCol = clamp(parameter(parameters, at: 1, defaultValue: 1) - 1, max: cols - 1)
            case "J":
                eraseDisplay(parameter(parameters, at: 0, defaultValue: 0))
            case "K":
                eraseLine(parameter(parameters, at: 0, defaultValue: 0))
            case "L":
                insertLines(parameter(parameters, at: 0, defaultValue: 1))
            case "M":
                deleteLines(parameter(parameters, at: 0, defaultValue: 1))
            case "P":
                deleteCharacters(parameter(parameters, at: 0, defaultValue: 1))
            case "S":
                scrollUp(parameter(parameters, at: 0, defaultValue: 1))
            case "T":
                scrollDown(parameter(parameters, at: 0, defaultValue: 1))
            case "X":
                eraseCharacters(parameter(parameters, at: 0, defaultValue: 1))
            case "@":
                insertCharacters(parameter(parameters, at: 0, defaultValue: 1))
            case "d":
                cursorRow = clamp(parameter(parameters, at: 0, defaultValue: 1) - 1, max: rows - 1)
            case "s":
                saveCursor()
            case "u":
                restoreCursor()
            default:
                break
            }
        }

        private func handlePrivateMode(parameters: [Int?], final: Character) {
            for parameter in parameters {
                guard let parameter else { continue }
                switch parameter {
                case 1:
                    isApplicationCursorModeActive = final == "h"
                case 7:
                    wrapsAtRightMargin = final == "h"
                case 47, 1047, 1049:
                    isAlternateScreenActive = final == "h"
                    if final == "h" {
                        clear()
                        cursorRow = 0
                        cursorCol = 0
                    }
                default:
                    break
                }
            }
        }

        private func put(_ value: String) {
            cells[cursorRow][cursorCol] = value
            if cursorCol == cols - 1 {
                if wrapsAtRightMargin {
                    cursorCol = 0
                    lineFeed()
                }
            } else {
                cursorCol += 1
            }
        }

        private func lineFeed() {
            if cursorRow == rows - 1 {
                scrollUp(1)
            } else {
                cursorRow += 1
            }
        }

        private func reverseIndex() {
            if cursorRow == 0 {
                scrollDown(1)
            } else {
                cursorRow -= 1
            }
        }

        private func clear() {
            cells = Array(
                repeating: Array(repeating: " ", count: cols),
                count: rows
            )
        }

        private func eraseDisplay(_ mode: Int) {
            switch mode {
            case 0:
                eraseLine(0)
                if cursorRow + 1 < rows {
                    for row in (cursorRow + 1)..<rows {
                        cells[row] = blankLine()
                    }
                }
            case 1:
                eraseLine(1)
                if cursorRow > 0 {
                    for row in 0..<cursorRow {
                        cells[row] = blankLine()
                    }
                }
            case 2, 3:
                clear()
            default:
                break
            }
        }

        private func eraseLine(_ mode: Int) {
            switch mode {
            case 0:
                for col in cursorCol..<cols {
                    cells[cursorRow][col] = " "
                }
            case 1:
                for col in 0...cursorCol {
                    cells[cursorRow][col] = " "
                }
            case 2:
                cells[cursorRow] = blankLine()
            default:
                break
            }
        }

        private func eraseCharacters(_ count: Int) {
            guard count > 0 else { return }
            for col in cursorCol..<min(cols, cursorCol + count) {
                cells[cursorRow][col] = " "
            }
        }

        private func insertCharacters(_ count: Int) {
            let count = min(max(0, count), cols - cursorCol)
            guard count > 0 else { return }
            var line = cells[cursorRow]
            for _ in 0..<count {
                line.insert(" ", at: cursorCol)
                _ = line.popLast()
            }
            cells[cursorRow] = line
        }

        private func deleteCharacters(_ count: Int) {
            let count = min(max(0, count), cols - cursorCol)
            guard count > 0 else { return }
            var line = cells[cursorRow]
            for _ in 0..<count {
                line.remove(at: cursorCol)
                line.append(" ")
            }
            cells[cursorRow] = line
        }

        private func insertLines(_ count: Int) {
            let count = min(max(0, count), rows - cursorRow)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.insert(blankLine(), at: cursorRow)
                _ = cells.popLast()
            }
        }

        private func deleteLines(_ count: Int) {
            let count = min(max(0, count), rows - cursorRow)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.remove(at: cursorRow)
                cells.append(blankLine())
            }
        }

        private func scrollUp(_ count: Int) {
            let count = min(max(0, count), rows)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.removeFirst()
                cells.append(blankLine())
            }
        }

        private func scrollDown(_ count: Int) {
            let count = min(max(0, count), rows)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.removeLast()
                cells.insert(blankLine(), at: 0)
            }
        }

        private func saveCursor() {
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
        }

        private func restoreCursor() {
            cursorRow = min(savedCursorRow, rows - 1)
            cursorCol = min(savedCursorCol, cols - 1)
        }

        private func renderedText() -> String {
            var lines = cells.map { row in
                var text = row.joined()
                while text.last == " " {
                    text.removeLast()
                }
                return text
            }
            while lines.first?.isEmpty == true {
                lines.removeFirst()
            }
            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
            return lines.isEmpty ? " " : lines.joined(separator: "\n")
        }

        private func blankLine() -> [String] {
            Array(repeating: " ", count: cols)
        }

        private func parseParameters(_ body: String) -> [Int?] {
            guard !body.isEmpty else { return [] }
            return body.split(separator: ";", omittingEmptySubsequences: false).map { part in
                Int(part)
            }
        }

        private func parameter(_ parameters: [Int?], at index: Int, defaultValue: Int) -> Int {
            guard parameters.indices.contains(index),
                  let value = parameters[index],
                  value != 0
            else {
                return defaultValue
            }
            return value
        }

        private func clamp(_ value: Int, max maxValue: Int) -> Int {
            min(max(0, value), maxValue)
        }
    }

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
