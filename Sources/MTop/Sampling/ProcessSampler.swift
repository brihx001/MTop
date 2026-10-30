import Darwin
import Foundation

struct ProcessSample: Identifiable {
    var id: pid_t { pid }
    var pid: pid_t
    var parentPID: pid_t
    var name: String
    var path: String?
    var user: String
    var uid: uid_t
    /// Pourcentage d'un coeur, comme top (peut depasser 100).
    var cpu: Double
    /// Empreinte memoire (ce qu'affiche le Moniteur d'activite), ou resident a defaut.
    var memory: UInt64
    var threads: Int32
    var state: String
    var nice: Int32
    var startDate: Date
    var readRate: Double
    var writeRate: Double
    /// Processus d'un autre utilisateur : le noyau refuse ses compteurs sans privileges.
    var restricted: Bool

    /// Profondeur et descendance dans la vue en arborescence.
    var treeDepth = 0
    var hasChildren = false
}

final class ProcessSampler {
    private struct Previous { var cpuNanoseconds: UInt64; var read: UInt64; var write: UInt64 }
    private struct Identity: Hashable { var pid: pid_t; var start: Int }
    private struct Static { var name: String; var path: String?; var lastSeen: Int }

    private var previous: [pid_t: Previous] = [:]
    private var statics: [Identity: Static] = [:]
    private var userNames: [uid_t: String] = [:]
    /// Tampon de kinfo_proc reutilise d'un tick a l'autre (~650 octets par processus).
    private var buffer: [kinfo_proc] = []
    private var tick = 0
    private let euid = geteuid()

    func sample(elapsed: Double) -> [ProcessSample] {
        tick &+= 1
        let count = refreshProcessList()
        var current: [pid_t: Previous] = [:]
        current.reserveCapacity(previous.count)
        var result: [ProcessSample] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let kinfo = buffer[index]
            let pid = kinfo.kp_proc.p_pid
            let startTime = kinfo.kp_proc.p_un.__p_starttime
            let identity = Identity(pid: pid, start: startTime.tv_sec)
            let info: Static
            if var cached = statics[identity] {
                cached.lastSeen = tick
                statics[identity] = cached
                info = cached
            } else {
                info = makeStatic(pid: pid, kinfo: kinfo)
                statics[identity] = info
            }

            let uid = kinfo.kp_eproc.e_ucred.cr_uid
            var sample = ProcessSample(
                pid: pid, parentPID: kinfo.kp_eproc.e_ppid, name: info.name, path: info.path,
                user: userName(uid), uid: uid, cpu: 0, memory: 0, threads: 0,
                state: Self.stateName(kinfo.kp_proc.p_stat), nice: Int32(kinfo.kp_proc.p_nice),
                startDate: Date(timeIntervalSince1970: TimeInterval(startTime.tv_sec)),
                readRate: 0, writeRate: 0, restricted: true)

            // Sans privileges, le noyau refuse les compteurs des autres utilisateurs :
            // inutile de faire l'appel pour les ~350 processus root.
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            if euid == 0 || uid == euid,
               proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
                sample.restricted = false
                sample.threads = task.pti_threadnum
                sample.memory = task.pti_resident_size
                let cpuTime = machToNanoseconds(task.pti_total_user + task.pti_total_system)

                var usage = rusage_info_v4()
                let usageOK = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                    }
                } == 0
                if usageOK { sample.memory = usage.ri_phys_footprint }

                let now = Previous(cpuNanoseconds: cpuTime,
                                   read: usageOK ? usage.ri_diskio_bytesread : 0,
                                   write: usageOK ? usage.ri_diskio_byteswritten : 0)
                if let before = previous[pid], elapsed > 0 {
                    if now.cpuNanoseconds >= before.cpuNanoseconds {
                        // Arrondi au dixieme affiche : les ecarts invisibles ne
                        // doivent pas reordonner la table a chaque mesure.
                        let raw = Double(now.cpuNanoseconds - before.cpuNanoseconds) / (elapsed * 1e9) * 100
                        sample.cpu = (raw * 10).rounded() / 10
                    }
                    if now.read >= before.read { sample.readRate = Double(now.read - before.read) / elapsed }
                    if now.write >= before.write { sample.writeRate = Double(now.write - before.write) / elapsed }
                }
                current[pid] = now
            }
            result.append(sample)
        }

        previous = current
        // Purge des processus disparus, seulement quand il y en a.
        if statics.count > count {
            statics = statics.filter { $0.value.lastSeen == tick }
        }
        return result
    }

    private func makeStatic(pid: pid_t, kinfo: kinfo_proc) -> Static {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil

        // p_comm est tronque a 16 caracteres : le chemin donne le nom complet.
        var name = stringFromCTuple(kinfo.kp_proc.p_comm)
        if let path {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { name = last }
        }
        if pid == 0 { name = "kernel_task" }
        return Static(name: name, path: path, lastSeen: tick)
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        var name = String(uid)
        if let entry = getpwuid(uid), let raw = entry.pointee.pw_name {
            name = String(cString: raw)
        }
        userNames[uid] = name
        return name
    }

    /// Date de lancement (secondes) d'un processus, ou nil s'il n'existe plus.
    static func startTime(of pid: pid_t) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        return info.kp_proc.p_un.__p_starttime.tv_sec
    }

    /// Remplit `buffer` avec la table des processus et renvoie leur nombre.
    private func refreshProcessList() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // Des processus peuvent naitre entre la mesure de taille et la lecture :
        // on reessaie avec un tampon plus grand si le noyau repond ENOMEM.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return 0 }
            let needed = size / stride + 64
            if buffer.count < needed {
                buffer = [kinfo_proc](repeating: kinfo_proc(), count: needed)
            }
            size = buffer.count * stride
            let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if status == 0 { return size / stride }
            guard errno == ENOMEM else { return 0 }
        }
        return 0
    }

    private static func stateName(_ stat: CChar) -> String {
        switch Int32(stat) {
        case SIDL: return "Starting"
        case SRUN: return "Running"
        case SSLEEP: return "Sleeping"
        case SSTOP: return "Stopped"
        case SZOMB: return "Zombie"
        default: return "?"
        }
    }
}
