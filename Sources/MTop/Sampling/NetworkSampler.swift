import Darwin

struct NetworkInterfaceSample: Identifiable {
    var id: String { name }
    var name: String
    var totalReceived: UInt64
    var totalSent: UInt64
    /// Octets par seconde.
    var receiveRate: Double
    var sendRate: Double
}

/// Compteurs 64 bits par interface, lus via NET_RT_IFLIST2 (getifaddrs ne
/// donne que des compteurs 32 bits qui bouclent a 4 Go).
final class NetworkSampler {
    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]

    func sample(elapsed: Double) -> [NetworkInterfaceSample] {
        let counters = Self.readCounters()
        defer { previous = counters.mapValues { ($0.rx, $0.tx) } }

        return counters.map { name, value in
            var rxRate = 0.0, txRate = 0.0
            if let before = previous[name], elapsed > 0 {
                rxRate = Double(value.rx &- before.rx) / elapsed
                txRate = Double(value.tx &- before.tx) / elapsed
                if value.rx < before.rx { rxRate = 0 }
                if value.tx < before.tx { txRate = 0 }
            }
            return NetworkInterfaceSample(name: name, totalReceived: value.rx, totalSent: value.tx,
                                          receiveRate: rxRate, sendRate: txRate)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func readCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if info.ifm_data.ifi_type != UInt8(IFT_LOOP),
                       if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        result[String(cString: nameBuffer)] =
                            (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
        }
        return result
    }
}
