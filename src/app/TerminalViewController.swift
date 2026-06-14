import AppKit
import Foundation

@_silgen_name("vaultty_ghostty_osc_command_type")
private func vaulttyGhosttyOscCommandType(_ payload: UnsafePointer<CChar>) -> Int32

private struct TerminalBlock {
    enum State {
        case running
        case completed(Int32)
    }

    let id: UUID
    let command: String
    let cwd: String
    let startedAt: Date
    var finishedAt: Date?
    var output: String
    var attributedOutput: NSMutableAttributedString
    var outputRevision: Int
    var state: State
}

private enum TahoeGlassPalette {
    static let windowCornerRadius: CGFloat = 22
    static let titleBarHeight: CGFloat = 50
    static let titleTabHeight: CGFloat = 34
    static let titleTabTopInset: CGFloat = titleBarHeight - titleTabHeight
    static let titleTabCornerRadius: CGFloat = max(0, windowCornerRadius - (titleTabTopInset * 0.535)) * 0.8
    static let titleTabBottomInset: CGFloat = 0
    static let titleContentTop: CGFloat = titleTabTopInset + titleTabHeight + titleTabBottomInset
    static let titleTabLeadingInset: CGFloat = 104
    static let titleTabMinimumWidth: CGFloat = 112
    static let titleTabTitleLeadingInset: CGFloat = 16
    static let titleTabTitleTrailingInset: CGFloat = 16
    static let titleTabTitleCloseTrailingInset: CGFloat = 34
    static let titleTabMeasurementSlack: CGFloat = 4
    static let titleTabCloseButtonSize: CGFloat = 16
    static let titleTabCloseButtonTrailingInset: CGFloat = 8
    static let titleTabShieldSize: CGFloat = 13
    static let titleTabShieldTextGap: CGFloat = 3
    static let titleTabShieldBaselineAdjustment: CGFloat = 1
    static let titleHairlineEndpointGap: CGFloat = 1
    static let windowTintStart = NSColor(
        calibratedRed: 0.05,
        green: 0.08,
        blue: 0.18,
        alpha: 0.30
    )
    static let windowTintMid = NSColor(
        calibratedRed: 0.24,
        green: 0.08,
        blue: 0.27,
        alpha: 0.26
    )
    static let windowTintEnd = NSColor(
        calibratedRed: 0.46,
        green: 0.16,
        blue: 0.09,
        alpha: 0.24
    )
    static let topBarTint = NSColor.black.withAlphaComponent(0.26)
    static let surfaceTint = NSColor.black.withAlphaComponent(0.18)
    static let failureSurfaceTint = NSColor.systemRed.withAlphaComponent(0.22)
    static let commandTint = NSColor.black.withAlphaComponent(0.22)
    static let hairline = NSColor.white.withAlphaComponent(0.12)
    static let titleTopHairline = NSColor.white.withAlphaComponent(0.20)
    static let titleText = NSColor.white.withAlphaComponent(0.44)
    static let titleTextActive = NSColor.white.withAlphaComponent(0.62)
    static let titleSegmentHoverFill = NSColor.white.withAlphaComponent(0.045)
}

private final class SeparatorView: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class NonHitTestingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class NonHitTestingVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class CommandInputTextView: NSTextView {
    var onUnmodifiedReturnKey: ((CommandInputTextView) -> Bool)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configurePlainTextInput()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePlainTextInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePlainTextInput()
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }

        resetPlainTextAttributes()
        insertText(text, replacementRange: selectedRange())
        normalizePlainTextStorage()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isPlainReturn = (event.keyCode == 36 || event.keyCode == 76)
            && !flags.contains(.shift)
            && !flags.contains(.command)
            && !flags.contains(.option)
            && !flags.contains(.control)
        if isPlainReturn, onUnmodifiedReturnKey?(self) == true {
            return
        }
        super.keyDown(with: event)
    }

    func resetPlainTextAttributes() {
        typingAttributes = commandTextAttributes
    }

    func normalizePlainTextStorage() {
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard range.length > 0 else {
            resetPlainTextAttributes()
            return
        }
        textStorage?.setAttributes(commandTextAttributes, range: range)
        resetPlainTextAttributes()
    }

    func renderMutedCompletionPreview(mutedRange: NSRange) {
        normalizePlainTextStorage()
        guard mutedRange.length > 0,
              mutedRange.location >= 0,
              mutedRange.location + mutedRange.length <= (string as NSString).length
        else {
            return
        }
        textStorage?.addAttribute(
            .foregroundColor,
            value: mutedCompletionTextColor,
            range: mutedRange
        )
        resetPlainTextAttributes()
    }

    private var commandTextAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: textColor ?? NSColor.labelColor
        ]
    }

    private var mutedCompletionTextColor: NSColor {
        (textColor ?? NSColor.labelColor).withAlphaComponent(0.38)
    }

    private func configurePlainTextInput() {
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        allowsDocumentBackgroundColorChange = false
        resetPlainTextAttributes()
    }
}

private final class ResizeMetricsTooltipView: NSView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 7
        static let minimumHeight: CGFloat = 30
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalPadding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(text: String) -> NSSize {
        label.stringValue = text
        let textSize = (text as NSString).size(withAttributes: [
            .font: label.font ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        ])
        return NSSize(
            width: ceil(textSize.width) + Metrics.horizontalPadding * 2,
            height: max(Metrics.minimumHeight, ceil(textSize.height) + Metrics.verticalPadding * 2)
        )
    }
}

private final class TahoeGlassRootView: NSView {
    private let materialView = NonHitTestingVisualEffectView()
    private let tintView = NonHitTestingView()
    private let tintLayer = CAGradientLayer()
    private let topBarLayer = CAShapeLayer()
    private let topBarSeparatorLayer = CAShapeLayer()

    var onLayout: (() -> Void)?

    var activeTabFrame: CGRect? {
        didSet {
            guard activeTabFrame != oldValue else { return }
            needsLayout = true
        }
    }
    var tabStripFrame: CGRect? {
        didSet {
            guard tabStripFrame != oldValue else { return }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = TahoeGlassPalette.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        materialView.material = .underWindowBackground
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.appearance = NSAppearance(named: .darkAqua)
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView, positioned: .below, relativeTo: nil)

        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView, positioned: .above, relativeTo: materialView)

        tintLayer.colors = [
            TahoeGlassPalette.windowTintStart.cgColor,
            TahoeGlassPalette.windowTintMid.cgColor,
            TahoeGlassPalette.windowTintEnd.cgColor
        ]
        tintLayer.locations = [0, 0.48, 1]
        tintLayer.startPoint = CGPoint(x: 0, y: 0)
        tintLayer.endPoint = CGPoint(x: 1, y: 1)
        tintView.layer?.addSublayer(tintLayer)

        topBarLayer.fillColor = TahoeGlassPalette.topBarTint.cgColor
        topBarLayer.fillRule = .evenOdd
        tintView.layer?.addSublayer(topBarLayer)

        topBarSeparatorLayer.fillColor = nil
        topBarSeparatorLayer.strokeColor = TahoeGlassPalette.hairline.cgColor
        topBarSeparatorLayer.lineWidth = 1
        tintView.layer?.addSublayer(topBarSeparatorLayer)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        onLayout?()
        tintLayer.frame = bounds
        let contentTop = TahoeGlassPalette.titleContentTop
        topBarLayer.frame = bounds
        topBarLayer.path = topBarPath(
            contentTop: contentTop,
            activeTabFrame: activeTabFrame,
            tabStripFrame: tabStripFrame
        )
        topBarSeparatorLayer.frame = bounds
        topBarSeparatorLayer.path = topBarSeparatorPath(
            y: max(0, bounds.height - contentTop),
            activeTabFrame: activeTabFrame
        )
    }

    private func topBarPath(
        contentTop: CGFloat,
        activeTabFrame: CGRect?,
        tabStripFrame: CGRect?
    ) -> CGPath {
        let path = CGMutablePath()
        let topBarFrame = CGRect(
            x: 0,
            y: bounds.height - contentTop,
            width: bounds.width,
            height: contentTop
        )
        path.addRect(topBarFrame)
        if let activeTabFrame {
            let cutoutFrame = activeTabFrame.intersection(topBarFrame)
            if !cutoutFrame.isNull {
                let roundsLeadingCorner = tabStripFrame.map {
                    abs(cutoutFrame.minX - $0.minX) < 0.5
                } ?? false
                let roundsTrailingCorner = tabStripFrame.map {
                    abs(cutoutFrame.maxX - $0.maxX) < 0.5
                } ?? false
                path.addPath(topRoundedRectPath(
                    in: cutoutFrame,
                    radius: TahoeGlassPalette.titleTabCornerRadius,
                    roundsLeadingCorner: roundsLeadingCorner,
                    roundsTrailingCorner: roundsTrailingCorner
                ))
            }
        }

        return path
    }

    private func topRoundedRectPath(
        in rect: CGRect,
        radius requestedRadius: CGFloat,
        roundsLeadingCorner: Bool,
        roundsTrailingCorner: Bool
    ) -> CGPath {
        guard roundsLeadingCorner || roundsTrailingCorner else {
            let path = CGMutablePath()
            path.addRect(rect)
            return path
        }

        let radius = min(requestedRadius, rect.width / 2, rect.height)
        let controlOffset = radius * 0.5522847498307936
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if roundsLeadingCorner {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                control1: CGPoint(x: rect.minX, y: rect.maxY - radius + controlOffset),
                control2: CGPoint(x: rect.minX + radius - controlOffset, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        if roundsTrailingCorner {
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                control1: CGPoint(x: rect.maxX - radius + controlOffset, y: rect.maxY),
                control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + controlOffset)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    private func topBarSeparatorPath(y: CGFloat, activeTabFrame: CGRect?) -> CGPath {
        let path = CGMutablePath()
        guard let activeTabFrame,
              y >= activeTabFrame.minY,
              y <= activeTabFrame.maxY
        else {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            return path
        }

        let endpointGap = TahoeGlassPalette.titleHairlineEndpointGap
        let gapStart = max(0, floor(activeTabFrame.minX) - endpointGap)
        let gapEnd = min(bounds.width, ceil(activeTabFrame.maxX) + endpointGap)
        if gapStart > 0 {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: gapStart, y: y))
        }
        if gapEnd < bounds.width {
            path.move(to: CGPoint(x: gapEnd, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        return path
    }
}

private final class TitleTabBorderView: NSView {
    weak var tabStack: NSStackView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        TahoeGlassPalette.titleTopHairline.setStroke()
        let outline = topRoundedOutlinePath(
            in: bounds.insetBy(dx: 0.5, dy: 0.5),
            radius: TahoeGlassPalette.titleTabCornerRadius
        )
        outline.lineWidth = 1
        outline.stroke()

        TahoeGlassPalette.titleTopHairline.setFill()

        guard let tabStack else { return }
        let visibleSubviews = tabStack.arrangedSubviews.filter { !$0.isHidden }
        let separatorEndpointInset = min(
            TahoeGlassPalette.titleHairlineEndpointGap,
            bounds.height / 2
        )
        for subview in visibleSubviews.dropLast() {
            let rect = subview.convert(subview.bounds, to: self)
            NSRect(
                x: floor(rect.maxX) - 1,
                y: separatorEndpointInset,
                width: 1,
                height: max(0, bounds.height - separatorEndpointInset)
            ).fill()
        }
    }

    private func topRoundedOutlinePath(in rect: NSRect, radius requestedRadius: CGFloat) -> NSBezierPath {
        let radius = min(requestedRadius, rect.width / 2, rect.height)
        let controlOffset = radius * 0.5522847498307936
        let path = NSBezierPath()

        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius - controlOffset),
            controlPoint2: NSPoint(x: rect.minX + radius - controlOffset, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.minY + radius),
            controlPoint1: NSPoint(x: rect.maxX - radius + controlOffset, y: rect.minY),
            controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radius - controlOffset)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))

        return path
    }
}

private final class TitleTabStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class TitleTabCloseButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private func titleSegmentFillPath(
    in rect: NSRect,
    isFlipped: Bool,
    roundsLeadingTopCorner: Bool,
    roundsTrailingTopCorner: Bool
) -> NSBezierPath {
    let radius = min(TahoeGlassPalette.titleTabCornerRadius, rect.width / 2, rect.height)
    let controlOffset = radius * 0.5522847498307936
    let path = NSBezierPath()

    guard roundsLeadingTopCorner || roundsTrailingTopCorner else {
        path.appendRect(rect)
        return path
    }

    if isFlipped {
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        if roundsLeadingTopCorner {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.curve(
                to: NSPoint(x: rect.minX + radius, y: rect.minY),
                controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius - controlOffset),
                controlPoint2: NSPoint(x: rect.minX + radius - controlOffset, y: rect.minY)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }

        if roundsTrailingTopCorner {
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.curve(
                to: NSPoint(x: rect.maxX, y: rect.minY + radius),
                controlPoint1: NSPoint(x: rect.maxX - radius + controlOffset, y: rect.minY),
                controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radius - controlOffset)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }

        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    } else {
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        if roundsLeadingTopCorner {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.curve(
                to: NSPoint(x: rect.minX + radius, y: rect.maxY),
                controlPoint1: NSPoint(x: rect.minX, y: rect.maxY - radius + controlOffset),
                controlPoint2: NSPoint(x: rect.minX + radius - controlOffset, y: rect.maxY)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }

        if roundsTrailingTopCorner {
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
            path.curve(
                to: NSPoint(x: rect.maxX, y: rect.maxY - radius),
                controlPoint1: NSPoint(x: rect.maxX - radius + controlOffset, y: rect.maxY),
                controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY - radius + controlOffset)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }

        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    }

    path.close()
    return path
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SelectableBlockTextField: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class BlockOutputTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class HoverMenuButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHoverAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "..."
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 15, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = TahoeGlassPalette.titleText
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateHoverAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }
}

private final class HoverCopyMarkdownButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHoverAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(
            systemSymbolName: "square.on.square",
            accessibilityDescription: "Copy Markdown"
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        toolTip = "Copy Markdown"
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = TahoeGlassPalette.titleText
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateHoverAppearance() {
        layer?.backgroundColor = (isHovering
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.clear
        ).cgColor
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }
}

private final class BlockView: NSView {
    private enum Metrics {
        static let runningMinimumHeight: CGFloat = 90
    }

    private struct MetadataSegment {
        let text: String
        let color: NSColor
    }

    private let commandLabel = SelectableBlockTextField()
    private let metaLabel = SelectableBlockTextField()
    private let outputView = BlockOutputTextView(frame: .zero)
    private let copyMarkdownButton = HoverCopyMarkdownButton(frame: .zero)
    private let menuButton = HoverMenuButton(frame: .zero)
    private var outputHeightConstraint: NSLayoutConstraint?
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var hasVisibleOutput = false
    private var lastMeasuredOutputWidth: CGFloat = 0
    private var needsOutputHeightMeasurement = true
    private var renderedOutputRevision = -1

    var onCopyCommand: (() -> Void)?
    var onCopyOutput: (() -> Void)?
    var onCopyMarkdown: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        layer?.backgroundColor = TahoeGlassPalette.surfaceTint.cgColor

        commandLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        commandLabel.textColor = .labelColor
        commandLabel.lineBreakMode = .byWordWrapping
        commandLabel.maximumNumberOfLines = 0

        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.maximumNumberOfLines = 1

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.drawsBackground = false
        outputView.textContainerInset = NSSize(width: 0, height: 0)
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.textColor = .labelColor
        outputView.isHorizontallyResizable = false
        outputView.isVerticallyResizable = true
        outputView.textContainer?.lineFragmentPadding = 0
        outputView.textContainer?.lineBreakMode = .byCharWrapping
        outputView.textContainer?.widthTracksTextView = true
        outputView.textContainer?.heightTracksTextView = false
        outputView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setButtonType(.momentaryPushIn)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        copyMarkdownButton.target = self
        copyMarkdownButton.action = #selector(copyMarkdown)
        copyMarkdownButton.setButtonType(.momentaryPushIn)
        copyMarkdownButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(metaLabel)
        header.addSubview(copyMarkdownButton)
        header.addSubview(menuButton)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [header, commandLabel, outputView])
        content.orientation = .vertical
        content.spacing = 0
        content.setCustomSpacing(6, after: commandLabel)
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let outputHeightConstraint = outputView.heightAnchor.constraint(equalToConstant: 0)
        self.outputHeightConstraint = outputHeightConstraint
        let minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.runningMinimumHeight)
        self.minimumHeightConstraint = minimumHeightConstraint
        let contentBottomConstraint = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        contentBottomConstraint.isActive = false
        self.contentBottomConstraint = contentBottomConstraint

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            metaLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            metaLabel.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyMarkdownButton.leadingAnchor, constant: -8),
            copyMarkdownButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            copyMarkdownButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -4),
            copyMarkdownButton.widthAnchor.constraint(equalTo: menuButton.widthAnchor),
            copyMarkdownButton.heightAnchor.constraint(equalTo: menuButton.heightAnchor),
            menuButton.topAnchor.constraint(equalTo: header.topAnchor),
            menuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            menuButton.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            commandLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            outputView.widthAnchor.constraint(equalTo: content.widthAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 36),
            menuButton.heightAnchor.constraint(equalToConstant: 28),
            outputHeightConstraint,
            minimumHeightConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with block: TerminalBlock) {
        commandLabel.stringValue = block.command
        hasVisibleOutput = !block.output.isEmpty
        outputView.isHidden = !hasVisibleOutput
        let output = block.output.isEmpty ? Ansi.emptyAttributedOutput() : block.attributedOutput
        if block.outputRevision != renderedOutputRevision {
            outputView.textStorage?.setAttributedString(output)
            resetOutputViewport()
            renderedOutputRevision = block.outputRevision
            needsOutputHeightMeasurement = true
        }
        updateOutputHeight()

        var metadata = [
            MetadataSegment(text: displayCwd(block.cwd), color: .secondaryLabelColor)
        ]
        switch block.state {
        case .running:
            layer?.backgroundColor = TahoeGlassPalette.commandTint.cgColor
            metadata.append(MetadataSegment(text: "running…", color: .tertiaryLabelColor))
            minimumHeightConstraint?.constant = Metrics.runningMinimumHeight
            contentBottomConstraint?.isActive = hasVisibleOutput
        case .completed(let code):
            minimumHeightConstraint?.constant = 0
            contentBottomConstraint?.isActive = true
            layer?.backgroundColor = (code == 0
                ? TahoeGlassPalette.surfaceTint
                : TahoeGlassPalette.failureSurfaceTint
            ).cgColor
            if let duration = durationText(for: block) {
                metadata.append(MetadataSegment(text: duration, color: .tertiaryLabelColor))
            }
            if code != 0 {
                metadata.append(MetadataSegment(text: "exit \(code)", color: .secondaryLabelColor))
            }
        }
        metaLabel.attributedStringValue = attributedMetadata(metadata)
    }

    override func layout() {
        super.layout()
        if abs(outputView.bounds.width - lastMeasuredOutputWidth) > 0.5 {
            needsOutputHeightMeasurement = true
            updateOutputHeight()
        }
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy Command", action: #selector(copyCommand), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Output", action: #selector(copyOutput), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Markdown", action: #selector(copyMarkdown), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.minY),
            in: menuButton
        )
    }

    @objc private func copyCommand() { onCopyCommand?() }

    @objc private func copyOutput() { onCopyOutput?() }

    @objc private func copyMarkdown() { onCopyMarkdown?() }

    private func updateOutputHeight() {
        guard let textContainer = outputView.textContainer,
              let layoutManager = outputView.layoutManager
        else {
            return
        }
        guard hasVisibleOutput else {
            outputHeightConstraint?.constant = 0
            lastMeasuredOutputWidth = outputView.bounds.width
            needsOutputHeightMeasurement = false
            return
        }
        let availableWidth = max(1, outputView.bounds.width)
        guard needsOutputHeightMeasurement || abs(availableWidth - lastMeasuredOutputWidth) > 0.5 else {
            return
        }
        textContainer.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        outputHeightConstraint?.constant = ceil(usedRect.height)
        resetOutputViewport()
        lastMeasuredOutputWidth = availableWidth
        needsOutputHeightMeasurement = false
    }

    private func resetOutputViewport() {
        outputView.setBoundsOrigin(.zero)
    }

    private func durationText(for block: TerminalBlock) -> String? {
        guard let finishedAt = block.finishedAt else {
            return nil
        }
        let seconds = max(0, finishedAt.timeIntervalSince(block.startedAt))
        if seconds < 1 {
            return "\(twoSignificantFigures(seconds * 1000)) ms"
        }
        if seconds < 60 {
            return "\(secondsText(seconds))s"
        }
        let totalMinutes = Int(seconds / 60)
        let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
        if totalMinutes < 60 {
            return "\(totalMinutes)m \(secondsText(remainingSeconds))s"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m \(secondsText(remainingSeconds))s"
    }

    private func attributedMetadata(_ metadata: [MetadataSegment]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let font = metaLabel.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)

        for (index, segment) in metadata.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(
                    string: "  ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
            output.append(NSAttributedString(
                string: segment.text,
                attributes: [
                    .font: font,
                    .foregroundColor: segment.color
                ]
            ))
        }

        return output
    }

    private func displayCwd(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~" + String(cwd.dropFirst(home.count))
        }
        return cwd
    }

    private func secondsText(_ seconds: Double) -> String {
        var text = String(format: "%.2f", seconds)
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    private func twoSignificantFigures(_ value: Double) -> String {
        guard value > 0 else {
            return "0"
        }
        let exponent = floor(log10(value))
        let scale = pow(10, 1 - exponent)
        let rounded = (value * scale).rounded() / scale
        let decimals = max(0, Int(ceil(log10(scale))))
        var text = String(format: "%.\(decimals)f", rounded)
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}

private final class TitleTabButton: NSButton {
    let tabID: UUID
    private let closeButton = TitleTabCloseButton()
    private let titleContentView = NSView()
    private let dotenvShieldImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var toolTipText: String?
    private var preferredWidthConstraint: NSLayoutConstraint?
    private var minimumWidthConstraint: NSLayoutConstraint?
    private var titleContentWidthConstraint: NSLayoutConstraint?
    private var titleContentTrailingConstraint: NSLayoutConstraint?
    private var dotenvShieldWidthConstraint: NSLayoutConstraint?
    private var dotenvShieldGapConstraint: NSLayoutConstraint?
    private var fillColor = NSColor.clear {
        didSet { needsDisplay = true }
    }
    private var showsDotenvShield = false
    var isSelectedTab = false {
        didSet { updateAppearance() }
    }
    var roundsLeadingTopCorner = false {
        didSet {
            guard roundsLeadingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }
    var roundsTrailingTopCorner = false {
        didSet {
            guard roundsTrailingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(tabID: UUID, title: String) {
        self.tabID = tabID
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 13, weight: .semibold)
        alignment = .center
        lineBreakMode = .byTruncatingTail
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        contentTintColor = .secondaryLabelColor
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dotenvShieldImageView.image = NSImage(
            systemSymbolName: "checkmark.shield.fill",
            accessibilityDescription: "Dotenv secrets loaded"
        )
        dotenvShieldImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        dotenvShieldImageView.contentTintColor = .systemGreen
        dotenvShieldImageView.imageScaling = .scaleProportionallyDown
        dotenvShieldImageView.isHidden = true
        dotenvShieldImageView.translatesAutoresizingMaskIntoConstraints = false

        titleContentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleContentView)
        titleContentView.addSubview(dotenvShieldImageView)

        titleLabel.stringValue = title
        titleLabel.font = font
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.textColor = TahoeGlassPalette.titleText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleContentView.addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 6
        closeButton.layer?.cornerCurve = .continuous
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        let titleContentWidthConstraint = titleContentView.widthAnchor.constraint(
            equalToConstant: titleContentWidth
        )
        titleContentWidthConstraint.priority = .defaultHigh
        self.titleContentWidthConstraint = titleContentWidthConstraint

        let dotenvShieldWidthConstraint = dotenvShieldImageView.widthAnchor.constraint(
            equalToConstant: 0
        )
        self.dotenvShieldWidthConstraint = dotenvShieldWidthConstraint

        let dotenvShieldGapConstraint = titleLabel.leadingAnchor.constraint(
            equalTo: dotenvShieldImageView.trailingAnchor,
            constant: 0
        )
        self.dotenvShieldGapConstraint = dotenvShieldGapConstraint
        let titleContentTrailingConstraint = titleContentView.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -TahoeGlassPalette.titleTabTitleTrailingInset
        )
        self.titleContentTrailingConstraint = titleContentTrailingConstraint

        NSLayoutConstraint.activate([
            titleContentView.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleContentView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleContentView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: TahoeGlassPalette.titleTabTitleLeadingInset
            ),
            titleContentTrailingConstraint,
            titleContentWidthConstraint,
            titleContentView.heightAnchor.constraint(equalTo: heightAnchor),

            dotenvShieldImageView.leadingAnchor.constraint(
                equalTo: titleContentView.leadingAnchor
            ),
            dotenvShieldImageView.centerYAnchor.constraint(
                equalTo: titleLabel.centerYAnchor,
                constant: TahoeGlassPalette.titleTabShieldBaselineAdjustment
            ),
            dotenvShieldWidthConstraint,
            dotenvShieldImageView.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabShieldSize),

            dotenvShieldGapConstraint,
            titleLabel.trailingAnchor.constraint(
                equalTo: titleContentView.trailingAnchor
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -TahoeGlassPalette.titleTabCloseButtonTrailingInset
            ),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabCloseButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabCloseButtonSize)
        ])

        updateTitle(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if !closeButton.isHidden {
            let closePoint = closeButton.convert(point, from: self)
            if let closeHit = closeButton.hitTest(closePoint) {
                return closeHit
            }
        }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1))
        titleSegmentFillPath(
            in: fillRect,
            isFlipped: isFlipped,
            roundsLeadingTopCorner: roundsLeadingTopCorner,
            roundsTrailingTopCorner: roundsTrailingTopCorner
        ).fill()
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        updateToolTipForCurrentLayout()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: TahoeGlassPalette.titleTabHeight)
    }

    var widthConstraints: [NSLayoutConstraint] {
        let preferredWidthConstraint = widthAnchor.constraint(equalToConstant: preferredWidth)
        preferredWidthConstraint.priority = .defaultHigh
        self.preferredWidthConstraint = preferredWidthConstraint
        let minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
        self.minimumWidthConstraint = minimumWidthConstraint

        return [
            preferredWidthConstraint,
            minimumWidthConstraint
        ]
    }

    private var minimumWidth: CGFloat {
        TahoeGlassPalette.titleTabMinimumWidth + dotenvShieldWidth
    }

    private var preferredWidth: CGFloat {
        let horizontalInsets = TahoeGlassPalette.titleTabTitleLeadingInset
            + TahoeGlassPalette.titleTabTitleCloseTrailingInset
            + TahoeGlassPalette.titleTabMeasurementSlack
        return max(
            TahoeGlassPalette.titleTabMinimumWidth,
            titleTextWidth + horizontalInsets + dotenvShieldWidth
        )
    }

    private var titleTextWidth: CGFloat {
        ceil((titleLabel.stringValue as NSString).size(withAttributes: [
            .font: titleLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]).width)
    }

    private var titleContentWidth: CGFloat {
        titleTextWidth + dotenvShieldWidth
    }

    private var dotenvShieldWidth: CGFloat {
        showsDotenvShield
            ? TahoeGlassPalette.titleTabShieldSize + TahoeGlassPalette.titleTabShieldTextGap
            : 0
    }

    func configureClose(target: AnyObject?, action: Selector) {
        closeButton.target = target
        closeButton.action = action
    }

    func containsCloseButton(at point: NSPoint) -> Bool {
        !closeButton.isHidden && closeButton.frame.contains(point)
    }

    func updateTitle(_ title: String, detail: String? = nil) {
        titleLabel.stringValue = title
        toolTipText = detail ?? title
        setAccessibilityLabel(title)
        titleContentWidthConstraint?.constant = titleContentWidth
        preferredWidthConstraint?.constant = preferredWidth
        minimumWidthConstraint?.constant = minimumWidth
        invalidateIntrinsicContentSize()
        updateToolTipForCurrentLayout()
    }

    func updateDotenvShield(isVisible: Bool) {
        guard showsDotenvShield != isVisible else { return }
        showsDotenvShield = isVisible
        dotenvShieldImageView.isHidden = !isVisible
        dotenvShieldWidthConstraint?.constant = isVisible ? TahoeGlassPalette.titleTabShieldSize : 0
        dotenvShieldGapConstraint?.constant = isVisible ? TahoeGlassPalette.titleTabShieldTextGap : 0
        titleContentWidthConstraint?.constant = titleContentWidth
        preferredWidthConstraint?.constant = preferredWidth
        minimumWidthConstraint?.constant = minimumWidth
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateToolTipForCurrentLayout() {
        guard titleLabel.bounds.width > 0,
              titleTextWidth > titleLabel.bounds.width + 0.5,
              let toolTipText,
              !toolTipText.isEmpty
        else {
            toolTip = nil
            return
        }

        toolTip = toolTipText
    }

    private func updateAppearance() {
        titleContentTrailingConstraint?.constant = -(
            isHovering
                ? TahoeGlassPalette.titleTabTitleCloseTrailingInset
                : TahoeGlassPalette.titleTabTitleTrailingInset
        )
        if isSelectedTab {
            fillColor = .clear
            contentTintColor = TahoeGlassPalette.titleTextActive
            titleLabel.textColor = TahoeGlassPalette.titleTextActive
        } else if isHovering {
            fillColor = TahoeGlassPalette.titleSegmentHoverFill
            contentTintColor = TahoeGlassPalette.titleTextActive
            titleLabel.textColor = TahoeGlassPalette.titleTextActive
        } else {
            fillColor = .clear
            contentTintColor = TahoeGlassPalette.titleText
            titleLabel.textColor = TahoeGlassPalette.titleText
        }
        closeButton.isHidden = !isHovering
        closeButton.contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
        closeButton.layer?.backgroundColor = (isHovering
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.clear
        ).cgColor
    }
}

private final class TitleAddButton: NSButton {
    private var fillColor = NSColor.clear {
        didSet { needsDisplay = true }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }
    var roundsLeadingTopCorner = false {
        didSet {
            guard roundsLeadingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }
    var roundsTrailingTopCorner = false {
        didSet {
            guard roundsTrailingTopCorner != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "+"
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 18, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = TahoeGlassPalette.titleText
        translatesAutoresizingMaskIntoConstraints = false
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1))
        titleSegmentFillPath(
            in: fillRect,
            isFlipped: isFlipped,
            roundsLeadingTopCorner: roundsLeadingTopCorner,
            roundsTrailingTopCorner: roundsTrailingTopCorner
        ).fill()
        super.draw(dirtyRect)
    }

    private func updateAppearance() {
        fillColor = isHovering ? TahoeGlassPalette.titleSegmentHoverFill : .clear
        contentTintColor = isHovering ? TahoeGlassPalette.titleTextActive : TahoeGlassPalette.titleText
    }
}

private final class TitleUpdateButton: NSButton {
    static let visibleWidth: CGFloat = 108

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Update"
        image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Install Update"
        )
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .regular
        font = .systemFont(ofSize: 13, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = TahoeGlassPalette.titleTextActive
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Install staged update")
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateAppearance() {
        let fillAlpha: CGFloat
        if !isEnabled {
            fillAlpha = 0.08
        } else {
            fillAlpha = isHovering ? 0.18 : 0.12
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(fillAlpha).cgColor
        contentTintColor = isEnabled
            ? TahoeGlassPalette.titleTextActive
            : TahoeGlassPalette.titleText
    }
}

private final class PtyPassthroughView: NSView {
    var onInput: ((String) -> Void)?
    var onInterrupt: (() -> Void)?
    var usesApplicationCursorKeys: (() -> Bool)?
    var usesPagerKeyBindings = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let sequence = terminalSequence(for: event) else {
            super.keyDown(with: event)
            return
        }
        if sequence == "\u{3}" {
            onInterrupt?()
            return
        }
        onInput?(sequence)
    }

    override func cancelOperation(_ sender: Any?) {
        onInterrupt?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private func terminalSequence(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return nil
        }
        if flags.contains(.control), event.charactersIgnoringModifiers?.lowercased() == "c" {
            return "\u{3}"
        }

        if usesPagerKeyBindings {
            switch event.keyCode {
            case 126:
                return "k"
            case 125:
                return "j"
            case 115:
                return "g"
            case 119:
                return "G"
            case 116:
                return "b"
            case 121:
                return " "
            default:
                break
            }
        }

        // Navigation key character payloads can already contain ESC bytes; use hardware key codes.
        switch event.keyCode {
        case 126:
            return cursorKey(normal: "\u{1B}[A", application: "\u{1B}OA")
        case 125:
            return cursorKey(normal: "\u{1B}[B", application: "\u{1B}OB")
        case 124:
            return cursorKey(normal: "\u{1B}[C", application: "\u{1B}OC")
        case 123:
            return cursorKey(normal: "\u{1B}[D", application: "\u{1B}OD")
        case 115:
            return "\u{1B}[H"
        case 119:
            return "\u{1B}[F"
        case 116:
            return "\u{1B}[5~"
        case 121:
            return "\u{1B}[6~"
        case 117:
            return "\u{1B}[3~"
        default:
            break
        }

        if let special = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           special >= 0xF700,
           special <= 0xF8FF {
            return nil
        }

        return event.characters?.isEmpty == false ? event.characters : nil
    }

    private func cursorKey(normal: String, application: String) -> String {
        usesApplicationCursorKeys?() == true ? application : normal
    }
}

private final class TerminalTab {
    let id = UUID()
    let session = PtySession()
    let rootView = NSView()
    let scrollView = NSScrollView()
    let stackView = NSStackView()
    let inputView = CommandInputTextView(frame: .zero)
    let statusLabel = NSTextField(labelWithString: "Starting shell...")
    let commandSeparator = SeparatorView()
    let commandBarView = NSView()
    let ptyPassthroughView = PtyPassthroughView(frame: .zero)
    var title: String

    var scrollBottomToCommandBarConstraint: NSLayoutConstraint?
    var scrollBottomToRootConstraint: NSLayoutConstraint?

    var blocks: [TerminalBlock] = []
    var blockViews: [UUID: BlockView] = [:]
    var pendingBlockViewUpdates = Set<UUID>()
    var isBlockViewUpdateScheduled = false
    var activeBlockID: UUID?
    var pendingBlockID: UUID?
    var currentCwd = FileManager.default.homeDirectoryForCurrentUser.path
    var hasInjectedDotenvSecrets = false
    var parserBuffer = ""
    var pendingShellOutput = ""
    var isShellOutputFlushScheduled = false
    var isScrollToBottomScheduled = false
    var isShellReady = false
    var isTerminalControlActive = false
    var isAlternateScreenActive = false
    var isApplicationCursorModeActive = false
    let terminalScreen = Ansi.TerminalScreen(rows: 30, cols: 100)
    let styledRenderer = Ansi.StyledTextRenderer()
    var ttyModeTimer: Timer?
    var commandHistory: [String] = []
    var commandHistoryIndex: Int?
    var commandHistoryDraft = ""

    init(title: String, delegate: NSTextViewDelegate) {
        self.title = title
        buildView(delegate: delegate)
    }

    private func buildView(delegate: NSTextViewDelegate) {
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(stackView)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        inputView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        inputView.minSize = NSSize(width: 0, height: 44)
        inputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 96)
        inputView.isVerticallyResizable = true
        inputView.delegate = delegate
        inputView.string = ""
        inputView.drawsBackground = false
        inputView.textColor = .labelColor
        inputView.insertionPointColor = .labelColor
        inputView.textContainerInset = NSSize(width: 12, height: 10)
        inputView.textContainer?.lineFragmentPadding = 0
        inputView.wantsLayer = true
        inputView.layer?.cornerRadius = 0
        inputView.layer?.borderWidth = 0
        configureCommandInputTextSystem(inputView)
        inputView.resetPlainTextAttributes()
        inputView.setAccessibilityLabel("Vaultty command input")

        let inputScroll = NSScrollView()
        inputScroll.documentView = inputView
        inputScroll.hasVerticalScroller = true
        inputScroll.drawsBackground = false
        inputScroll.contentView.drawsBackground = false
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        commandBarView.wantsLayer = true
        commandBarView.layer?.backgroundColor = TahoeGlassPalette.commandTint.cgColor
        commandBarView.translatesAutoresizingMaskIntoConstraints = false
        ptyPassthroughView.translatesAutoresizingMaskIntoConstraints = false
        ptyPassthroughView.isHidden = true
        ptyPassthroughView.onInput = { [weak self] sequence in
            self?.session.write(sequence)
        }
        ptyPassthroughView.usesApplicationCursorKeys = { [weak self] in
            self?.isApplicationCursorModeActive == true
        }
        commandBarView.addSubview(statusLabel)
        commandBarView.addSubview(inputScroll)

        rootView.addSubview(scrollView)
        rootView.addSubview(commandSeparator)
        rootView.addSubview(commandBarView)
        rootView.addSubview(ptyPassthroughView)

        scrollBottomToCommandBarConstraint = scrollView.bottomAnchor.constraint(equalTo: commandSeparator.topAnchor)
        scrollBottomToRootConstraint = scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        scrollBottomToRootConstraint?.isActive = false

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollBottomToCommandBarConstraint!,

            commandSeparator.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandSeparator.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandSeparator.bottomAnchor.constraint(equalTo: commandBarView.topAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            commandBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            commandBarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: commandBarView.topAnchor, constant: 8),

            inputScroll.leadingAnchor.constraint(equalTo: commandBarView.leadingAnchor),
            inputScroll.trailingAnchor.constraint(equalTo: commandBarView.trailingAnchor),
            inputScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            inputScroll.bottomAnchor.constraint(equalTo: commandBarView.bottomAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 64),

            ptyPassthroughView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            ptyPassthroughView.topAnchor.constraint(equalTo: rootView.topAnchor),
            ptyPassthroughView.widthAnchor.constraint(equalToConstant: 0),
            ptyPassthroughView.heightAnchor.constraint(equalToConstant: 0)
        ])
    }

    private func configureCommandInputTextSystem(_ textView: NSTextView) {
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }
}

final class TerminalViewController: NSViewController, NSTextViewDelegate {
    private struct TerminalGridSize {
        let rows: UInt16
        let cols: UInt16
    }

    private struct CompletionPreviewState {
        let baseText: String
        let replacementRange: NSRange
        var renderedRange: NSRange
    }

    private let selfTestCommand: String?
    private var didRunSelfTest = false
    private var tabs: [TerminalTab] = []
    private var activeTabID: UUID?
    private var tabButtons: [UUID: TitleTabButton] = [:]
    var onInstallStagedUpdate: (() -> Void)?

    private let titleTabStack = TitleTabStackView()
    private let titleTabBorderView = TitleTabBorderView()
    private let newTabButton = TitleAddButton(frame: .zero)
    private let updateButton = TitleUpdateButton(frame: .zero)
    private let contentContainer = NSView()
    private let resizeTooltipView = ResizeMetricsTooltipView()
    private let completionEngine = VaulttyCompletionEngine()
    private let completionQueue = DispatchQueue(label: "com.automicvault.vaultty.completion", qos: .userInitiated)
    private let gitStateProvider = GitDirectoryStateProvider()
    private let gitStateQueue = DispatchQueue(label: "com.automicvault.vaultty.git-state", qos: .utility)
    private let completionPopup = CompletionPopupController()
    private var completionRequestSerial = 0
    private var activeCompletionRange: NSRange?
    private var completionPreviewState: CompletionPreviewState?
    private var isApplyingCompletion = false
    private var isCompletionInteractionArmed = false
    private var isShowingResizeTooltip = false
    private var tabMouseDownMonitor: Any?
    private var commandFocusMonitor: Any?
    private var updateButtonWidthConstraint: NSLayoutConstraint?
    private let shellOutputFlushDelay: TimeInterval = 1.0 / 30.0
    private let blockViewRenderDelay: TimeInterval = 1.0 / 12.0
    private let interactiveBlockViewRenderDelay: TimeInterval = 1.0 / 30.0

    private enum TabClickTarget {
        case select(UUID)
        case close(UUID)
    }

    init(selfTestCommand: String? = nil) {
        self.selfTestCommand = selfTestCommand
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.selfTestCommand = nil
        super.init(coder: coder)
    }

    override func loadView() {
        let rootView = TahoeGlassRootView()
        rootView.onLayout = { [weak self] in
            self?.handleRootLayout()
        }
        view = rootView

        titleTabStack.orientation = .horizontal
        titleTabStack.spacing = 0
        titleTabStack.alignment = .centerY
        titleTabStack.distribution = .fill
        titleTabStack.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        updateButton.target = self
        updateButton.action = #selector(installStagedUpdate(_:))
        updateButton.isHidden = true
        titleTabBorderView.tabStack = titleTabStack

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        resizeTooltipView.isHidden = true

        view.addSubview(titleTabStack)
        view.addSubview(titleTabBorderView)
        view.addSubview(updateButton)
        view.addSubview(contentContainer)
        view.addSubview(resizeTooltipView)
        titleTabStack.addArrangedSubview(newTabButton)
        updateTitleSegmentCornerMasks()

        let updateButtonWidthConstraint = updateButton.widthAnchor.constraint(equalToConstant: 0)
        self.updateButtonWidthConstraint = updateButtonWidthConstraint

        NSLayoutConstraint.activate([
            titleTabStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: TahoeGlassPalette.titleTabLeadingInset
            ),
            titleTabStack.trailingAnchor.constraint(
                lessThanOrEqualTo: updateButton.leadingAnchor,
                constant: -12
            ),
            titleTabStack.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: TahoeGlassPalette.titleTabTopInset
            ),
            titleTabStack.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight),

            titleTabBorderView.leadingAnchor.constraint(equalTo: titleTabStack.leadingAnchor),
            titleTabBorderView.trailingAnchor.constraint(equalTo: titleTabStack.trailingAnchor),
            titleTabBorderView.topAnchor.constraint(equalTo: titleTabStack.topAnchor),
            titleTabBorderView.bottomAnchor.constraint(equalTo: titleTabStack.bottomAnchor),

            newTabButton.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight),
            newTabButton.widthAnchor.constraint(equalTo: newTabButton.heightAnchor),

            updateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            updateButton.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: TahoeGlassPalette.titleTabTopInset
            ),
            updateButton.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight),
            updateButtonWidthConstraint,

            contentContainer.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            contentContainer.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            contentContainer.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: TahoeGlassPalette.titleContentTop
            ),
            contentContainer.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            )
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        completionPopup.onExternalDismiss = { [weak self] in
            self?.dismissCompletion()
        }
        createTab()
        installTabMouseDownMonitor()
        installCommandFocusMonitor()
    }

    deinit {
        if let tabMouseDownMonitor {
            NSEvent.removeMonitor(tabMouseDownMonitor)
        }
        if let commandFocusMonitor {
            NSEvent.removeMonitor(commandFocusMonitor)
        }
        stopAllSessions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        windowDidAttach()
    }

    func windowDidAttach() {
        if let tab = activeTab {
            focusInput(for: tab)
        }
    }

    func windowDidBecomeActive() {
        restoreCommandFocusIfNeeded()
    }

    func stopAllSessions() {
        for tab in tabs {
            stopTtyModePolling(for: tab)
            tab.session.stop()
        }
    }

    func setUpdateStaged(_ isStaged: Bool) {
        updateButton.isHidden = !isStaged
        updateButton.isEnabled = isStaged
        updateButton.toolTip = isStaged ? "Install staged update" : nil
        updateButtonWidthConstraint?.constant = isStaged ? TitleUpdateButton.visibleWidth : 0
        view.needsLayout = true
    }

    func setUpdateInstallInProgress(_ isInstalling: Bool) {
        updateButton.isEnabled = !isInstalling
    }

    func beginWindowResizeTooltip() {
        isShowingResizeTooltip = true
        updateWindowResizeTooltip()
    }

    func updateWindowResizeTooltip() {
        guard isShowingResizeTooltip else { return }
        guard let tab = activeTab,
              let gridSize = terminalGridSize(for: tab),
              let window = view.window
        else {
            resizeTooltipView.isHidden = true
            return
        }

        let text = "\(gridSize.cols) cols x \(gridSize.rows) rows"
        let tooltipSize = resizeTooltipView.update(text: text)
        let windowPoint = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        let point = view.convert(windowPoint, from: nil)

        resizeTooltipView.frame = NSRect(
            origin: tooltipOrigin(near: point, size: tooltipSize),
            size: tooltipSize
        )
        resizeTooltipView.isHidden = false
    }

    func endWindowResizeTooltip() {
        isShowingResizeTooltip = false
        resizeTooltipView.isHidden = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        handleRootLayout()
    }

    private func handleRootLayout() {
        updateTitleSegmentCornerMasks()
        updateActiveTabCutoutFrame()
        titleTabBorderView.needsDisplay = true
        for tab in tabs {
            resizePtyToViewport(for: tab)
        }
        updateWindowResizeTooltip()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let tab = tabs.first(where: { $0.inputView === textView }) else {
            return false
        }

        if completionPopup.isShown &&
            (isCompletionInteractionArmed || commandSelector == #selector(NSResponder.insertTab(_:))) {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if let suggestion = completionPopup.selectPrevious() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let suggestion = completionPopup.selectNext() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                isCompletionInteractionArmed = true
                if completionPopup.hasSingleSuggestion {
                    acceptSelectedCompletion(in: tab, continuingDirectories: true)
                    return true
                }
                let suggestion = completionPreviewState == nil
                    ? completionPopup.activateSelection()
                    : completionPopup.selectNext()
                if let suggestion {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if let suggestion = completionPopup.selectPrevious() {
                    renderCompletionPreview(suggestion, in: tab)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                acceptSelectedCompletionAndSubmit(in: tab)
                return true
            }
            if commandSelector == #selector(NSResponder.moveRight(_:)) {
                acceptSelectedCompletion(in: tab, continuingDirectories: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                dismissCompletion()
                return true
            }
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)),
           isCommandRunning(in: tab) {
            interruptCommand(in: tab)
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            isCompletionInteractionArmed = true
            requestCompletion(in: tab, mode: .explicit)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                _ = handleUnmodifiedReturnKey(in: tab)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            return showPreviousCommand(in: tab)
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            return showNextCommand(in: tab)
        }
        return false
    }

    private func handleUnmodifiedReturnKey(in tab: TerminalTab) -> Bool {
        guard activeTabID == tab.id else { return false }
        if completionPopup.isShown && isCompletionInteractionArmed {
            acceptSelectedCompletionAndSubmit(in: tab)
        } else {
            dismissCompletion()
            submitCommand(in: tab)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingCompletion else { return }
        guard let textView = notification.object as? NSTextView,
              let tab = tabs.first(where: { $0.inputView === textView })
        else {
            dismissCompletion()
            return
        }
        tab.inputView.normalizePlainTextStorage()
        if completionPreviewState != nil {
            completionPreviewState = nil
            activeCompletionRange = nil
            isCompletionInteractionArmed = false
            completionPopup.dismiss()
            completionRequestSerial += 1
            return
        }
        if completionPopup.isShown {
            requestCompletion(in: tab, mode: .filtering)
        } else if shouldStartAutomaticCompletion(in: textView) {
            isCompletionInteractionArmed = false
            requestCompletion(in: tab, mode: .automatic)
        } else {
            dismissCompletion()
        }
    }

    func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        guard let textView = textObject as? NSTextView,
              let tab = tabs.first(where: { $0.inputView === textView }),
              shouldSendInputToPty(in: tab)
        else {
            return true
        }
        focusInput(for: tab)
        return false
    }

    @objc func newTab(_ sender: Any?) {
        createTab()
    }

    @objc private func installStagedUpdate(_ sender: Any?) {
        onInstallStagedUpdate?()
    }

    func newTab(at directoryURL: URL) {
        createTab(workingDirectory: directoryURL)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activateAdjacentTab(offset: -1)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activateAdjacentTab(offset: 1)
    }

    @objc private func selectTab(_ sender: TitleTabButton) {
        activateTab(sender.tabID)
    }

    @objc func closeActiveTabOrWindow(_ sender: Any?) {
        guard let activeTabID else {
            view.window?.performClose(sender)
            return
        }
        closeTab(withID: activeTabID)
    }

    @objc func clearActiveTab(_ sender: Any?) {
        guard let tab = activeTab, !tab.blocks.isEmpty else { return }

        let blocksToKeep = tab.blocks.filter { block in
            if block.id == tab.activeBlockID || block.id == tab.pendingBlockID {
                return true
            }
            if case .running = block.state {
                return true
            }
            return false
        }

        tab.blocks = blocksToKeep
        tab.blockViews.removeAll()
        tab.commandHistoryIndex = nil
        tab.commandHistoryDraft = ""
        rebuildBlockViews(for: tab)
        scrollToBottom(tab)
        focusInput(for: tab)
    }

    @objc private func closeTab(_ sender: NSButton) {
        guard let button = sender.superview as? TitleTabButton else { return }
        closeTab(withID: button.tabID)
    }

    @discardableResult
    private func closeTab(withID id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let button = tabButtons[id]
        else {
            return false
        }
        let tab = tabs[index]
        guard confirmCloseIfNeeded(tab) else {
            return false
        }
        stopTtyModePolling(for: tab)
        tab.session.stop()
        guard tabs.count > 1 else {
            view.window?.performClose(nil)
            return true
        }

        let wasActive = activeTabID == tab.id
        tab.rootView.removeFromSuperview()
        titleTabStack.removeArrangedSubview(button)
        button.removeFromSuperview()
        tabButtons.removeValue(forKey: tab.id)
        tabs.remove(at: index)

        if wasActive {
            let nextIndex = min(index, tabs.count - 1)
            activateTab(tabs[nextIndex].id, tabStripLayoutChanged: true)
        } else {
            layoutTabStripBeforeMeasuringSelection()
            updateActiveTabCutoutFrame()
        }
        return true
    }

    private var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    private func createTab(workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let directoryURL = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directoryPath = directoryURL.path
        let tab = TerminalTab(title: titleForDirectory(directoryPath), delegate: self)
        tab.currentCwd = directoryPath
        tab.inputView.onUnmodifiedReturnKey = { [weak self, weak tab] _ in
            guard let self, let tab else { return false }
            return self.handleUnmodifiedReturnKey(in: tab)
        }
        tabs.append(tab)
        configureSession(for: tab)
        configureInterruptHandling(for: tab)
        installTabView(tab)
        installTabButton(tab)
        activateTab(tab.id, tabStripLayoutChanged: true)
        startShell(for: tab, workingDirectory: directoryURL)
    }

    private func installTabView(_ tab: TerminalTab) {
        contentContainer.addSubview(tab.rootView)
        NSLayoutConstraint.activate([
            tab.rootView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tab.rootView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            tab.rootView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tab.rootView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    private func installTabButton(_ tab: TerminalTab) {
        let button = TitleTabButton(tabID: tab.id, title: tab.title)
        button.updateTitle(tab.title, detail: detailForDirectory(tab.currentCwd))
        button.target = self
        button.action = #selector(selectTab(_:))
        button.configureClose(target: self, action: #selector(closeTab(_:)))
        tabButtons[tab.id] = button
        titleTabStack.insertArrangedSubview(button, at: max(0, titleTabStack.arrangedSubviews.count - 1))
        updateTitleSegmentCornerMasks()
        NSLayoutConstraint.activate(button.widthConstraints + [
            button.heightAnchor.constraint(equalToConstant: TahoeGlassPalette.titleTabHeight)
        ])
    }

    private func installTabMouseDownMonitor() {
        tabMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  let clickedTarget = self.tabClickTarget(atWindowPoint: event.locationInWindow)
            else {
                return event
            }

            switch clickedTarget {
            case .select(let id):
                self.activateTab(id)
            case .close(let id):
                _ = self.closeTab(withID: id)
            }
            return nil
        }
    }

    private func installCommandFocusMonitor() {
        commandFocusMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseUp, .rightMouseUp]
        ) { [weak self] event in
            guard let self,
                  event.window === self.view.window
            else {
                return event
            }

            switch event.type {
            case .keyDown:
                if self.shouldRedirectKeyEventToCommandInput(event) {
                    self.restoreCommandFocusIfNeeded()
                }
            case .leftMouseUp, .rightMouseUp:
                if self.shouldRestoreCommandFocus(afterMouseEvent: event) {
                    DispatchQueue.main.async { [weak self] in
                        self?.restoreCommandFocusIfNeeded()
                    }
                }
            default:
                break
            }

            return event
        }
    }

    private func shouldRedirectKeyEventToCommandInput(_ event: NSEvent) -> Bool {
        guard let tab = activeTab,
              shouldRestoreCommandFocus,
              !isCommandFocusCurrent(for: tab)
        else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.contains(.command)
    }

    private func shouldRestoreCommandFocus(afterMouseEvent event: NSEvent) -> Bool {
        guard let tab = activeTab,
              shouldRestoreCommandFocus,
              let hitView = hitView(for: event),
              !isCommandInputView(hitView, in: tab),
              !isSelectableTranscriptView(hitView)
        else {
            return false
        }

        return true
    }

    private var shouldRestoreCommandFocus: Bool {
        guard let window = view.window else { return false }
        return NSApp.isActive && window.isKeyWindow && NSApp.modalWindow == nil
    }

    private func restoreCommandFocusIfNeeded() {
        guard shouldRestoreCommandFocus,
              let tab = activeTab,
              !isCommandFocusCurrent(for: tab)
        else {
            return
        }
        focusInput(for: tab)
    }

    private func isCommandFocusCurrent(for tab: TerminalTab) -> Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        return firstResponder === commandFocusTarget(for: tab)
    }

    private func commandFocusTarget(for tab: TerminalTab) -> NSResponder {
        shouldSendInputToPty(in: tab) ? tab.ptyPassthroughView : tab.inputView
    }

    private func hitView(for event: NSEvent) -> NSView? {
        guard let contentView = event.window?.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(point)
    }

    private func isCommandInputView(_ view: NSView, in tab: TerminalTab) -> Bool {
        view === tab.inputView || view.isDescendant(of: tab.inputView)
    }

    private func isSelectableTranscriptView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view is BlockOutputTextView || view is SelectableBlockTextField {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func tabClickTarget(atWindowPoint windowPoint: NSPoint) -> TabClickTarget? {
        for (id, button) in tabButtons {
            guard !button.isHidden, button.window != nil else { continue }
            let point = button.convert(windowPoint, from: nil)
            if button.bounds.contains(point) {
                return button.containsCloseButton(at: point) ? .close(id) : .select(id)
            }
        }
        return nil
    }

    private func activateTab(_ id: UUID, tabStripLayoutChanged: Bool = false) {
        activeTabID = id
        for tab in tabs {
            tab.rootView.isHidden = tab.id != id
            tabButtons[tab.id]?.isSelectedTab = tab.id == id
        }
        if tabStripLayoutChanged {
            layoutTabStripBeforeMeasuringSelection()
        }
        updateActiveTabCutoutFrame()
        if let tab = activeTab {
            focusInput(for: tab)
        }
    }

    private func activateAdjacentTab(offset: Int) {
        guard tabs.count > 1,
              let activeTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID })
        else {
            return
        }

        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        activateTab(tabs[nextIndex].id)
    }

    private func layoutTabStripBeforeMeasuringSelection() {
        guard view.window != nil else { return }
        updateTitleSegmentCornerMasks()
        titleTabStack.needsLayout = true
        titleTabBorderView.needsDisplay = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func updateTitleSegmentCornerMasks() {
        let visibleSegments = titleTabStack.arrangedSubviews.filter { !$0.isHidden }
        for segment in visibleSegments {
            let roundsLeading = segment === visibleSegments.first
            let roundsTrailing = segment === visibleSegments.last

            if let tabButton = segment as? TitleTabButton {
                tabButton.roundsLeadingTopCorner = roundsLeading
                tabButton.roundsTrailingTopCorner = roundsTrailing
            } else if let addButton = segment as? TitleAddButton {
                addButton.roundsLeadingTopCorner = roundsLeading
                addButton.roundsTrailingTopCorner = roundsTrailing
            }
        }
    }

    private func updateActiveTabCutoutFrame() {
        guard let rootView = view as? TahoeGlassRootView else { return }
        rootView.tabStripFrame = titleTabStack.convert(titleTabStack.bounds, to: rootView)
        guard let activeTabID,
              let button = tabButtons[activeTabID],
              button.superview != nil
        else {
            rootView.activeTabFrame = nil
            return
        }
        rootView.activeTabFrame = button.convert(button.bounds, to: rootView)
    }

    private func configureSession(for tab: TerminalTab) {
        tab.session.onOutput = { [weak self, weak tab] text in
            guard let tab else { return }
            self?.enqueueShellOutput(text, in: tab)
        }
        tab.session.onExit = { [weak self, weak tab] status in
            tab?.statusLabel.stringValue = "Shell exited with status \(status)"
            if let tab {
                self?.flushPendingShellOutput(in: tab)
                self?.finishRunningBlocks(in: tab, status: status)
                self?.updateTabTitleForDirectory(tab)
                self?.stopTtyModePolling(for: tab)
                tab.ptyPassthroughView.usesPagerKeyBindings = false
                self?.setTerminalControl(false, in: tab)
                self?.clearCommandInput(in: tab)
                self?.updateCommandBarVisibility(for: tab)
            }
        }
    }

    private func configureInterruptHandling(for tab: TerminalTab) {
        tab.ptyPassthroughView.onInterrupt = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.interruptCommand(in: tab)
        }
    }

    private func startShell(for tab: TerminalTab, workingDirectory: URL) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["VAULTTY"] = "1"
        env["VAULTTY_ENV"] = bundledExecutablePath(named: "vaultty-env")
        env["PROMPT"] = ""
        env["RPROMPT"] = ""

        do {
            try tab.session.start(shellPath: shell, environment: env, workingDirectory: workingDirectory)
            let initScript = """
            export VAULTTY=1
            export TERM=xterm-256color
            export VAULTTY_ENV=\(shellQuote(env["VAULTTY_ENV"] ?? ""))
            cd \(shellQuote(workingDirectory.path))
            __vaultty_dotenv_hook() {
              local __vaultty_dotenv __vaultty_status __vaultty_loaded
              if [ ! -x "$VAULTTY_ENV" ]; then
                return 0
              fi
              __vaultty_dotenv="$("$VAULTTY_ENV" export --cwd "$PWD" --format zsh)"
              __vaultty_status=$?
              if [ "$__vaultty_status" -eq 0 ]; then
                eval "$__vaultty_dotenv"
                __vaultty_status=$?
              fi
              if [ "$__vaultty_status" -eq 0 ] && [ -n "${VAULTTY_DOTENV_FILE:-}" ] && [ -n "${VAULTTY_DOTENV_KEYS:-}" ]; then
                __vaultty_loaded=1
              else
                __vaultty_loaded=0
              fi
              printf '\\033]133;V;%s\\a' "$__vaultty_loaded"
              return "$__vaultty_status"
            }
            if [ -n "${ZSH_VERSION:-}" ]; then
              autoload -Uz add-zsh-hook
              add-zsh-hook -d chpwd __av_dotenv_hook 2>/dev/null || true
              add-zsh-hook -d chpwd __vaultty_dotenv_hook 2>/dev/null || true
              add-zsh-hook chpwd __vaultty_dotenv_hook 2>/dev/null || true
            fi
            __vaultty_dotenv_hook
            stty -echo
            PROMPT=''
            RPROMPT=''
            setopt no_prompt_cr 2>/dev/null || true
            printf '\\033]133;R;%s\\a' "$(pwd | base64)"

            """
            tab.session.write(initScript)
        } catch {
            tab.statusLabel.stringValue = "Failed to start shell: \(error.localizedDescription)"
        }
    }

    private func bundledExecutablePath(named name: String) -> String? {
        if name == "vaultty-env" {
            let nestedHelperURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("VaulttyEnv.app", isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: nestedHelperURL.path) {
                return nestedHelperURL.path
            }
        }

        let helpersURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: helpersURL.path) {
            return helpersURL.path
        }
        return Bundle.main.path(forResource: name, ofType: nil)
    }

    private enum CompletionRequestMode {
        case explicit
        case automatic
        case filtering
        case continuation
    }

    private func shouldStartAutomaticCompletion(in textView: NSTextView) -> Bool {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return false }

        let parsed = ShellCompletionParser.parse(input: textView.string, cursorOffset: selectedRange.location)
        guard parsed.commandTokenIndex != nil, !parsed.isCompletingCommand else { return false }

        let prefix = (textView.string as NSString).substring(to: selectedRange.location)
        guard let lastCharacter = prefix.last else { return false }
        return lastCharacter.isWhitespace || !parsed.currentTokenText.isEmpty
    }

    private func requestCompletion(in tab: TerminalTab, mode: CompletionRequestMode) {
        guard tab.isShellReady, !tab.isTerminalControlActive else { return }
        let selectedRange = tab.inputView.selectedRange()
        guard selectedRange.length == 0 else { return }

        completionRequestSerial += 1
        let serial = completionRequestSerial
        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = tab.currentCwd
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        let request = CompletionRequest(
            input: tab.inputView.string,
            cursorOffset: selectedRange.location,
            cwd: tab.currentCwd,
            shellPath: environment["SHELL"] ?? "/bin/zsh",
            environment: environment,
            limit: 14
        )

        completionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.completionEngine.completions(for: request)
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self,
                      let tab,
                      self.activeTabID == tab.id,
                      serial == self.completionRequestSerial
                else {
                    return
                }
                self.handleCompletionResult(result, in: tab, mode: mode)
            }
        }
    }

    private func handleCompletionResult(_ result: CompletionResult, in tab: TerminalTab, mode: CompletionRequestMode) {
        guard !result.suggestions.isEmpty else {
            dismissCompletion()
            if mode == .explicit {
                NSSound.beep()
            }
            return
        }

        activeCompletionRange = result.replacementRange
        if mode == .explicit,
           let prefix = result.commonPrefix,
           let existing = substring(in: tab.inputView.string, range: result.replacementRange),
           prefix.utf16.count > existing.utf16.count {
            replace(range: result.replacementRange, with: prefix, in: tab)
            activeCompletionRange = NSRange(location: result.replacementRange.location, length: prefix.utf16.count)
            if shouldContinueCompletion(afterInserting: prefix, from: result) {
                requestCompletion(in: tab, mode: .continuation)
                return
            }
        }

        let anchor = completionAnchorRect(for: tab.inputView, in: tab.commandBarView)
        completionPopup.show(
            suggestions: result.suggestions,
            relativeTo: anchor,
            of: tab.commandBarView,
            resetSelection: mode != .explicit,
            showsSelection: isCompletionInteractionArmed
        )
        let shouldRenderPreview = mode == .explicit || mode == .continuation
        if shouldRenderPreview, let suggestion = completionPopup.selectedSuggestion {
            renderCompletionPreview(suggestion, in: tab)
        }
    }

    private func acceptSelectedCompletion(in tab: TerminalTab, continuingDirectories: Bool = false) {
        guard let suggestion = completionPopup.selectedSuggestion else {
            dismissCompletion()
            return
        }
        let shouldContinue = continuingDirectories && shouldContinueCompletion(afterApplying: suggestion)
        applyCompletion(suggestion, in: tab, dismissAfterApplying: !shouldContinue)
        if shouldContinue {
            requestCompletion(in: tab, mode: .continuation)
        }
    }

    private func acceptSelectedCompletionAndSubmit(in tab: TerminalTab) {
        guard let suggestion = completionPopup.selectedSuggestion else {
            dismissCompletion()
            return
        }
        applyCompletion(suggestion, in: tab)
        submitCommand(in: tab)
    }

    private func applyCompletion(
        _ suggestion: CompletionSuggestion,
        in tab: TerminalTab,
        dismissAfterApplying: Bool = true
    ) {
        if !commitCompletionPreview(in: tab) {
            guard let range = activeCompletionRange else { return }
            replace(range: range, with: suggestion.insertText, in: tab)
        }
        if dismissAfterApplying {
            dismissCompletion(restoringPreview: false)
        }
    }

    private func renderCompletionPreview(_ suggestion: CompletionSuggestion, in tab: TerminalTab) {
        guard let replacementRange = completionPreviewState?.replacementRange ?? activeCompletionRange else { return }
        let baseText = completionPreviewState?.baseText ?? tab.inputView.string
        guard let existing = substring(in: baseText, range: replacementRange) else { return }

        let updated = (baseText as NSString).replacingCharacters(in: replacementRange, with: suggestion.insertText)
        let renderedRange = NSRange(
            location: replacementRange.location,
            length: (suggestion.insertText as NSString).length
        )
        let typedPrefixLength = commonPrefixLength(existing, suggestion.insertText)
        let mutedRange = NSRange(
            location: renderedRange.location + typedPrefixLength,
            length: max(0, renderedRange.length - typedPrefixLength)
        )

        isApplyingCompletion = true
        tab.inputView.string = updated
        tab.inputView.renderMutedCompletionPreview(mutedRange: mutedRange)
        let cursor = replacementRange.location + replacementRange.length
        tab.inputView.setSelectedRange(NSRange(location: cursor, length: 0))
        tab.inputView.scrollRangeToVisible(NSRange(location: cursor, length: 0))
        isApplyingCompletion = false

        completionPreviewState = CompletionPreviewState(
            baseText: baseText,
            replacementRange: replacementRange,
            renderedRange: renderedRange
        )
    }

    @discardableResult
    private func commitCompletionPreview(in tab: TerminalTab) -> Bool {
        guard let preview = completionPreviewState else { return false }
        isApplyingCompletion = true
        tab.inputView.normalizePlainTextStorage()
        let cursor = preview.renderedRange.location + preview.renderedRange.length
        tab.inputView.setSelectedRange(NSRange(location: cursor, length: 0))
        tab.inputView.scrollRangeToVisible(NSRange(location: cursor, length: 0))
        isApplyingCompletion = false
        completionPreviewState = nil
        activeCompletionRange = preview.renderedRange
        return true
    }

    private func clearCompletionPreview(in tab: TerminalTab, restoringOriginal: Bool) {
        guard let preview = completionPreviewState else { return }
        completionPreviewState = nil
        isApplyingCompletion = true
        if restoringOriginal {
            tab.inputView.string = preview.baseText
            tab.inputView.normalizePlainTextStorage()
            let cursor = preview.replacementRange.location + preview.replacementRange.length
            tab.inputView.setSelectedRange(NSRange(location: cursor, length: 0))
            tab.inputView.scrollRangeToVisible(NSRange(location: cursor, length: 0))
            activeCompletionRange = preview.replacementRange
        } else {
            tab.inputView.normalizePlainTextStorage()
            activeCompletionRange = preview.renderedRange
        }
        isApplyingCompletion = false
    }

    private func shouldContinueCompletion(afterApplying suggestion: CompletionSuggestion) -> Bool {
        suggestion.kind == .folder || suggestion.insertText.hasSuffix("/")
    }

    private func shouldContinueCompletion(afterInserting value: String, from result: CompletionResult) -> Bool {
        guard value.hasSuffix("/") else { return false }
        return result.suggestions.contains { suggestion in
            suggestion.kind == .file || suggestion.kind == .folder
        }
    }

    private func replace(range: NSRange, with value: String, in tab: TerminalTab) {
        let text = tab.inputView.string as NSString
        guard range.location >= 0,
              range.location + range.length <= text.length
        else {
            return
        }
        let updated = text.replacingCharacters(in: range, with: value)
        isApplyingCompletion = true
        tab.inputView.string = updated
        tab.inputView.normalizePlainTextStorage()
        let cursor = range.location + (value as NSString).length
        tab.inputView.setSelectedRange(NSRange(location: cursor, length: 0))
        tab.inputView.scrollRangeToVisible(NSRange(location: cursor, length: 0))
        isApplyingCompletion = false
    }

    private func dismissCompletion(restoringPreview: Bool = true) {
        if let tab = activeTab {
            clearCompletionPreview(in: tab, restoringOriginal: restoringPreview)
        } else {
            completionPreviewState = nil
        }
        activeCompletionRange = nil
        isCompletionInteractionArmed = false
        completionPopup.dismiss()
        completionRequestSerial += 1
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        while lhsIndex < lhs.endIndex,
              rhsIndex < rhs.endIndex,
              lhs[lhsIndex] == rhs[rhsIndex] {
            length += String(lhs[lhsIndex]).utf16.count
            lhsIndex = lhs.index(after: lhsIndex)
            rhsIndex = rhs.index(after: rhsIndex)
        }
        return length
    }

    private func substring(in value: String, range: NSRange) -> String? {
        let text = value as NSString
        guard range.location >= 0,
              range.location + range.length <= text.length
        else {
            return nil
        }
        return text.substring(with: range)
    }

    private func completionAnchorRect(for textView: NSTextView, in containerView: NSView) -> NSRect {
        func boundedAnchorRect(_ rect: NSRect) -> NSRect {
            let width = max(1, rect.width)
            let height = max(1, rect.height)
            let minX = containerView.bounds.minX
            let maxX = max(minX, containerView.bounds.maxX - width)
            let minY = containerView.bounds.minY
            let maxY = max(minY, containerView.bounds.maxY - height)
            let x = min(max(rect.minX, minX), maxX)
            let y = min(max(rect.minY, minY), maxY)
            return NSRect(x: x, y: y, width: width, height: height)
        }

        func rectInTextViewCoordinates(from textContainerRect: NSRect) -> NSRect {
            let origin = textView.textContainerOrigin
            return NSRect(
                x: origin.x + textContainerRect.minX,
                y: origin.y + textContainerRect.minY,
                width: textContainerRect.width,
                height: textContainerRect.height
            )
        }

        let textViewRect = textView.convert(textView.bounds, to: containerView)
        let lineHeight = textView.font.map { textView.layoutManager?.defaultLineHeight(for: $0) ?? $0.boundingRectForFont.height } ?? 16
        let fallbackRect = NSRect(
            x: textViewRect.minX + textView.textContainerInset.width,
            y: textViewRect.minY + textView.textContainerInset.height,
            width: 1,
            height: lineHeight
        )

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return boundedAnchorRect(fallbackRect)
        }

        layoutManager.ensureLayout(for: textContainer)

        let selectedRange = textView.selectedRange()
        let textLength = (textView.string as NSString).length
        let cursorLocation = min(max(0, selectedRange.location), textLength)
        guard textLength > 0, layoutManager.numberOfGlyphs > 0 else {
            return boundedAnchorRect(fallbackRect)
        }

        let characterLocation = cursorLocation < textLength ? cursorLocation : textLength - 1
        let glyphIndex = min(
            layoutManager.glyphIndexForCharacter(at: characterLocation),
            max(0, layoutManager.numberOfGlyphs - 1)
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        let caretX = cursorLocation < textLength ? glyphRect.minX : glyphRect.maxX
        let textCaretRect = rectInTextViewCoordinates(from: NSRect(
            x: caretX,
            y: glyphRect.minY,
            width: 1,
            height: max(lineHeight, glyphRect.height)
        ))
        return boundedAnchorRect(textView.convert(textCaretRect, to: containerView))
    }

    private func submitCommand(in tab: TerminalTab) {
        guard tab.isShellReady else { return }
        let rawCommand = tab.inputView.string
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            submitEmptyCommand(rawCommand, in: tab)
            return
        }
        tab.commandHistory.append(command)
        tab.commandHistoryIndex = nil
        tab.commandHistoryDraft = ""
        clearCommandInput(in: tab)
        tab.isShellReady = false
        tab.isAlternateScreenActive = false
        tab.isApplicationCursorModeActive = false
        tab.terminalScreen.resetForCommand()
        tab.styledRenderer.reset()
        tab.ptyPassthroughView.usesPagerKeyBindings = usesPagerKeyBindings(for: command)

        let block = TerminalBlock(
            id: UUID(),
            command: command,
            cwd: tab.currentCwd,
            startedAt: Date(),
            finishedAt: nil,
            output: "",
            attributedOutput: NSMutableAttributedString(),
            outputRevision: 0,
            state: .running
        )
        tab.blocks.append(block)
        tab.pendingBlockID = block.id
        addBlockView(block, to: tab)
        updateCommandBarVisibility(for: tab)
        updateTabTitle(titleForCommand(command), detail: command, in: tab)
        startTtyModePolling(for: tab)
        updatePassthroughVisibility(for: tab)
        focusInput(for: tab)
        settleCommandStartLayout(for: tab)

        let encodedCommand = command.data(using: .utf8)?.base64EncodedString() ?? ""
        let script = "__vaultty_cmd=\(shellQuote(command)); __vaultty_command_b64=\(shellQuote(encodedCommand)); printf '\\033]133;C;%s\\a' \"$__vaultty_command_b64\"; if typeset -f __vaultty_dotenv_hook >/dev/null 2>&1; then __vaultty_dotenv_hook 2>&1; elif [ -x \"$VAULTTY_ENV\" ]; then eval \"$(\"$VAULTTY_ENV\" export --cwd \"$PWD\" --format zsh)\" 2>&1; fi; eval \"$__vaultty_cmd\"; __vaultty_status=$?; printf '\\033]133;P;%s\\a' \"$(pwd | base64)\"; printf '\\033]133;D;%s\\a' \"$__vaultty_status\"\n"
        tab.session.write(script)
    }

    private func submitEmptyCommand(_ rawCommand: String, in tab: TerminalTab) {
        let timestamp = Date()
        clearCommandInput(in: tab)
        tab.commandHistoryIndex = nil
        tab.commandHistoryDraft = ""

        let block = TerminalBlock(
            id: UUID(),
            command: "",
            cwd: tab.currentCwd,
            startedAt: timestamp,
            finishedAt: timestamp,
            output: "",
            attributedOutput: NSMutableAttributedString(),
            outputRevision: 0,
            state: .completed(0)
        )
        tab.blocks.append(block)
        addBlockView(block, to: tab)
        updateCommandBarVisibility(for: tab)
        tab.session.write(rawCommand + "\n")
        focusInput(for: tab)
    }

    private func interruptCommand(in tab: TerminalTab) {
        guard isCommandRunning(in: tab) else { return }
        renderInterruptEcho(in: tab)
        tab.session.sendInterrupt()
        tab.parserBuffer.removeAll()
        finishRunningBlocks(in: tab, status: 130)
        tab.isAlternateScreenActive = false
        tab.isApplicationCursorModeActive = false
        tab.ptyPassthroughView.usesPagerKeyBindings = false
        stopTtyModePolling(for: tab)
        tab.isShellReady = true
        setTerminalControl(false, in: tab)
        clearCommandInput(in: tab)
        updateCommandBarDirectoryStatus(for: tab)
        updateCommandBarVisibility(for: tab)
        updateTabTitleForDirectory(tab)
        focusInput(for: tab)
    }

    private func renderInterruptEcho(in tab: TerminalTab) {
        guard let activeBlockID = tab.activeBlockID,
              tab.blocks.contains(where: { $0.id == activeBlockID })
        else {
            return
        }
        flushVisible("^C\n", in: tab)
    }

    private func showPreviousCommand(in tab: TerminalTab) -> Bool {
        guard tab.isShellReady, !tab.commandHistory.isEmpty else { return false }

        let nextIndex: Int
        if let index = tab.commandHistoryIndex {
            nextIndex = max(0, index - 1)
        } else {
            tab.commandHistoryDraft = tab.inputView.string
            nextIndex = tab.commandHistory.count - 1
        }

        tab.commandHistoryIndex = nextIndex
        setInput(tab.commandHistory[nextIndex], in: tab)
        return true
    }

    private func showNextCommand(in tab: TerminalTab) -> Bool {
        guard tab.isShellReady, let index = tab.commandHistoryIndex else { return false }

        let nextIndex = index + 1
        if nextIndex < tab.commandHistory.count {
            tab.commandHistoryIndex = nextIndex
            setInput(tab.commandHistory[nextIndex], in: tab)
        } else {
            tab.commandHistoryIndex = nil
            setInput(tab.commandHistoryDraft, in: tab)
            tab.commandHistoryDraft = ""
        }
        return true
    }

    private func setInput(_ value: String, in tab: TerminalTab) {
        tab.inputView.string = value
        tab.inputView.normalizePlainTextStorage()
        let location = (value as NSString).length
        tab.inputView.setSelectedRange(NSRange(location: location, length: 0))
        tab.inputView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    private func enqueueShellOutput(_ text: String, in tab: TerminalTab) {
        tab.pendingShellOutput += text
        guard !tab.isShellOutputFlushScheduled else { return }

        tab.isShellOutputFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + shellOutputFlushDelay) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.flushPendingShellOutput(in: tab)
        }
    }

    private func flushPendingShellOutput(in tab: TerminalTab) {
        guard !tab.pendingShellOutput.isEmpty else {
            tab.isShellOutputFlushScheduled = false
            return
        }

        let text = tab.pendingShellOutput
        tab.pendingShellOutput.removeAll(keepingCapacity: true)
        tab.isShellOutputFlushScheduled = false
        consumeShellOutput(text, in: tab)
    }

    private func consumeShellOutput(_ text: String, in tab: TerminalTab) {
        tab.parserBuffer += text
        var visible = ""

        while true {
            guard let start = tab.parserBuffer.range(of: "\u{1B}]133;") else {
                visible += tab.parserBuffer
                tab.parserBuffer.removeAll()
                break
            }

            visible += String(tab.parserBuffer[..<start.lowerBound])
            tab.parserBuffer.removeSubrange(..<start.lowerBound)

            guard let end = tab.parserBuffer.firstIndex(of: "\u{7}") else {
                break
            }

            let marker = String(tab.parserBuffer[tab.parserBuffer.index(tab.parserBuffer.startIndex, offsetBy: 6)..<end])
            tab.parserBuffer.removeSubrange(...end)
            flushVisible(visible, in: tab)
            visible.removeAll()
            handleMarker(marker, in: tab)
        }

        flushVisible(visible, in: tab)
    }

    private func flushVisible(_ text: String, in tab: TerminalTab) {
        guard !text.isEmpty,
              let activeBlockID = tab.activeBlockID,
              let index = tab.blocks.firstIndex(where: { $0.id == activeBlockID })
        else {
            return
        }

        let shouldRenderScreen = tab.isAlternateScreenActive
            || tab.ptyPassthroughView.usesPagerKeyBindings
            || !Ansi.alternateScreenSwitches(in: text).isEmpty

        if shouldRenderScreen {
            let state = tab.terminalScreen.process(text)
            tab.isAlternateScreenActive = state.isAlternateScreenActive
            tab.isApplicationCursorModeActive = state.isApplicationCursorModeActive
            tab.blocks[index].output = state.text
            tab.blocks[index].attributedOutput = NSMutableAttributedString(
                attributedString: state.attributedText
            )
        } else {
            let rendered = tab.styledRenderer.process(text)
            tab.blocks[index].output = rendered.plainText
            tab.blocks[index].attributedOutput = NSMutableAttributedString(
                attributedString: rendered.attributedText
            )
        }
        tab.blocks[index].outputRevision += 1

        ensureBlockView(for: activeBlockID, in: tab)
        scheduleBlockViewUpdate(for: activeBlockID, in: tab)
        refreshTerminalControl(in: tab)
    }

    private func handleMarker(_ marker: String, in tab: TerminalTab) {
        let parts = marker.split(separator: ";", maxSplits: 1).map(String.init)
        guard let code = parts.first else { return }
        let payload = parts.count > 1 ? parts[1] : ""
        if code == "C" || code == "D" {
            let oscPayload = "133;\(marker)"
            guard oscPayload.withCString({ vaulttyGhosttyOscCommandType($0) }) == 3 else {
                return
            }
        }
        switch code {
        case "R":
            tab.currentCwd = decodeBase64(payload) ?? tab.currentCwd
            tab.isShellReady = true
            updateCommandBarDirectoryStatus(for: tab)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            runSelfTestIfNeeded(in: tab)
        case "C":
            tab.activeBlockID = tab.pendingBlockID
            tab.pendingBlockID = nil
        case "P":
            tab.currentCwd = decodeBase64(payload) ?? tab.currentCwd
        case "V":
            updateDotenvShield(payload.trimmingCharacters(in: .whitespacesAndNewlines) == "1", in: tab)
        case "D":
            let status = Int32(payload.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            if let activeBlockID = tab.activeBlockID,
               let index = tab.blocks.firstIndex(where: { $0.id == activeBlockID }) {
                tab.blocks[index].finishedAt = Date()
                tab.blocks[index].state = .completed(status)
                ensureBlockView(for: activeBlockID, in: tab)
                updateBlockViewNow(for: activeBlockID, in: tab)
            }
            tab.activeBlockID = nil
            tab.isAlternateScreenActive = false
            tab.isApplicationCursorModeActive = false
            tab.ptyPassthroughView.usesPagerKeyBindings = false
            tab.isShellReady = true
            stopTtyModePolling(for: tab)
            setTerminalControl(false, in: tab)
            clearCommandInput(in: tab)
            updateCommandBarDirectoryStatus(for: tab)
            updateCommandBarVisibility(for: tab)
            updateTabTitleForDirectory(tab)
            scrollToBottom(tab)
            focusInput(for: tab)
            runSelfTestIfNeeded(in: tab)
        default:
            break
        }
    }

    private func updateTerminalControl(from text: String, in tab: TerminalTab) {
        for isActive in Ansi.alternateScreenSwitches(in: text) {
            tab.isAlternateScreenActive = isActive
        }
        refreshTerminalControl(in: tab)
    }

    private func usesPagerKeyBindings(for command: String) -> Bool {
        guard let name = commandName(from: command) else { return false }
        return ["less", "man", "more", "most"].contains(name)
    }

    private func updateTabTitle(_ title: String, detail: String? = nil, in tab: TerminalTab) {
        let fallback = titleForDirectory(tab.currentCwd)
        let normalizedTitle = singleLineTitle(title)
        let displayTitle = normalizedTitle.isEmpty ? fallback : normalizedTitle
        tab.title = displayTitle
        if let button = tabButtons[tab.id] {
            button.updateTitle(displayTitle, detail: detail)
            button.updateDotenvShield(isVisible: tab.hasInjectedDotenvSecrets)
            layoutTabStripBeforeMeasuringSelection()
            updateActiveTabCutoutFrame()
        }
    }

    private func updateDotenvShield(_ isVisible: Bool, in tab: TerminalTab) {
        guard tab.hasInjectedDotenvSecrets != isVisible else { return }
        tab.hasInjectedDotenvSecrets = isVisible
        guard let button = tabButtons[tab.id] else { return }
        button.updateDotenvShield(isVisible: isVisible)
        layoutTabStripBeforeMeasuringSelection()
        updateActiveTabCutoutFrame()
    }

    private func updateTabTitleForDirectory(_ tab: TerminalTab) {
        updateTabTitle(
            titleForDirectory(tab.currentCwd),
            detail: detailForDirectory(tab.currentCwd),
            in: tab
        )
    }

    private func titleForDirectory(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (cwd as NSString).standardizingPath
        if path == home {
            return "~"
        }
        if path == "/" {
            return "/"
        }

        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func detailForDirectory(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (cwd as NSString).standardizingPath
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func updateCommandBarDirectoryStatus(for tab: TerminalTab) {
        let cwd = tab.currentCwd
        let directoryText = detailForDirectory(cwd)
        tab.statusLabel.stringValue = directoryText

        gitStateQueue.async { [weak self, weak tab] in
            guard let self else { return }
            let gitSummary = self.gitStateProvider.summary(
                forDirectory: URL(fileURLWithPath: cwd, isDirectory: true)
            )

            DispatchQueue.main.async { [weak tab] in
                guard let tab,
                      tab.currentCwd == cwd,
                      tab.isShellReady
                else {
                    return
                }
                guard let gitSummary else {
                    tab.statusLabel.stringValue = directoryText
                    return
                }
                tab.statusLabel.attributedStringValue = self.commandBarStatusText(
                    directoryText: directoryText,
                    gitSummary: gitSummary,
                    font: tab.statusLabel.font
                )
            }
        }
    }

    private func commandBarStatusText(
        directoryText: String,
        gitSummary: GitDirectoryStateProvider.Summary,
        font: NSFont?
    ) -> NSAttributedString {
        let statusFont = font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let directoryAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let gitAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let output = NSMutableAttributedString(
            string: directoryText,
            attributes: directoryAttributes
        )
        output.append(NSAttributedString(
            string: "  git \(gitSummary.branch) \(gitSummary.isDirty ? "dirty" : "clean")",
            attributes: gitAttributes
        ))
        if gitSummary.insertions > 0 {
            output.append(NSAttributedString(
                string: " +\(gitSummary.insertions)",
                attributes: [
                    .font: statusFont,
                    .foregroundColor: NSColor.systemGreen
                ]
            ))
        }
        if gitSummary.deletions > 0 {
            output.append(NSAttributedString(
                string: " -\(gitSummary.deletions)",
                attributes: [
                    .font: statusFont,
                    .foregroundColor: NSColor.systemRed
                ]
            ))
        }
        return output
    }

    private func clearCommandInput(in tab: TerminalTab) {
        tab.inputView.string = ""
        tab.inputView.resetPlainTextAttributes()
        tab.inputView.isEditable = true
    }

    private func titleForCommand(_ command: String) -> String {
        singleLineTitle(command)
    }

    private func singleLineTitle(_ title: String) -> String {
        title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func commandName(from command: String) -> String? {
        let wrappers = Set(["builtin", "command", "env", "exec", "noglob", "sudo"])
        for part in command.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(part)
            if token.contains("="), !token.hasPrefix("./"), !token.hasPrefix("/") {
                continue
            }

            let name = URL(fileURLWithPath: token).lastPathComponent.lowercased()
            if wrappers.contains(name) {
                continue
            }
            return name
        }
        return nil
    }

    private func startTtyModePolling(for tab: TerminalTab) {
        stopTtyModePolling(for: tab)
        tab.ttyModeTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self, weak tab] timer in
            guard let self, let tab else {
                timer.invalidate()
                return
            }
            guard self.isCommandRunning(in: tab) else {
                self.stopTtyModePolling(for: tab)
                return
            }
            self.refreshTerminalControl(in: tab)
        }
    }

    private func stopTtyModePolling(for tab: TerminalTab) {
        tab.ttyModeTimer?.invalidate()
        tab.ttyModeTimer = nil
    }

    private func refreshTerminalControl(in tab: TerminalTab) {
        let isRawInputMode = tab.session.isCanonicalInputModeEnabled() == false
        setTerminalControl(isCommandRunning(in: tab) && (tab.isAlternateScreenActive || isRawInputMode), in: tab)
    }

    private func setTerminalControl(_ isActive: Bool, in tab: TerminalTab) {
        guard tab.isTerminalControlActive != isActive else {
            updateCommandBarVisibility(for: tab)
            focusInput(for: tab)
            return
        }

        tab.isTerminalControlActive = isActive
        updatePassthroughVisibility(for: tab)
        updateCommandBarVisibility(for: tab)

        resizePtyToViewport(for: tab)
        focusInput(for: tab)
        scrollToBottom(tab)
    }

    private func updateCommandBarVisibility(for tab: TerminalTab) {
        let shouldShowCommandBar = !tab.isTerminalControlActive && !isCommandRunning(in: tab)
        tab.commandBarView.isHidden = !shouldShowCommandBar
        tab.commandSeparator.isHidden = !shouldShowCommandBar
        tab.scrollBottomToCommandBarConstraint?.isActive = shouldShowCommandBar
        tab.scrollBottomToRootConstraint?.isActive = !shouldShowCommandBar
        tab.rootView.needsLayout = true
        tab.rootView.layoutSubtreeIfNeeded()
    }

    private func settleCommandStartLayout(for tab: TerminalTab) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            tab.rootView.layoutSubtreeIfNeeded()
            contentContainer.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }
        scrollToBottomNow(tab)
    }

    private func focusInput(for tab: TerminalTab) {
        guard activeTabID == tab.id else { return }
        view.window?.makeFirstResponder(commandFocusTarget(for: tab))
    }

    private func updatePassthroughVisibility(for tab: TerminalTab) {
        tab.ptyPassthroughView.isHidden = !shouldSendInputToPty(in: tab)
    }

    private func shouldSendInputToPty(in tab: TerminalTab) -> Bool {
        tab.isTerminalControlActive || isCommandRunning(in: tab)
    }

    private func resizePtyToViewport(for tab: TerminalTab) {
        guard let gridSize = terminalGridSize(for: tab) else { return }
        tab.session.resize(rows: gridSize.rows, cols: gridSize.cols)
        tab.terminalScreen.resize(rows: Int(gridSize.rows), cols: Int(gridSize.cols))
    }

    private func terminalGridSize(for tab: TerminalTab) -> TerminalGridSize? {
        let viewport = tab.scrollView.contentView.bounds
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let characterWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let cols = UInt16(max(20, Int(viewport.width / characterWidth)))
        let rows = UInt16(max(5, Int(viewport.height / lineHeight)))
        return TerminalGridSize(rows: rows, cols: cols)
    }

    private func tooltipOrigin(near point: NSPoint, size: NSSize) -> NSPoint {
        let bounds = view.bounds
        let offset: CGFloat = 14
        let margin: CGFloat = 10

        var x = point.x + offset
        if x + size.width + margin > bounds.maxX {
            x = point.x - size.width - offset
        }

        var y = point.y - size.height - offset
        if y < bounds.minY + margin {
            y = point.y + offset
        }

        x = min(max(bounds.minX + margin, x), bounds.maxX - size.width - margin)
        y = min(max(bounds.minY + margin, y), bounds.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    private func addBlockView(_ block: TerminalBlock, to tab: TerminalTab) {
        if !tab.stackView.arrangedSubviews.isEmpty {
            let separator = SeparatorView()
            tab.stackView.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true
        }

        let blockView = BlockView()
        blockView.update(with: block)
        blockView.onCopyCommand = { [weak self] in
            self?.copy(block.command)
        }
        blockView.onCopyOutput = { [weak self, weak tab] in
            let latest = tab?.blocks.first(where: { $0.id == block.id })
            self?.copy(latest?.output ?? "")
        }
        blockView.onCopyMarkdown = { [weak self, weak tab] in
            guard let self else { return }
            let latest = tab?.blocks.first(where: { $0.id == block.id }) ?? block
            self.copy(markdownTranscript(command: latest.command, output: latest.output))
        }
        tab.stackView.addArrangedSubview(blockView)
        blockView.translatesAutoresizingMaskIntoConstraints = false
        blockView.widthAnchor.constraint(equalTo: tab.stackView.widthAnchor).isActive = true
        tab.blockViews[block.id] = blockView
        scrollToBottom(tab)
    }

    private func ensureBlockView(for blockID: UUID, in tab: TerminalTab) {
        guard tab.blockViews[blockID] == nil,
              let block = tab.blocks.first(where: { $0.id == blockID })
        else {
            return
        }
        addBlockView(block, to: tab)
    }

    private func rebuildBlockViews(for tab: TerminalTab) {
        for view in tab.stackView.arrangedSubviews {
            tab.stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for block in tab.blocks {
            addBlockView(block, to: tab)
        }
    }

    private func runSelfTestIfNeeded(in tab: TerminalTab) {
        guard !didRunSelfTest, let selfTestCommand, tab.blocks.isEmpty, tab.isShellReady else { return }
        didRunSelfTest = true
        tab.inputView.string = selfTestCommand
        submitCommand(in: tab)
    }

    private func confirmCloseIfNeeded(_ tab: TerminalTab) -> Bool {
        guard isCommandRunning(in: tab) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this tab?"
        alert.informativeText = "A command is still running in this tab. Closing it will stop the shell session."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func isCommandRunning(in tab: TerminalTab) -> Bool {
        if tab.activeBlockID != nil || tab.pendingBlockID != nil {
            return true
        }
        return tab.blocks.contains { block in
            if case .running = block.state {
                return true
            }
            return false
        }
    }

    private func scheduleBlockViewUpdate(for blockID: UUID, in tab: TerminalTab) {
        tab.pendingBlockViewUpdates.insert(blockID)
        guard !tab.isBlockViewUpdateScheduled else { return }

        tab.isBlockViewUpdateScheduled = true
        let delay = tab.isTerminalControlActive || tab.isAlternateScreenActive || tab.ptyPassthroughView.usesPagerKeyBindings
            ? interactiveBlockViewRenderDelay
            : blockViewRenderDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.flushScheduledBlockViewUpdates(in: tab)
        }
    }

    private func flushScheduledBlockViewUpdates(in tab: TerminalTab) {
        let blockIDs = tab.pendingBlockViewUpdates
        tab.pendingBlockViewUpdates.removeAll(keepingCapacity: true)
        tab.isBlockViewUpdateScheduled = false

        for blockID in blockIDs {
            updateBlockViewNow(for: blockID, in: tab)
        }
    }

    private func updateBlockViewNow(for blockID: UUID, in tab: TerminalTab) {
        tab.pendingBlockViewUpdates.remove(blockID)
        guard let block = tab.blocks.first(where: { $0.id == blockID }) else { return }
        ensureBlockView(for: blockID, in: tab)
        tab.blockViews[blockID]?.update(with: block)
        scrollToBottom(tab)
    }

    private func finishRunningBlocks(in tab: TerminalTab, status: Int32) {
        let finishedAt = Date()
        for index in tab.blocks.indices {
            if case .running = tab.blocks[index].state {
                tab.blocks[index].finishedAt = finishedAt
                tab.blocks[index].state = .completed(status)
                ensureBlockView(for: tab.blocks[index].id, in: tab)
                updateBlockViewNow(for: tab.blocks[index].id, in: tab)
            }
        }
        tab.activeBlockID = nil
        tab.pendingBlockID = nil
        tab.isShellReady = false
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func markdownTranscript(command: String, output: String) -> String {
        var transcript = "```sh\n$ \(command)\n"
        if !output.isEmpty {
            transcript += output
            if !output.hasSuffix("\n") {
                transcript += "\n"
            }
        }
        transcript += "```"
        return transcript
    }

    private func scrollToBottom(_ tab: TerminalTab) {
        guard !tab.isScrollToBottomScheduled else { return }
        tab.isScrollToBottomScheduled = true
        DispatchQueue.main.async { [weak self] in
            tab.isScrollToBottomScheduled = false
            self?.scrollToBottomNow(tab)
        }
    }

    private func scrollToBottomNow(_ tab: TerminalTab) {
        guard let documentView = tab.scrollView.documentView else {
            return
        }

        documentView.layoutSubtreeIfNeeded()
        tab.scrollView.contentView.layoutSubtreeIfNeeded()

        let clipView = tab.scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let targetY: CGFloat
        if documentView.isFlipped {
            targetY = max(documentView.bounds.minY, documentView.bounds.maxY - visibleHeight)
        } else {
            targetY = documentView.bounds.minY
        }

        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        tab.scrollView.reflectScrolledClipView(clipView)
    }

    private func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
