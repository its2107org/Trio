//
//  TrioHomeWidget.swift
//  LiveActivityExtension
//
//  Custom addition (not part of upstream Trio).
//  A Home Screen and Lock Screen widget showing glucose, trend, IOB and COB.
//  Display only. The data comes from a snapshot the Trio app writes to the
//  shared app group (see TrioHomeWidgetBridge in LiveActivityManager.swift).
//
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

/// Deep, dark backdrop. When the Home Screen is set to Clear or Tinted, iOS removes
/// this and supplies its own glass, so the widget content sits directly on it.
struct TrioHomeWidgetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.11, blue: 0.16),
                Color(red: 0.03, green: 0.03, blue: 0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// A frosted, glass-like panel: a faint light fill with a thin bright edge.
struct TrioHomeWidgetGlass: ViewModifier {
    var cornerRadius: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6)
            }
    }
}

/// Shown until the Trio app has written its first snapshot.
struct TrioHomeWidgetEmptyView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall || family == .systemMedium {
            VStack(spacing: 4) {
                Text("--")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("Open Trio")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        } else {
            Text("--")
        }
    }
}

/// The big number with its trend arrow. Greyed out and struck through once the reading is old.
struct TrioHomeWidgetGlucoseView: View {
    let model: TrioHomeWidgetModel
    var size: CGFloat = 44

    var body: some View {
        let color = model.isStale
            ? Color.white.opacity(0.45)
            : TrioHomeWidgetPalette.color(hue: model.hue(mgdl: Double(model.snapshot.glucose)))
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(model.glucoseText)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .strikethrough(model.isStale, pattern: .solid, color: .red.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let direction = model.direction {
                Text(direction)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .widgetAccentable()
    }
}

/// "+3 mg/dL"
struct TrioHomeWidgetDeltaView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            // "–" when there is no recent previous reading to compare with (for example after a sensor change).
            Text(model.deltaText ?? "–")
                .fontWeight(.semibold)
                .foregroundStyle(Color.white.opacity(0.9))
            Text(model.snapshot.units)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// How old the reading is. Turns red once the reading counts as old.
struct TrioHomeWidgetAgeView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        Group {
            if model.usesRunningAge {
                // Counts up by itself, so it stays true even if iOS never reloads the widget.
                Text(model.snapshot.glucoseDate, style: .relative)
            } else {
                Text(model.ageText)
            }
        }
        .font(.caption2)
        .fontWeight(model.isStale ? .semibold : .regular)
        .foregroundStyle(model.isStale ? TrioHomeWidgetPalette.warning : Color.white.opacity(0.55))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A coloured dot and "loop 2m", like Trio's loop circle: green when the loop ran recently,
/// amber after 6 minutes, red after 15 minutes or when there is no loop result.
struct TrioHomeWidgetLoopView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(TrioHomeWidgetPalette.loop(model.loopStatus))
                .frame(width: 6, height: 6)
            Text(model.loopText)
        }
        .font(.caption2)
        .foregroundStyle(
            model.loopStatus == .fresh ? Color.white.opacity(0.55) : TrioHomeWidgetPalette.loop(model.loopStatus)
        )
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Reading age on the left, loop status on the right.
struct TrioHomeWidgetFooterView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        HStack(spacing: 4) {
            TrioHomeWidgetAgeView(model: model)
            Spacer(minLength: 2)
            TrioHomeWidgetLoopView(model: model)
        }
    }
}

/// A glass chip such as "IOB 1.2U".
struct TrioHomeWidgetStatView: View {
    let title: String
    let value: String
    let isStale: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(isStale ? 0.5 : 0.95))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .modifier(TrioHomeWidgetGlass(cornerRadius: 9))
    }
}

struct TrioHomeWidgetSmallView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TrioHomeWidgetGlucoseView(model: model, size: 44)
            TrioHomeWidgetDeltaView(model: model)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TrioHomeWidgetStatView(title: "IOB", value: model.iobText, isStale: model.isStale || model.isLoopStale)
                TrioHomeWidgetStatView(title: "COB", value: model.cobText, isStale: model.isStale || model.isLoopStale)
            }
            TrioHomeWidgetFooterView(model: model)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Left: the number, change, age and loop status. Right: the chart, with IOB and COB side by side under it,
/// so the narrow left column is not crowded.
struct TrioHomeWidgetMediumView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TrioHomeWidgetGlucoseView(model: model, size: 38)
                TrioHomeWidgetDeltaView(model: model)
                Spacer(minLength: 0)
                TrioHomeWidgetAgeView(model: model)
                TrioHomeWidgetLoopView(model: model)
            }
            .frame(width: 96, alignment: .leading)

            VStack(spacing: 6) {
                TrioHomeWidgetChartView(model: model)
                    .padding(.leading, 6)
                    .padding(.vertical, 6)
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(TrioHomeWidgetGlass(cornerRadius: 14))
                HStack(spacing: 6) {
                    TrioHomeWidgetStatView(title: "IOB", value: model.iobText, isStale: model.isStale || model.isLoopStale)
                    TrioHomeWidgetStatView(title: "COB", value: model.cobText, isStale: model.isStale || model.isLoopStale)
                }
            }
        }
    }
}

/// The last three hours as dots plus, when the loop is current, Trio's forecast for
/// the next two hours (a shaded cone or separate lines, following the setting in Trio).
struct TrioHomeWidgetChartView: View {
    let model: TrioHomeWidgetModel

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
        .opacity(model.isStale ? 0.5 : 1)
    }
}

// MARK: - Lock Screen sizes

struct TrioHomeWidgetCircularView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.glucoseText)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .strikethrough(model.isStale, pattern: .solid, color: .primary)
                .minimumScaleFactor(0.6)
                .widgetAccentable()
            // Fresh: trend arrow. Old: how old, so an old number is never mistaken for a current one.
            if model.isStale {
                if model.usesRunningAge {
                    Text("old")
                        .font(.caption2)
                } else {
                    Text(model.shortAgeText)
                        .font(.caption2)
                }
            } else if let direction = model.direction {
                Text(direction)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
        }
        .lineLimit(1)
    }
}

struct TrioHomeWidgetRectangularView: View {
    let model: TrioHomeWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.glucoseText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .strikethrough(model.isStale, pattern: .solid, color: .primary)
                    .widgetAccentable()
                // Like the circular size: no trend arrow or delta on an old reading.
                if !model.isStale {
                    if let direction = model.direction {
                        Text(direction)
                            .fontWeight(.bold)
                    }
                    if let delta = model.deltaText {
                        Text(delta)
                            .font(.caption)
                    }
                }
            }
            Text("IOB \(model.iobText)  COB \(model.cobText)")
                .font(.caption)
            HStack(spacing: 0) {
                if model.usesRunningAge {
                    Text(model.snapshot.glucoseDate, style: .relative)
                } else {
                    Text(model.isStale ? "OLD: \(model.ageText)" : model.ageText)
                }
                // Loop age only when it needs attention, to keep this line short.
                if model.loopStatus != .fresh {
                    Text(" · \(model.loopText)")
                }
            }
            .font(.caption2)
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
        if model.usesRunningAge {
            return "Trio: no recent reading"
        }
        if model.isStale {
            return "OLD \(model.glucoseText) (\(model.ageText))"
        }
        var parts = [model.glucoseText]
        if let direction = model.direction { parts.append(direction) }
        if let delta = model.deltaText { parts.append(delta) }
        return parts.joined(separator: " ") + " · " + model.shortAgeText
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
