//
//  TrioHomeWidget.swift
//  LiveActivityExtension
//
//  Custom addition (not part of upstream Trio).
//  A Home Screen and Lock Screen widget showing glucose, trend, IOB and COB.
//  Display only. The data comes from a snapshot the Trio app writes to the
//  shared app group (see TrioHomeWidgetBridge in LiveActivityManager.swift).
//
import AppIntents
import Charts
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct TrioHomeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TrioHomeWidgetSnapshot?
}

struct TrioHomeWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioHomeWidgetEntry {
        TrioHomeWidgetEntry(date: Date(), snapshot: TrioHomeWidgetSnapshot.sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioHomeWidgetEntry) -> Void) {
        let stored = TrioHomeWidgetStore.load()
        let snapshot = context.isPreview ? (stored ?? TrioHomeWidgetSnapshot.sample()) : stored
        completion(TrioHomeWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioHomeWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = TrioHomeWidgetStore.load()
        var entries = [TrioHomeWidgetEntry(date: now, snapshot: snapshot)]

        // iOS decides when a widget is allowed to reload, and it can be slow about it.
        // So the timeline carries one entry per minute of the reading's age. That keeps
        // the "x min ago" label and the greyed-out "old data" look correct even if no
        // reload happens. The last entry switches to a self-updating duration.
        if let snapshot {
            let limit = TrioHomeWidgetModel.minuteLabelLimit
            for minute in 1 ... limit {
                let date = snapshot.glucoseDate.addingTimeInterval(TimeInterval(minute * 60))
                if date > now {
                    entries.append(TrioHomeWidgetEntry(date: date, snapshot: snapshot))
                }
            }
        }

        // Fallback refresh in case the app could not ask for one.
        let refresh = now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

// MARK: - Refresh button

/// Tapping the refresh button redraws the widget from the latest snapshot without opening Trio.
/// Trio saves every new reading to the snapshot even when iOS skips a scheduled refresh,
/// and refreshes started from a tap do not count against the daily limit. Display only.
struct TrioHomeWidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Trio widget"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: TrioHomeWidgetStore.kind)
        return .result()
    }
}

// MARK: - Widget

struct TrioHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrioHomeWidgetStore.kind, provider: TrioHomeWidgetProvider()) { entry in
            TrioHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    TrioHomeWidgetBackground()
                }
                // Tapping anywhere on the widget opens Trio.
                .widgetURL(URL(string: "Trio://"))
        }
        .configurationDisplayName("Trio Glucose")
        .description("Glucose, trend, IOB, COB and forecast from Trio.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Views

struct TrioHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TrioHomeWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            let model = TrioHomeWidgetModel(snapshot: snapshot, now: entry.date)
            Group {
                switch family {
                case .systemMedium:
                    TrioHomeWidgetMediumView(model: model)
                case .systemLarge:
                    TrioHomeWidgetLargeView(model: model)
                case .accessoryCircular:
                    TrioHomeWidgetCircularView(model: model)
                case .accessoryRectangular:
                    TrioHomeWidgetRectangularView(model: model)
                case .accessoryInline:
                    TrioHomeWidgetInlineView(model: model)
                default:
                    TrioHomeWidgetSmallView(model: model)
                }
            }
            // VoiceOver reads one clear sentence instead of the separate pieces.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.accessibilityText))
        } else {
            TrioHomeWidgetEmptyView()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Trio glucose. No reading yet. Open Trio."))
        }
    }
}

/// Dark backdrop close to Apple's own dark widgets. When the Home Screen is set to Clear or
/// Tinted, iOS removes this and supplies its own glass, so the content sits directly on it.
struct TrioHomeWidgetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.165, green: 0.165, blue: 0.180),
                Color(red: 0.086, green: 0.086, blue: 0.094)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Shown until the Trio app has written its first snapshot.
struct TrioHomeWidgetEmptyView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall || family == .systemMedium || family == .systemLarge {
            VStack(spacing: 4) {
                Text("--")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("Open Trio")
                    .font(.footnote)
                    .foregroundStyle(TrioHomeWidgetPalette.secondary)
            }
        } else {
            Text("--")
        }
    }
}

/// The full-width "Loop 9m" pill across the top. Green dot while the loop is current, amber after
/// 5 minutes, red after 15. The whole pill is a button: tapping it refreshes the widget.
struct TrioHomeWidgetLoopPill: View {
    let model: TrioHomeWidgetModel
    var showsReadingAge = false
    var fontSize: CGFloat = 13
    var height: CGFloat = 28

    var body: some View {
        Button(intent: TrioHomeWidgetRefreshIntent()) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(model.loopPillText)
                if showsReadingAge {
                    Text("· reading \(model.ageText)")
                        .fontWeight(.medium)
                        .foregroundStyle(metaColor)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(metaColor)
            }
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(fillColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Apple's guidelines inset grouping shapes 11 pt from the edge, 5 pt less than the content margin.
        .padding(.horizontal, -5)
        .padding(.top, -5)
    }

    private var dotColor: Color {
        switch model.loopStatus {
        case .fresh: return TrioHomeWidgetPalette.systemGreen
        case .aging: return TrioHomeWidgetPalette.systemOrange
        case .stale: return TrioHomeWidgetPalette.systemRed
        }
    }

    private var textColor: Color {
        switch model.loopStatus {
        case .fresh: return Color.white
        case .aging: return TrioHomeWidgetPalette.systemOrange
        case .stale: return TrioHomeWidgetPalette.softRed
        }
    }

    private var metaColor: Color {
        model.loopStatus == .fresh ? TrioHomeWidgetPalette.secondary : textColor.opacity(0.85)
    }

    private var fillColor: Color {
        switch model.loopStatus {
        case .fresh: return TrioHomeWidgetPalette.pillFill
        case .aging: return TrioHomeWidgetPalette.systemOrange.opacity(0.2)
        case .stale: return TrioHomeWidgetPalette.systemRed.opacity(0.22)
        }
    }
}

/// The big number with its trend arrow. Greyed out and crossed out once it is too old
/// to trust for its trend (see `TrioHomeWidgetModel.crossOutAfter`).
struct TrioHomeWidgetNumberView: View {
    let model: TrioHomeWidgetModel
    var size: CGFloat

    var body: some View {
        let color = model.isStale
            ? TrioHomeWidgetPalette.tertiary
            : TrioHomeWidgetPalette.color(hue: model.hue(mgdl: Double(model.snapshot.glucose)))
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text(model.glucoseText)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .tracking(-size * 0.03)
                .strikethrough(model.isStale, pattern: .solid, color: TrioHomeWidgetPalette.systemRed)
            if let direction = model.direction {
                Text(direction)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .widgetAccentable()
    }
}

/// "+6 mg/dL". "–" when there is no recent previous reading to compare with.
struct TrioHomeWidgetDeltaView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        (
            Text(model.deltaText ?? "–")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                + Text(" \(model.snapshot.units)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TrioHomeWidgetPalette.secondary)
        )
        .lineLimit(1)
    }
}

/// "IOB 1.35 U" on one line: label in grey, value in white.
struct TrioHomeWidgetInlineStat: View {
    let title: String
    let value: String

    var body: some View {
        (
            Text("\(title) ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TrioHomeWidgetPalette.secondary)
                + Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
        )
        .lineLimit(1)
    }
}

/// Label above value, for the large size.
struct TrioHomeWidgetStackedStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(TrioHomeWidgetPalette.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .lineLimit(1)
    }
}

/// Pill on top, the number centred, IOB and COB along the bottom.
struct TrioHomeWidgetSmallView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        VStack(spacing: 0) {
            TrioHomeWidgetLoopPill(model: model)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                TrioHomeWidgetNumberView(model: model, size: 58)
                TrioHomeWidgetDeltaView(model: model)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                TrioHomeWidgetInlineStat(title: "IOB", value: model.iobText)
                TrioHomeWidgetInlineStat(title: "COB", value: model.cobText)
            }
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pill on top. Below: the number, change, IOB and COB on the left, the chart on the right.
struct TrioHomeWidgetMediumView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        VStack(spacing: 10) {
            TrioHomeWidgetLoopPill(model: model, showsReadingAge: true)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    TrioHomeWidgetNumberView(model: model, size: 42)
                    TrioHomeWidgetDeltaView(model: model)
                        .padding(.top, 4)
                    Spacer(minLength: 2)
                    TrioHomeWidgetInlineStat(title: "IOB", value: model.iobText)
                    TrioHomeWidgetInlineStat(title: "COB", value: model.cobText)
                }
                .frame(width: 112, alignment: .leading)

                TrioHomeWidgetChartView(model: model, showsHours: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Pill on top, a big number with IOB and COB beside it, and a large chart below.
struct TrioHomeWidgetLargeView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        VStack(spacing: 0) {
            TrioHomeWidgetLoopPill(model: model, showsReadingAge: true, fontSize: 14, height: 30)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    TrioHomeWidgetNumberView(model: model, size: 64)
                    TrioHomeWidgetDeltaView(model: model)
                }
                Spacer(minLength: 8)
                HStack(alignment: .top, spacing: 20) {
                    TrioHomeWidgetStackedStat(title: "IOB", value: model.iobText)
                    TrioHomeWidgetStackedStat(title: "COB", value: model.cobText)
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 12)
            TrioHomeWidgetChartView(model: model, showsHours: true)
                .frame(maxWidth: .infinity)
                .frame(height: 196)
        }
    }
}

struct TrioHomeWidgetChartView: View {
    let model: TrioHomeWidgetModel
    /// Clock times along the bottom. Off on the wide size, where they would be too small to read.
    var showsHours = true

    var body: some View {
        let points = model.chartPoints
        let cone = model.forecastCone
        let lines = model.forecastLinePoints

        Chart {
            RuleMark(y: .value("High", model.highLine))
                .foregroundStyle(Color.white.opacity(0.35))
                .lineStyle(.init(lineWidth: 1, dash: [4, 3]))

            RuleMark(y: .value("Low", model.lowLine))
                .foregroundStyle(Color.white.opacity(0.35))
                .lineStyle(.init(lineWidth: 1, dash: [4, 3]))

            if model.showsForecast {
                // Marks "now": history to the left, forecast to the right.
                RuleMark(x: .value("Now", model.now))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .lineStyle(.init(lineWidth: 1))
            }

            ForEach(cone, id: \.self) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Min", point.low),
                    yEnd: .value("Max", point.high)
                )
                .foregroundStyle(TrioHomeWidgetPalette.cone)
                .interpolationMethod(.linear)
            }

            ForEach(lines, id: \.self) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", point.value),
                    series: .value("Type", point.series)
                )
                .foregroundStyle(TrioHomeWidgetPalette.forecastLine(point.series))
                .lineStyle(.init(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }

            ForEach(points, id: \.self) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Value", point.display)
                )
                .symbolSize(12)
                .foregroundStyle(TrioHomeWidgetPalette.color(hue: model.hue(mgdl: Double(point.mgdl))))
            }
        }
        .chartYScale(domain: model.chartYDomain)
        .chartXScale(domain: model.chartStart ... model.chartEnd)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [model.lowLine, model.highLine]) { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .chartXAxis {
            // Clock times along the bottom: every hour, or every two hours when the
            // forecast widens the chart and hourly labels would crowd each other.
            AxisMarks(values: .stride(by: .hour, count: model.showsForecast ? 2 : 1)) { _ in
                AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.white.opacity(0.18))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .chartXAxis(showsHours ? .visible : .hidden)
        .opacity(model.isStale ? 0.5 : 1)
    }
}

// MARK: - Lock Screen sizes
// iOS draws these in a single tint, so the Loop label goes from outlined to filled
// (instead of changing colour) once the loop is more than 5 minutes old.

struct TrioHomeWidgetCircularView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        let filled = model.loopStatus != .fresh
        VStack(spacing: 1) {
            Text(model.glucoseText)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .strikethrough(model.isStale, pattern: .solid, color: .primary)
                .opacity(model.isStale ? 0.6 : 1)
                .minimumScaleFactor(0.6)
                .widgetAccentable()
            Text(model.loopShortText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(filled ? Color.black : Color.primary)
                .padding(.horizontal, 5)
                .background(Capsule().fill(filled ? Color.white : Color.clear))
        }
        .lineLimit(1)
    }
}

struct TrioHomeWidgetRectangularView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        let filled = model.loopStatus != .fresh
        VStack(alignment: .leading, spacing: 3) {
            Button(intent: TrioHomeWidgetRefreshIntent()) {
                HStack(spacing: 5) {
                    Text(model.loopPillText)
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(filled ? Color.black : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Capsule().fill(filled ? Color.white : Color.clear))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(filled ? 0 : 0.85), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Refresh. \(model.loopPillText)"))

            HStack(alignment: .center, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(model.glucoseText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .strikethrough(model.isStale, pattern: .solid, color: .primary)
                        .opacity(model.isStale ? 0.6 : 1)
                        .widgetAccentable()
                    if !model.isStale, let direction = model.direction {
                        Text(direction)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                }
                Text(model.isStale ? "old" : (model.deltaText ?? "–"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("IOB ") + Text(model.iobText).bold()
                    Text("COB ") + Text(model.cobText).bold()
                }
                .font(.system(size: 11))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrioHomeWidgetInlineView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        Text(text)
    }

    private var text: String {
        if model.isStale {
            return "\(model.loopPillText) · old \(model.glucoseText)"
        }
        var parts = [model.glucoseText]
        if let direction = model.direction { parts.append(direction) }
        if let delta = model.deltaText { parts.append(delta) }
        return "\(model.loopPillText) · " + parts.joined(separator: " ")
    }
}

// MARK: - Colour

enum TrioHomeWidgetPalette {
    /// Trio's glucose colours (red when low, green at target, purple when high),
    /// slightly brighter to stand out on the dark glass backdrop.
    static func color(hue: Double) -> Color {
        Color(hue: hue, saturation: 0.62, brightness: 0.96)
    }

    static let warning = Color(red: 1.0, green: 0.42, blue: 0.40)

    /// Apple's dark-mode system colours, for the Loop pill.
    static let systemGreen = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let systemOrange = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let systemRed = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let softRed = Color(red: 1.0, green: 0.412, blue: 0.380)
    static let pillFill = Color(red: 0.47, green: 0.47, blue: 0.50).opacity(0.32)
    /// Apple's secondary and tertiary label colours on a dark background.
    static let secondary = Color(red: 0.92, green: 0.92, blue: 0.96).opacity(0.6)
    static let tertiary = Color(red: 0.92, green: 0.92, blue: 0.96).opacity(0.3)

    /// Loop status colours, close to Trio's loop circle.
    static func loop(_ status: TrioHomeWidgetModel.LoopStatus) -> Color {
        switch status {
        case .fresh: return Color(red: 0.24, green: 0.81, blue: 0.48)
        case .aging: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .stale: return warning
        }
    }
    static let cone = Color(red: 0.35, green: 0.62, blue: 1.0).opacity(0.45)

    /// Same line colours Trio uses for its forecast lines.
    static func forecastLine(_ series: String) -> Color {
        switch series {
        case "iob": return Color(red: 0.118, green: 0.588, blue: 0.988)
        case "cob": return Color.orange
        case "uam": return Color(red: 0.820, green: 0.169, blue: 0.969)
        case "zt": return Color(red: 0.443, green: 0.380, blue: 0.937)
        default: return Color.gray
        }
    }
}
