import Charts
import PhoneScreenKit
import SwiftUI

/// Mac load at a glance: gauges, per-core bars and the last minute as charts.
struct MonitorPage: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size

    var body: some View {
        if size == .full { full } else { compact }
    }

    /// Card version: gauges (and, with room, the load chart).
    private var compact: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Mac", symbol: "gauge.with.dots.needle.33percent")
            if let stats = model.stats {
                GeometryReader { geo in
                    let wide = geo.size.width > geo.size.height
                    let side = min(size == .small ? 58 : 70, (wide ? geo.size.width / 3 : geo.size.height / 3) - 18)
                    let layout = wide || size == .medium ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 6))
                    VStack(spacing: 10) {
                        layout {
                            Gauge(title: "CPU", value: stats.cpu, diameter: side)
                            Gauge(title: "GPU", value: stats.gpu, diameter: side)
                            Gauge(title: "RAM", value: Double(stats.memoryUsed) / Double(max(stats.memoryTotal, 1)), diameter: side)
                        }
                        if size == .medium { LoadChart(history: model.statsHistory) }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                ThemedSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Whole page: upright a single column; lying sideways gauges on the left, charts on the right.
    private var full: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.3
            Group {
                if let stats = model.stats {
                    if wide {
                        HStack(spacing: 24) {
                            VStack(spacing: 18) {
                                gauges(stats, diameter: min(88, (geo.size.height - 90) / 1.6))
                                network(stats)
                            }
                            .frame(width: geo.size.width * 0.4)
                            VStack(spacing: 14) {
                                CoreBars(values: stats.cpuPerCore)
                                LoadChart(history: model.statsHistory)
                                NetworkChart(history: model.statsHistory)
                            }
                        }
                    } else {
                        VStack(spacing: 20) {
                            gauges(stats, diameter: 88)
                            CoreBars(values: stats.cpuPerCore)
                            LoadChart(history: model.statsHistory)
                            NetworkChart(history: model.statsHistory)
                            network(stats)
                        }
                        .frame(maxWidth: 520)
                    }
                } else {
                    VStack(spacing: 12) {
                        ThemedSpinner()
                        Text("Waiting for data from the Mac…").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func gauges(_ stats: SystemStats, diameter: CGFloat) -> some View {
        HStack(spacing: 14) {
            Gauge(title: "CPU", value: stats.cpu, diameter: diameter)
            Gauge(title: "GPU", value: stats.gpu, diameter: diameter)
            Gauge(title: "RAM", value: Double(stats.memoryUsed) / Double(max(stats.memoryTotal, 1)),
                  caption: ByteCountFormatter.string(fromByteCount: Int64(stats.memoryUsed), countStyle: .memory),
                  diameter: diameter)
        }
    }

    private func network(_ stats: SystemStats) -> some View {
        HStack {
            Label { Text(rate(stats.netInBytesPerSec)) } icon: { Glyph("arrow.down") }
            Spacer()
            Label { Text(rate(stats.netOutBytesPerSec)) } icon: { Glyph("arrow.up") }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .animation(.snappy, value: stats.netInBytesPerSec)
    }

    private func rate(_ bytesPerSec: Double) -> String {
        L("%@/s", ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .binary))
    }
}

private struct Gauge: View {
    let title: String
    let value: Double?
    var caption: String?
    var diameter: CGFloat = 88
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ThemedRing(value: value, color: color, diameter: diameter)
            Text(caption.map { "\(title) · \($0)" } ?? title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch value ?? 0 {
        case ..<0.6: theme.named("green", .green)
        case ..<0.85: theme.named("yellow", .yellow)
        default: theme.named("red", .red)
        }
    }
}

private struct CoreBars: View {
    let values: [Double]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                GeometryReader { geo in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: theme.style == .ascii ? 0 : 2)
                            .fill((theme.style == .ascii ? theme.text : theme.named("cyan", .cyan)).opacity(0.4 + v * 0.6))
                            .frame(height: max(2, geo.size.height * v))
                    }
                }
            }
        }
        .frame(minHeight: 80, maxHeight: 160)
        .animation(.easeOut(duration: 0.4), value: values)
    }
}

/// CPU and GPU over the last minute.
private struct LoadChart: View {
    let history: [SystemStats]
    @Environment(\.theme) private var theme

    var body: some View {
        if theme.style == .ascii {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU, last minute").font(.caption2).foregroundStyle(.secondary)
                AsciiChart(values: history.map { $0.cpu * 100 }, color: theme.text)
            }
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { i, s in
                LineMark(x: .value("t", i), y: .value("%", s.cpu * 100), series: .value("", "CPU"))
                    .foregroundStyle(.cyan)
                if let gpu = s.gpu {
                    LineMark(x: .value("t", i), y: .value("%", gpu * 100), series: .value("", "GPU"))
                        .foregroundStyle(.purple)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...59)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel("\(value.as(Int.self) ?? 0)%")
            }
        }
        .chartLegend(.hidden)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Label { Text("CPU") } icon: { Glyph("circle.fill") }.foregroundStyle(.cyan)
                Label { Text("GPU") } icon: { Glyph("circle.fill") }.foregroundStyle(.purple)
            }
            .font(.caption2).labelStyle(.titleAndIcon)
        }
        .frame(minHeight: 110, maxHeight: .infinity)
        .animation(.linear(duration: 0.3), value: history.count)
    }
}

/// Download (filled) and upload (line) throughput over the last minute.
private struct NetworkChart: View {
    let history: [SystemStats]
    @Environment(\.theme) private var theme

    var body: some View {
        if theme.style == .ascii {
            VStack(alignment: .leading, spacing: 2) {
                Text("Network in").font(.caption2).foregroundStyle(.secondary)
                AsciiChart(values: history.map(\.netInBytesPerSec), color: theme.text)
            }
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { i, s in
                AreaMark(x: .value("t", i), y: .value("B/s", s.netInBytesPerSec))
                    .foregroundStyle(LinearGradient(colors: [.green.opacity(0.6), .green.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", i), y: .value("B/s", s.netOutBytesPerSec), series: .value("", "out"))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...59)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(minHeight: 60, maxHeight: 140)
    }
}
