import AppKit
import Foundation

enum Ansi {
    struct TerminalScreenState {
        let text: String
        let attributedText: NSAttributedString
        let isAlternateScreenActive: Bool
        let isApplicationCursorModeActive: Bool
    }

    struct StyledOutput {
        let plainText: String
        let attributedText: NSAttributedString
    }

    static func emptyAttributedOutput() -> NSAttributedString {
        NSAttributedString(string: " ", attributes: TextStyle().attributes())
    }

    final class StyledTextRenderer {
        private var pending = ""
        private var style = TextStyle()
        private var lines: [[Cell]] = [[]]
        private var cursorRow = 0
        private var cursorCol = 0
        private var savedCursorRow = 0
        private var savedCursorCol = 0

        func reset() {
            pending.removeAll()
            style = TextStyle()
            lines = [[]]
            cursorRow = 0
            cursorCol = 0
            savedCursorRow = 0
            savedCursorCol = 0
        }

        func process(_ text: String) -> StyledOutput {
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
                    put("\t")
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

            return renderedOutput()
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
                    if scalars[cursor].value == 0x1B {
                        guard cursor + 1 < scalars.count else { return false }
                        if scalars[cursor + 1] == "\\" {
                            index = cursor + 2
                            return true
                        }
                    }
                    cursor += 1
                }
                return false
            }

            if "()*+-./".contains(Character(String(introducer))) {
                guard index + 2 < scalars.count else { return false }
                index += 3
                return true
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
                cursorRow = max(0, cursorRow - 1)
            case "c":
                reset()
            default:
                break
            }
            index += 2
            return true
        }

        private func handleCSI(body: String, final: Character) {
            let privateMode = body.first == "?"
            guard !privateMode else { return }

            let parameters = parseParameters(body)
            switch final {
            case "A":
                cursorRow = max(0, cursorRow - parameter(parameters, at: 0, defaultValue: 1))
            case "B":
                cursorRow += parameter(parameters, at: 0, defaultValue: 1)
                ensureCursorRow()
            case "C":
                cursorCol += parameter(parameters, at: 0, defaultValue: 1)
            case "D":
                cursorCol = max(0, cursorCol - parameter(parameters, at: 0, defaultValue: 1))
            case "E":
                cursorRow += parameter(parameters, at: 0, defaultValue: 1)
                cursorCol = 0
                ensureCursorRow()
            case "F":
                cursorRow = max(0, cursorRow - parameter(parameters, at: 0, defaultValue: 1))
                cursorCol = 0
            case "G":
                cursorCol = max(0, parameter(parameters, at: 0, defaultValue: 1) - 1)
            case "H", "f":
                cursorRow = max(0, parameter(parameters, at: 0, defaultValue: 1) - 1)
                cursorCol = max(0, parameter(parameters, at: 1, defaultValue: 1) - 1)
                ensureCursorRow()
            case "J":
                eraseDisplay(parameter(parameters, at: 0, defaultValue: 0))
            case "K":
                eraseLine(parameter(parameters, at: 0, defaultValue: 0))
            case "X":
                eraseCharacters(parameter(parameters, at: 0, defaultValue: 1))
            case "m":
                style.applySGR(parameters)
            case "s":
                saveCursor()
            case "u":
                restoreCursor()
            default:
                break
            }
        }

        private func put(_ value: String) {
            ensureCursorRow()
            while lines[cursorRow].count < cursorCol {
                lines[cursorRow].append(Cell(text: " ", style: style))
            }
            if cursorCol < lines[cursorRow].count {
                lines[cursorRow][cursorCol] = Cell(text: value, style: style)
            } else {
                lines[cursorRow].append(Cell(text: value, style: style))
            }
            cursorCol += 1
        }

        private func lineFeed() {
            cursorRow += 1
            cursorCol = 0
            ensureCursorRow()
        }

        private func ensureCursorRow() {
            while cursorRow >= lines.count {
                lines.append([])
            }
        }

        private func eraseDisplay(_ mode: Int) {
            switch mode {
            case 0:
                eraseLine(0)
                if cursorRow + 1 < lines.count {
                    lines.removeSubrange((cursorRow + 1)..<lines.count)
                }
            case 1:
                eraseLine(1)
                if cursorRow > 0 {
                    for row in 0..<cursorRow {
                        lines[row] = []
                    }
                }
            case 2, 3:
                lines = [[]]
                cursorRow = 0
                cursorCol = 0
            default:
                break
            }
        }

        private func eraseLine(_ mode: Int) {
            ensureCursorRow()
            switch mode {
            case 0:
                if cursorCol < lines[cursorRow].count {
                    lines[cursorRow].removeSubrange(cursorCol..<lines[cursorRow].count)
                }
            case 1:
                while lines[cursorRow].count <= cursorCol {
                    lines[cursorRow].append(Cell(text: " ", style: style))
                }
                for col in 0...cursorCol {
                    lines[cursorRow][col] = Cell(text: " ", style: style)
                }
            case 2:
                lines[cursorRow] = []
            default:
                break
            }
        }

        private func eraseCharacters(_ count: Int) {
            guard count > 0 else { return }
            ensureCursorRow()
            let end = min(lines[cursorRow].count, cursorCol + count)
            guard cursorCol < end else { return }
            for col in cursorCol..<end {
                lines[cursorRow][col] = Cell(text: " ", style: style)
            }
        }

        private func saveCursor() {
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
        }

        private func restoreCursor() {
            cursorRow = max(0, savedCursorRow)
            cursorCol = max(0, savedCursorCol)
            ensureCursorRow()
        }

        private func renderedOutput() -> StyledOutput {
            let attributed = NSMutableAttributedString()
            var plain = ""

            for (rowIndex, line) in lines.enumerated() {
                for cell in line {
                    plain.append(cell.text)
                    attributed.append(NSAttributedString(string: cell.text, attributes: cell.style.attributes()))
                }
                if rowIndex < lines.count - 1 {
                    plain.append("\n")
                    attributed.append(NSAttributedString(string: "\n", attributes: TextStyle().attributes()))
                }
            }

            return StyledOutput(plainText: plain, attributedText: attributed)
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
    }

    final class TerminalScreen {
        private var rows: Int
        private var cols: Int
        private var cells: [[Cell]]
        private var cursorRow = 0
        private var cursorCol = 0
        private var savedCursorRow = 0
        private var savedCursorCol = 0
        private var pending = ""
        private var isAlternateScreenActive = false
        private var isApplicationCursorModeActive = false
        private var wrapsAtRightMargin = true
        private var style = TextStyle()

        init(rows: Int, cols: Int) {
            self.rows = max(1, rows)
            self.cols = max(1, cols)
            self.cells = Array(
                repeating: Array(repeating: Cell(), count: self.cols),
                count: self.rows
            )
        }

        func resize(rows newRows: Int, cols newCols: Int) {
            let clampedRows = max(1, newRows)
            let clampedCols = max(1, newCols)
            guard clampedRows != rows || clampedCols != cols else { return }

            var resized = Array(
                repeating: Array(repeating: Cell(), count: clampedCols),
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
            style = TextStyle()
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
                attributedText: renderedAttributedText(),
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
                    if scalars[cursor].value == 0x1B {
                        guard cursor + 1 < scalars.count else { return false }
                        if scalars[cursor + 1] == "\\" {
                            index = cursor + 2
                            return true
                        }
                    }
                    cursor += 1
                }
                return false
            }

            if "()*+-./".contains(Character(String(introducer))) {
                guard index + 2 < scalars.count else { return false }
                index += 3
                return true
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
            case "m":
                style.applySGR(parameters)
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
            cells[cursorRow][cursorCol] = Cell(text: value, style: style)
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
                repeating: Array(repeating: Cell(), count: cols),
                count: rows
            )
        }

        private func eraseDisplay(_ mode: Int) {
            switch mode {
            case 0:
                eraseLine(0)
                if cursorRow + 1 < rows {
                    for row in (cursorRow + 1)..<rows {
                        cells[row] = blankLine(style: style)
                    }
                }
            case 1:
                eraseLine(1)
                if cursorRow > 0 {
                    for row in 0..<cursorRow {
                        cells[row] = blankLine(style: style)
                    }
                }
            case 2, 3:
                cells = Array(
                    repeating: blankLine(style: style),
                    count: rows
                )
            default:
                break
            }
        }

        private func eraseLine(_ mode: Int) {
            switch mode {
            case 0:
                for col in cursorCol..<cols {
                    cells[cursorRow][col] = Cell(text: " ", style: style)
                }
            case 1:
                for col in 0...cursorCol {
                    cells[cursorRow][col] = Cell(text: " ", style: style)
                }
            case 2:
                cells[cursorRow] = blankLine(style: style)
            default:
                break
            }
        }

        private func eraseCharacters(_ count: Int) {
            guard count > 0 else { return }
            for col in cursorCol..<min(cols, cursorCol + count) {
                cells[cursorRow][col] = Cell(text: " ", style: style)
            }
        }

        private func insertCharacters(_ count: Int) {
            let count = min(max(0, count), cols - cursorCol)
            guard count > 0 else { return }
            var line = cells[cursorRow]
            for _ in 0..<count {
                line.insert(Cell(text: " ", style: style), at: cursorCol)
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
                line.append(Cell(text: " ", style: style))
            }
            cells[cursorRow] = line
        }

        private func insertLines(_ count: Int) {
            let count = min(max(0, count), rows - cursorRow)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.insert(blankLine(style: style), at: cursorRow)
                _ = cells.popLast()
            }
        }

        private func deleteLines(_ count: Int) {
            let count = min(max(0, count), rows - cursorRow)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.remove(at: cursorRow)
                cells.append(blankLine(style: style))
            }
        }

        private func scrollUp(_ count: Int) {
            let count = min(max(0, count), rows)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.removeFirst()
                cells.append(blankLine(style: style))
            }
        }

        private func scrollDown(_ count: Int) {
            let count = min(max(0, count), rows)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.removeLast()
                cells.insert(blankLine(style: style), at: 0)
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
            let lines = renderedRows().map { row in
                row.map(\.text).joined()
            }
            return lines.isEmpty ? " " : lines.joined(separator: "\n")
        }

        private func renderedAttributedText() -> NSAttributedString {
            let rows = renderedRows()
            guard !rows.isEmpty else {
                return Ansi.emptyAttributedOutput()
            }

            let output = NSMutableAttributedString()
            for (rowIndex, row) in rows.enumerated() {
                for cell in row {
                    output.append(NSAttributedString(string: cell.text, attributes: cell.style.attributes()))
                }
                if rowIndex < rows.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: TextStyle().attributes()))
                }
            }
            return output
        }

        private func renderedRows() -> [[Cell]] {
            var lines = cells.map { row in
                var text = row
                while text.last?.text == " " {
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
            return lines
        }

        private func blankLine(style: TextStyle = TextStyle()) -> [Cell] {
            Array(repeating: Cell(text: " ", style: style), count: cols)
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
        StyledTextRenderer().process(text).plainText
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

    private struct Cell: Equatable {
        var text = " "
        var style = TextStyle()
    }

    private struct TextStyle: Equatable {
        var foreground: TerminalColor?
        var background: TerminalColor?
        var isBold = false
        var isDim = false
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
        var isInverse = false

        mutating func applySGR(_ parameters: [Int?]) {
            let parameters = parameters.isEmpty ? [0] : parameters
            var index = 0

            while index < parameters.count {
                let parameter = parameters[index] ?? 0
                switch parameter {
                case 0:
                    self = TextStyle()
                    index += 1
                case 1:
                    isBold = true
                    index += 1
                case 2:
                    isDim = true
                    index += 1
                case 3:
                    isItalic = true
                    index += 1
                case 4:
                    isUnderlined = true
                    index += 1
                case 7:
                    isInverse = true
                    index += 1
                case 9:
                    isStruckThrough = true
                    index += 1
                case 21, 22:
                    isBold = false
                    isDim = false
                    index += 1
                case 23:
                    isItalic = false
                    index += 1
                case 24:
                    isUnderlined = false
                    index += 1
                case 27:
                    isInverse = false
                    index += 1
                case 29:
                    isStruckThrough = false
                    index += 1
                case 30...37:
                    foreground = .palette(parameter - 30)
                    index += 1
                case 39:
                    foreground = nil
                    index += 1
                case 40...47:
                    background = .palette(parameter - 40)
                    index += 1
                case 49:
                    background = nil
                    index += 1
                case 90...97:
                    foreground = .palette(parameter - 90 + 8)
                    index += 1
                case 100...107:
                    background = .palette(parameter - 100 + 8)
                    index += 1
                case 38, 48:
                    index = applyExtendedColor(parameters, at: index)
                default:
                    index += 1
                }
            }
        }

        func attributes() -> [NSAttributedString.Key: Any] {
            var font = NSFont.monospacedSystemFont(ofSize: 12, weight: isBold ? .semibold : .regular)
            if isItalic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            var foregroundColor = foreground?.nsColor ?? .labelColor
            var backgroundColor = background?.nsColor

            if isDim {
                foregroundColor = foregroundColor.withAlphaComponent(0.62)
            }

            if isInverse {
                let originalForeground = foregroundColor
                foregroundColor = backgroundColor ?? .black
                backgroundColor = originalForeground
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foregroundColor
            ]
            if let backgroundColor {
                attributes[.backgroundColor] = backgroundColor
            }
            if isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if isStruckThrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        }

        private mutating func applyExtendedColor(_ parameters: [Int?], at index: Int) -> Int {
            guard parameters.indices.contains(index + 1),
                  let mode = parameters[index + 1]
            else {
                return index + 1
            }

            let appliesToForeground = parameters[index] == 38
            switch mode {
            case 5:
                var cursor = index + 2
                while parameters.indices.contains(cursor) {
                    if let colorIndex = parameters[cursor] {
                        setColor(.palette(colorIndex), foreground: appliesToForeground)
                        return cursor + 1
                    }
                    cursor += 1
                }
                return index + 2
            case 2:
                var cursor = index + 2
                var components: [Int] = []
                while parameters.indices.contains(cursor), components.count < 3 {
                    if let component = parameters[cursor] {
                        components.append(min(max(0, component), 255))
                    }
                    cursor += 1
                }
                if components.count == 3 {
                    setColor(
                        .rgb(components[0], components[1], components[2]),
                        foreground: appliesToForeground
                    )
                    return cursor
                }
                return index + 2
            default:
                return index + 2
            }
        }

        private mutating func setColor(_ color: TerminalColor, foreground: Bool) {
            if foreground {
                self.foreground = color
            } else {
                self.background = color
            }
        }
    }

    private enum TerminalColor: Equatable {
        case palette(Int)
        case rgb(Int, Int, Int)

        var nsColor: NSColor {
            switch self {
            case .palette(let index):
                return Self.paletteColor(index)
            case .rgb(let red, let green, let blue):
                return Self.rgb(red, green, blue)
            }
        }

        private static func paletteColor(_ index: Int) -> NSColor {
            let clamped = min(max(0, index), 255)
            let base: [NSColor] = [
                rgb(0, 0, 0),
                rgb(205, 49, 49),
                rgb(13, 188, 121),
                rgb(229, 229, 16),
                rgb(36, 114, 200),
                rgb(188, 63, 188),
                rgb(17, 168, 205),
                rgb(229, 229, 229),
                rgb(102, 102, 102),
                rgb(241, 76, 76),
                rgb(35, 209, 139),
                rgb(245, 245, 67),
                rgb(59, 142, 234),
                rgb(214, 112, 214),
                rgb(41, 184, 219),
                rgb(255, 255, 255)
            ]

            if clamped < base.count {
                return base[clamped]
            }

            if clamped < 232 {
                let color = clamped - 16
                let levels = [0, 95, 135, 175, 215, 255]
                let red = levels[color / 36]
                let green = levels[(color / 6) % 6]
                let blue = levels[color % 6]
                return rgb(red, green, blue)
            }

            let level = 8 + (clamped - 232) * 10
            return rgb(level, level, level)
        }

        private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
            NSColor(
                calibratedRed: CGFloat(min(max(0, red), 255)) / 255,
                green: CGFloat(min(max(0, green), 255)) / 255,
                blue: CGFloat(min(max(0, blue), 255)) / 255,
                alpha: 1
            )
        }
    }

    private static func parseParameters(_ body: String) -> [Int?] {
        guard !body.isEmpty else { return [] }
        return body.split(omittingEmptySubsequences: false) { ch in
            ch == ";" || ch == ":"
        }.map { part in
            Int(part)
        }
    }
}
