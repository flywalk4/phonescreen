import Darwin
import Foundation
import IOKit
import PhoneScreenKit

/// CPU (total + per core), RAM, GPU utilisation and network throughput, sampled once per second.
@MainActor
final class SystemStatsProvider {
    var onSample: ((SystemStats) -> Void)?
    private var timer: Timer?
    private var previousTicks: [(busy: UInt64, total: UInt64)] = []
    private var previousNet: (inBytes: UInt64, outBytes: UInt64, time: TimeInterval)?

    func start() {
        _ = sample() // prime the deltas
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stats = self.sample() else { return }
                self.onSample?(stats)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() -> SystemStats? {
        let cores = cpuPerCore()
        let memory = memoryUsage()
        let net = networkRates()
        return SystemStats(cpu: cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count),
                           cpuPerCore: cores, gpu: gpuUtilization(),
                           memoryUsed: memory.used, memoryTotal: memory.total,
                           netInBytesPerSec: net.inRate, netOutBytesPerSec: net.outRate)
    }

    private func cpuPerCore() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        var ticks: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append((user + system + nice, user + system + nice + idle))
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return ticks.map { _ in 0 } }
        return zip(ticks, previousTicks).map { now, before in
            let total = now.total &- before.total
            return total == 0 ? 0 : Double(now.busy &- before.busy) / Double(total)
        }
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        // Same definition as Activity Monitor's "Memory Used": app (internal - purgeable) + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, total)
    }

    private func networkRates() -> (inRate: Double, outRate: Double) {
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            inBytes += UInt64(data.pointee.ifi_ibytes)
            outBytes += UInt64(data.pointee.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNet = (inBytes, outBytes, now) }
        guard let prev = previousNet, now > prev.time,
              inBytes >= prev.inBytes, outBytes >= prev.outBytes // 32-bit counters wrap; skip that sample
        else { return (0, 0) }
        let dt = now - prev.time
        return (Double(inBytes - prev.inBytes) / dt, Double(outBytes - prev.outBytes) / dt)
    }

    /// "Device Utilization %" from the GPU driver's performance statistics (works on Apple Silicon and AMD).
    private func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = stats["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, value.doubleValue / 100)
        }
        return best
    }
}
