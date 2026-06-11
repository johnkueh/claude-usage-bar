import AppKit

// All drawing: the status-bar item (account initial + two stacked mini bars)
// and the attributed two-line account rows inside the menu. Colors are
// semantic (green/amber/red by threshold); everything else stays system
// neutral so the menu reads native.
enum Render {
    static func color(_ pct: Double) -> NSColor {
        if pct >= 90 { return .systemRed }
        if pct >= 70 { return .systemOrange }
        return .systemGreen
    }

    private static func drawBar(_ pct: Double?, in rect: NSRect) {
        let radius = rect.height / 2
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard let pct else { return }
        let clamped = min(max(pct, 0), 100)
        let width = max(rect.height, rect.width * CGFloat(clamped) / 100)
        var fill = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        fill = fill.intersection(rect)
        color(clamped).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    // Same compact countdown as ~/.claude/scripts/statusline.sh: "now / 3m / 2h / 3d".
    // >30m rounds to the nearest hour; under 30m shows exact minutes.
    static func countdown(_ date: Date?) -> String {
        guard let date else { return "" }
        let diff = Int(date.timeIntervalSinceNow)
        if diff <= 0 { return "now" }
        if diff >= 86400 { return "\((diff + 43200) / 86400)d" }
        if diff >= 1800 { return "\((diff + 1800) / 3600)h" }
        return "\(diff / 60)m"
    }

    // The menu bar item: statusline format, stacked —
    //   S:47%/3h
    //   W:10%/5d
    // Drawn into an image at display time so labelColor resolves against the
    // menu bar's appearance. The % value picks up amber/red when hot; a
    // trailing ~ marks stale (cached) numbers, like the statusline.
    static func statusText(_ usage: Usage?, stale: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

        func line(_ label: String, _ pct: Double?, _ reset: Date?) -> NSAttributedString {
            let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let result = NSMutableAttributedString(string: "\(label):", attributes: dim)
            guard let pct else {
                result.append(NSAttributedString(string: "–", attributes: dim))
                return result
            }
            let valueColor: NSColor = pct >= 90 ? .systemRed : pct >= 70 ? .systemOrange : .labelColor
            result.append(NSAttributedString(string: String(format: "%.0f%%", pct),
                                             attributes: [.font: font, .foregroundColor: valueColor]))
            let t = countdown(reset)
            if !t.isEmpty {
                result.append(NSAttributedString(string: "/\(t)", attributes: dim))
            }
            if stale {
                result.append(NSAttributedString(string: "~", attributes: dim))
            }
            return result
        }

        let top = line("S", usage?.fiveHourPct, usage?.fiveHourReset)
        let bottom = line("W", usage?.sevenDayPct, usage?.sevenDayReset)
        let width = ceil(max(top.size().width, bottom.size().width)) + 1
        let image = NSImage(size: NSSize(width: width, height: 21), flipped: false) { _ in
            top.draw(at: NSPoint(x: 0, y: 10.5))
            bottom.draw(at: NSPoint(x: 0, y: 0.5))
            return true
        }
        image.isTemplate = false
        return image
    }

    static func gaugeImage(_ pct: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 36, height: 7), flipped: false) { rect in
            drawBar(pct, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    // "2:59am" inside ~22h, otherwise "wed 9am" (rounded to the nearest hour —
    // resets land at hh:59:59, and "5pm" for 5:59pm reads an hour early).
    static func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let fmt = DateFormatter()
        let nearTerm = date.timeIntervalSinceNow < 22 * 3600
        fmt.dateFormat = nearTerm ? "h:mma" : "EEE ha"
        let display = nearTerm ? date : date.addingTimeInterval(1800)
        return fmt.string(from: display).lowercased()
    }

    static func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // Two-line menu row: account name, then "5h [bar] 47% 2:59am · wk [bar] 10% wed 9am".
    static func accountTitle(name: String, state: UsageState?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        title.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))

        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let smallDim: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        func gauge(_ label: String, _ pct: Double, _ reset: Date?) -> NSAttributedString {
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: "\(label) ", attributes: smallDim))
            let attachment = NSTextAttachment()
            attachment.image = gaugeImage(pct)
            attachment.bounds = CGRect(x: 0, y: 0.5, width: 36, height: 7)
            let bar = NSMutableAttributedString(attachment: attachment)
            bar.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: bar.length))
            line.append(bar)
            line.append(NSAttributedString(string: String(format: " %.0f%%", pct), attributes: small))
            let resetStr = resetText(reset)
            if !resetStr.isEmpty {
                line.append(NSAttributedString(string: " \(resetStr)", attributes: smallDim))
            }
            return line
        }

        title.append(NSAttributedString(string: "\n", attributes: smallDim))
        switch state {
        case .fresh(let u), .stale(let u, _):
            title.append(gauge("5h", u.fiveHourPct, u.fiveHourReset))
            title.append(NSAttributedString(string: "  ·  ", attributes: smallDim))
            title.append(gauge("wk", u.sevenDayPct, u.sevenDayReset))
            if case .stale(_, let reason) = state! {
                title.append(NSAttributedString(string: "\n\(reason) — switch once to refresh", attributes: smallDim))
            }
        case .unavailable(let reason):
            title.append(NSAttributedString(string: reason, attributes: smallDim))
        case nil:
            title.append(NSAttributedString(string: "loading…", attributes: smallDim))
        }
        return title
    }
}
