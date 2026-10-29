import Darwin

/// Lecture de valeurs du noyau par leur nom (sysctlbyname).
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func value<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let status = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        return status == 0 ? value : nil
    }
}

/// Convertit un tuple C de caracteres (char[N]) en chaine.
func stringFromCTuple<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Conversion des unites de temps Mach en nanosecondes (125/3 sur Apple Silicon).
let machTimebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(max(info.denom, 1)))
}()

func machToNanoseconds(_ ticks: UInt64) -> UInt64 {
    ticks / machTimebase.denom * machTimebase.numer
        + ticks % machTimebase.denom * machTimebase.numer / machTimebase.denom
}
