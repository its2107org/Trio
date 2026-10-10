//
//  TrioHomeWidgetModel.swift
//  LiveActivityExtension
//
//  Custom addition (not part of upstream Trio).
//  Data and formatting for the Home Screen / Lock Screen widget.
//  This file is plain Foundation on purpose: no SwiftUI, no pump or CGM access.
//
import Foundation

/// A small, display-only copy of what the Trio app currently shows.
/// The app writes it to the shared app group, the widget reads it.
/// Keep the fields in sync with `TrioHomeWidgetBridge.Snapshot` in the app target
/// (LiveActivityManager.swift).
struct TrioHomeWidgetForecastLine: Codable, Equatable {
    /// "iob", "cob", "uam" or "zt".
    var type: String
    /// Predicted glucose in mg/dL, one value every five minutes.
    var values: [Int]
}

struct TrioHomeWidgetSnapshot: Codable, Equatable {
    /// Latest glucose reading in mg/dL.
    var glucose: Int
    /// When that reading was taken.
    var glucoseDate: Date
    /// The reading before it, in mg/dL, if it is recent enough to give a meaningful delta.
    var previousGlucose: Int?
    /// Trend arrow as text, for example "→".
    var direction: String?
    /// "mg/dL" or "mmol/L" (the unit chosen in Trio).
    var units: String
    /// Low and high limits from Trio settings, in mg/dL.
    var low: Double
    var high: Double
    /// Current target in mg/dL, if a loop result is available.
    var target: Double?
    /// "staticColor" or "dynamicColor" (the glucose colour setting in Trio).
    var colorScheme: String
    /// Insulin on board in units.
    var iob: Double?
    /// Carbs on board in grams.
    var cob: Int?
    /// When the loop last produced a result.
    var loopDate: Date?
    /// Recent readings for the chart: seconds since 1970 and mg/dL, same length.
    var historyDates: [Double]
    var historyValues: [Int]
    /// Trio's forecast from the last loop, in mg/dL, one value every five minutes starting
    /// at `loopDate`. "cone" uses the min/max pair, "lines" uses the individual lines.
    var forecastStyle: String?
    var forecastMin: [Int]?
    var forecastMax: [Int]?
    var forecastLines: [TrioHomeWidgetForecastLine]?
}

enum TrioHomeWidgetStore {
    static let kind = "TrioHomeWidget"
    static let storageKey = "trioHomeWidget.snapshot.v1"

    /// The app group both the app and this extension belong to.
    static var appGroupID: String? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
           configured.hasPrefix("group.")
        {
            return configured
        }
        // Fallback: derive it from the extension's bundle identifier
        // (org.nightscout.TEAM.trio.LiveActivity -> group.org.nightscout.TEAM.trio.trio-app-group).
        guard let bundleID = Bundle.main.bundleIdentifier,
              let lastDot = bundleID.lastIndex(of: ".")
        else { return nil }
        return "group.\(bundleID[..<lastDot]).trio-app-group"
    }

    static func load() -> TrioHomeWidgetSnapshot? {
        guard let groupID = appGroupID,
              let defaults = UserDefaults(suiteName: groupID),
              let data = defaults.data(forKey: storageKey)
        else { return nil }
        return try? JSONDecoder().decode(TrioHomeWidgetSnapshot.self, from: data)
    }
}

/// Everything the views need, already formatted, for one moment in time.
struct TrioHomeWidgetModel {
    let snapshot: TrioHomeWidgetSnapshot
    /// The moment this widget entry is shown (not when it was built).
    let now: Date

    /// A reading older than this is drawn greyed out and struck through.
    /// iOS only lets the app refresh the widget about every 20 minutes in the background
    /// (see TrioHomeWidgetBridge), so a reading up to about 25 minutes old is normal here.
    /// Anything older means Trio really has stopped getting readings.
    static let staleAfter: TimeInterval = 27 * 60
    /// Past this age (in minutes) the label switches from "x min ago" to a self-updating duration.
    static let minuteLabelLimit = 30
    /// How much history the chart shows.
    static let chartWindow: TimeInterval = 3 * 60 * 60

    private static let mmolRate: Decimal = 0.0555

    /// How far ahead the forecast is drawn.
    static let forecastHorizon: TimeInterval = 2 * 60 * 60
    /// A forecast from a loop older than this is not drawn at all, and the loop shows red.
    static let forecastMaxAge: TimeInterval = 30 * 60
    /// Forecast values above this are clipped, like in Trio's own charts.
    static let forecastCeiling = 300

    struct ConePoint: Hashable {
        let date: Date
        let low: Double
        let high: Double
    }

    struct LinePoint: Hashable {
        let series: String
        let date: Date
        let value: Double
    }

    struct ChartPoint: Hashable {
        let date: Date
        let mgdl: Int
        /// Value in the unit the user picked in Trio.
        let display: Double
    }

    enum Band { case low, inRange, high }

    // MARK: Age

    var age: TimeInterval { max(0, now.timeIntervalSince(snapshot.glucoseDate)) }
    var ageMinutes: Int { Int(age / 60) }
    var isStale: Bool { age >= Self.staleAfter }
    /// True once "x min ago" would no longer be trustworthy as a fixed label.
    var usesRunningAge: Bool { ageMinutes >= Self.minuteLabelLimit }

    /// True when the loop has not produced a result recently, so IOB and COB may be out of date.
    var isLoopStale: Bool { loopStatus == .stale }

    /// Like Trio's loop circle: fresh (green), aging (amber) or stale (red).
    enum LoopStatus { case fresh, aging, stale }

    /// A loop result older than this is shown as aging (longer than the normal gap between widget refreshes).
    static let loopAgingAfter: TimeInterval = 26 * 60

    var loopAgeMinutes: Int? {
        guard let loopDate = snapshot.loopDate else { return nil }
        return Int(max(0, now.timeIntervalSince(loopDate)) / 60)
    }

    var loopStatus: LoopStatus {
        guard let loopDate = snapshot.loopDate else { return .stale }
        let loopAge = now.timeIntervalSince(loopDate)
        if loopAge > Self.forecastMaxAge { return .stale }
        if loopAge > Self.loopAgingAfter { return .aging }
        return .fresh
    }

    /// "loop 2m", "loop now" or "no loop".
    var loopText: String {
        guard let minutes = loopAgeMinutes else { return "no loop" }
        return minutes < 1 ? "loop now" : "loop \(minutes)m"
    }

    var ageText: String {
        ageMinutes < 1 ? "now" : "\(ageMinutes)m ago"
    }

    var shortAgeText: String {
        ageMinutes < 1 ? "now" : "\(ageMinutes)m"
    }

    // MARK: Glucose

    var isMmol: Bool { snapshot.units == "mmol/L" }

    var glucoseText: String { Self.format(mgdl: snapshot.glucose, mmol: isMmol, signed: false) }

    /// Change since the previous reading, with a sign, or nil if there is nothing recent to compare with.
    var deltaText: String? {
        guard let previous = snapshot.previousGlucose else { return nil }
        if isMmol {
            let delta = Self.mmol(snapshot.glucose) - Self.mmol(previous)
            return Self.format(decimal: delta, fractionDigits: 1, signed: true)
        }
        return Self.format(decimal: Decimal(snapshot.glucose - previous), fractionDigits: 0, signed: true)
    }

    var direction: String? {
        guard let direction = snapshot.direction, !direction.isEmpty else { return nil }
        return direction
    }

    var band: Band { Self.band(mgdl: Double(snapshot.glucose), low: snapshot.low, high: snapshot.high) }

    /// The trend arrow in words, for VoiceOver.
    var directionWords: String? {
        switch direction ?? "" {
        case "↑↑↑", "↑↑": return "rising fast"
        case "↑": return "rising"
        case "↗︎", "↗": return "rising slightly"
        case "→": return "steady"
        case "↘︎", "↘": return "falling slightly"
        case "↓": return "falling"
        case "↓↓", "↓↓↓": return "falling fast"
        default: return nil
        }
    }

    /// What VoiceOver reads for the whole widget, for example
    /// "Glucose 112 mg/dL, steady, 1 minute ago. Insulin on board 1.25 units. Carbs on board 20 grams."
    var accessibilityText: String {
        var parts = ["Glucose \(glucoseText) \(snapshot.units)"]
        if let directionWords { parts.append(directionWords) }
        if ageMinutes < 1 {
            parts.append("just now")
        } else {
            parts.append(ageMinutes == 1 ? "1 minute ago" : "\(ageMinutes) minutes ago")
        }
        var text = parts.joined(separator: ", ")
        if isStale { text += ". This reading is old" }
        if snapshot.iob != nil { text += ". Insulin on board \(iobText.dropLast()) units" }
        if let cob = snapshot.cob { text += ". Carbs on board \(cob) grams" }
        switch loopStatus {
        case .fresh: break
        case .aging, .stale: text += ". Loop last ran \(loopAgeMinutes.map { "\($0) minutes ago" } ?? "a while ago")"
        }
        return text + "."
    }

    // MARK: Insulin and carbs

    var iobText: String {
        guard let iob = snapshot.iob else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: iob)) ?? "--") + "U"
    }

    var cobText: String {
        guard let cob = snapshot.cob else { return "--" }
        return "\(cob)g"
    }

    // MARK: Colour

    /// Hue between 0 and 1 for a glucose value, following Trio's own colour rules:
    /// red when low, green at target, purple when high.
    func hue(mgdl: Double) -> Double {
        let red = 0.0
        let green = 120.0 / 360.0
        let purple = 270.0 / 360.0

        guard snapshot.colorScheme == "dynamicColor" else {
            switch Self.band(mgdl: mgdl, low: snapshot.low, high: snapshot.high) {
            case .low: return red
            case .inRange: return green
            case .high: return purple
            }
        }

        // Same fixed anchors Trio uses for its dynamic colours.
        let low = 55.0
        let high = 220.0
        let rawTarget = snapshot.target ?? 100
        let target = min(max(rawTarget, low + 1), high - 1)

        if mgdl <= low { return red }
        if mgdl >= high { return purple }
        if mgdl <= target {
            let ratio = (mgdl - low) / (target - low)
            return red + ratio * (green - red)
        }
        let ratio = (mgdl - target) / (high - target)
        return green + ratio * (purple - green)
    }

    // MARK: Chart

    var chartStart: Date { now.addingTimeInterval(-Self.chartWindow) }

    var chartEnd: Date {
        let lastForecast = (forecastCone.map(\.date) + forecastLinePoints.map(\.date)).max()
        return max(lastForecast ?? now, now).addingTimeInterval(5 * 60)
    }

    // MARK: Forecast

    /// The loop time the forecast starts from, but only while the forecast is still worth showing:
    /// the reading must be current and the loop recent.
    private var forecastAnchor: Date? {
        guard !isStale, let loopDate = snapshot.loopDate else { return nil }
        let loopAge = now.timeIntervalSince(loopDate)
        guard loopAge >= -60, loopAge <= Self.forecastMaxAge else { return nil }
        return loopDate
    }

    private func forecastDate(_ index: Int, anchor: Date) -> Date? {
        let date = anchor.addingTimeInterval(TimeInterval(index * 300))
        return date <= now.addingTimeInterval(Self.forecastHorizon) ? date : nil
    }

    private func forecastValue(_ mgdl: Int) -> Double {
        displayValue(mgdl: Double(min(max(mgdl, 0), Self.forecastCeiling)))
    }

    /// Shaded band between the lowest and highest forecast ("cone" style in Trio).
    var forecastCone: [ConePoint] {
        guard snapshot.forecastStyle == "cone",
              let anchor = forecastAnchor,
              let lows = snapshot.forecastMin,
              let highs = snapshot.forecastMax
        else { return [] }
        return (0 ..< min(lows.count, highs.count)).compactMap { index in
            guard let date = forecastDate(index, anchor: anchor) else { return nil }
            var low = forecastValue(min(lows[index], highs[index]))
            var high = forecastValue(max(lows[index], highs[index]))
            if high - low < 0.01 {
                // Give a zero-width band a little thickness so it stays visible.
                let pad = isMmol ? 0.06 : 1.0
                low -= pad
                high += pad
            }
            return ConePoint(date: date, low: low, high: high)
        }
    }

    /// Individual forecast lines ("lines" style in Trio).
    var forecastLinePoints: [LinePoint] {
        guard snapshot.forecastStyle == "lines",
              let anchor = forecastAnchor,
              let lines = snapshot.forecastLines
        else { return [] }
        return lines.flatMap { line in
            line.values.indices.compactMap { index -> LinePoint? in
                guard let date = forecastDate(index, anchor: anchor) else { return nil }
                return LinePoint(series: line.type, date: date, value: forecastValue(line.values[index]))
            }
        }
    }

    var showsForecast: Bool { !forecastCone.isEmpty || !forecastLinePoints.isEmpty }

    var chartPoints: [ChartPoint] {
        let count = min(snapshot.historyDates.count, snapshot.historyValues.count)
        guard count > 0 else { return [] }
        let start = chartStart
        return (0 ..< count).compactMap { index in
            let date = Date(timeIntervalSince1970: snapshot.historyDates[index])
            guard date >= start, date <= now.addingTimeInterval(60) else { return nil }
            let mgdl = snapshot.historyValues[index]
            return ChartPoint(date: date, mgdl: mgdl, display: displayValue(mgdl: Double(mgdl)))
        }
    }

    var lowLine: Double { displayValue(mgdl: snapshot.low) }
    var highLine: Double { displayValue(mgdl: snapshot.high) }

    /// Vertical range of the chart, in the user's unit. Always includes the low and high lines.
    var chartYDomain: ClosedRange<Double> {
        let values = chartPoints.map(\.mgdl).map(Double.init)
        let lowest = min(values.min() ?? snapshot.low, snapshot.low) - 15
        let highest = max(values.max() ?? snapshot.high, snapshot.high) + 15
        var lower = displayValue(mgdl: max(lowest, 30))
        var upper = displayValue(mgdl: min(max(highest, lowest + 40), 420))
        // Make room for the forecast (already in display units).
        let forecastValues = forecastCone.flatMap { [$0.low, $0.high] } + forecastLinePoints.map(\.value)
        if let forecastLow = forecastValues.min() { lower = min(lower, max(forecastLow, 0)) }
        if let forecastHigh = forecastValues.max() { upper = max(upper, forecastHigh) }
        return lower ... max(upper, lower + 1)
    }

    func displayValue(mgdl: Double) -> Double {
        isMmol ? mgdl * 0.0555 : mgdl
    }

    // MARK: Helpers

    static func band(mgdl: Double, low: Double, high: Double) -> Band {
        if mgdl <= low { return .low }
        if mgdl >= high { return .high }
        return .inRange
    }

    /// mg/dL to mmol/L, rounded to one decimal the same way Trio does it.
    static func mmol(_ mgdl: Int) -> Decimal {
        var result = Decimal()
        var value = Decimal(mgdl) * mmolRate
        NSDecimalRound(&result, &value, 1, .plain)
        return result
    }

    static func format(mgdl: Int, mmol: Bool, signed: Bool) -> String {
        mmol
            ? format(decimal: Self.mmol(mgdl), fractionDigits: 1, signed: signed)
            : format(decimal: Decimal(mgdl), fractionDigits: 0, signed: signed)
    }

    static func format(decimal: Decimal, fractionDigits: Int, signed: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        if signed {
            formatter.positivePrefix = formatter.plusSign
        }
        return formatter.string(from: decimal as NSDecimalNumber) ?? "--"
    }
}

extension TrioHomeWidgetSnapshot {
    /// Made-up numbers shown in the widget gallery before real data exists.
    static func sample(now: Date = Date()) -> TrioHomeWidgetSnapshot {
        let values = [
            142, 139, 137, 133, 130, 127, 124, 121, 118, 116, 115, 113, 112, 110, 109, 108, 108, 107,
            108, 109, 111, 113, 116, 118, 120, 121, 121, 120, 118, 117, 115, 114, 113, 112, 112, 112
        ]
        let latest = now.addingTimeInterval(-60)
        let dates = values.indices.map { index in
            latest.addingTimeInterval(Double(index - (values.count - 1)) * 300).timeIntervalSince1970
        }
        return TrioHomeWidgetSnapshot(
            glucose: 112,
            glucoseDate: latest,
            previousGlucose: 112,
            direction: "→",
            units: "mg/dL",
            low: 70,
            high: 180,
            target: 100,
            colorScheme: "dynamicColor",
            iob: 1.25,
            cob: 20,
            loopDate: latest,
            historyDates: dates,
            historyValues: values,
            forecastStyle: "cone",
            forecastMin: [112, 111, 110, 108, 107, 105, 104, 103, 102, 101, 100, 99, 99, 98, 98, 98, 98, 98],
            forecastMax: [112, 113, 114, 116, 118, 120, 122, 124, 126, 127, 128, 129, 130, 130, 131, 131, 131, 131],
            forecastLines: nil
        )
    }
}
