import Charts
import PhoneScreenKit
import SwiftUI

/// Mac load at a glance: gauges, per-core bars and the last minute as charts.
struct MonitorPage: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        VStack(spacing: 20) {
            if let stats = model.stats {
                HStack(spacing: 14) {
                    Gauge(title: "CPU", value: stats.cpu)
                    Gauge(title: "GPU", value: stats.gpu)
                    Gauge(title: "RAM", value: Double(stats.memoryUsed) / Double(max(stats.memoryTotal, 1)),
                          caption: ByteCountFormatter.string(fromByteCount: Int64(stats.memoryUsed), countStyle: .memory))
                }
                CoreBars(values: stats.cpuPerCore)
                LoadChart(history: model.statsHistory)
                NetworkChart(history: model.statsHistory)
                HStack {
                    Label(rate(stats.netInBytesPerSec), systemImage: "arrow.down")
                    Spacer()
                    Label(rate(stats.netOutBytesPerSec), systemImage: "arrow.up")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Жду данные с Mac…").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
        .frame(maxWidth: 520, maxHeight: .infinity)
    }

    private func rate(_ bytesPerSec: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .binary) + "/с"
    }
}

private struct Gauge: View {
    let title: String
    let value: Double?
    var caption: String?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: value ?? 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            .frame(width: 88, height: 88)
            Text(caption.map { "\(title) · \($0)" } ?? title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch value ?? 0 {
        case ..<0.6: .green
        case ..<0.85: .yellow
        default: .red
        }
    }
}

private struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                GeometryReader { geo in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.cyan.opacity(0.4 + v * 0.6))
                            .frame(height: max(2, geo.size.height * v))
                    }
                }
            }
        }
        .frame(height: 80)
        .animation(.easeOut(duration: 0.4), value: values)
    }
}

/// CPU and GPU over the last minute.
private struct LoadChart: View {
    let history: [SystemStats]

    var body: some View {
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
                Label("CPU", systemImage: "circle.fill").foregroundStyle(.cyan)
                Label("GPU", systemImage: "circle.fill").foregroundStyle(.purple)
            }
            .font(.caption2).labelStyle(.titleAndIcon)
        }
        .frame(height: 110)
        .animation(.linear(duration: 0.3), value: history.count)
    }
}

/// Download (filled) and upload (line) throughput over the last minute.
private struct NetworkChart: View {
    let history: [SystemStats]

    var body: some View {
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
        .frame(height: 60)
    }
}
