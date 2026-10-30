import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// #949 第一段(REC-30):全域錄音租約 `~/.config/myparrot/recording.lease`。
/// 任何時候只有一個錄音 writer(GUI 或 CLI):誰先拿到租約誰錄,另一邊只能看與停。
/// 「活著」＝檔在且鎖不到(EWOULDBLOCK);「死了」＝檔在但鎖得到(持有者已結束,kernel 已釋放 flock)。
/// 不用 pid 判活(pid 會被重用)。
public struct RecordingLease: Codable, Sendable, Equatable {
    public var sessionId: String          // UUID
    public var owner: String              // "gui" | "cli"
    public var pid: Int32
    public var bundleID: String           // Bundle.main.bundleIdentifier ?? "myparrot-cli"
    public var appVersion: String
    public var protocolVersion: Int       // 1
    public var requestId: String?         // 第二段用,現在 nil
    public var startedAt: String          // ISO8601
    public var name: String
    public var audioPath: String          // inprogress 的 audio.caf 絕對路徑
    public var bootUUID: String           // sysctl kern.bootsessionuuid
    public var heartbeatAt: String

    public init(sessionId: String, owner: String, pid: Int32, bundleID: String, appVersion: String,
                protocolVersion: Int = RecordingLease.currentProtocolVersion, requestId: String? = nil,
                startedAt: String, name: String, audioPath: String, bootUUID: String, heartbeatAt: String) {
        self.sessionId = sessionId; self.owner = owner; self.pid = pid; self.bundleID = bundleID
        self.appVersion = appVersion; self.protocolVersion = protocolVersion; self.requestId = requestId
        self.startedAt = startedAt; self.name = name; self.audioPath = audioPath
        self.bootUUID = bootUUID; self.heartbeatAt = heartbeatAt
    }

    public static let currentProtocolVersion = 1

    /// 本進程的租約:pid／bundleID／appVersion／bootUUID 自動填,startedAt＝heartbeatAt＝現在。
    public static func make(sessionId: String, owner: String, name: String, audioPath: String,
                            now: Date = Date()) -> RecordingLease {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let stamp = ISO8601.string(now)
        return RecordingLease(sessionId: sessionId, owner: owner, pid: getpid(),
                              bundleID: Bundle.main.bundleIdentifier ?? "myparrot-cli",
                              appVersion: version, startedAt: stamp, name: name, audioPath: audioPath,
                              bootUUID: bootSessionUUID(), heartbeatAt: stamp)
    }

    /// 租約檔在、鎖也確定被持有,但內容還沒寫好/讀到一半(建檔與寫內容之間的空窗、心跳覆寫中)時的占位。
    /// sessionId 空字串 ⇒ 任何「比對 sessionId」的判斷都不會誤中。
    public static let placeholder = RecordingLease(sessionId: "", owner: "", pid: 0, bundleID: "", appVersion: "",
                                                   protocolVersion: 0, startedAt: "", name: "", audioPath: "",
                                                   bootUUID: "", heartbeatAt: "")

    /// REC-38:心跳超過門檻沒更新 ⇒ 非 owner 端標「無回應」(只標示,**不**收割:進程可能卡住但活著)。
    /// heartbeatAt 解不開(占位、舊格式)⇒ 視為不新鮮。純函式。
    public static func isHeartbeatStale(_ lease: RecordingLease, now: Date, threshold: TimeInterval = 10) -> Bool {
        guard let beat = ISO8601.date(lease.heartbeatAt) else { return true }
        return now.timeIntervalSince(beat) > threshold
    }

    /// `sysctl kern.bootsessionuuid`;讀不到 ⇒ 空字串。
    public static func bootSessionUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "" }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum LeaseError: Error, Equatable {
    /// 已有人持有(existing＝讀到的租約;內容讀不到時是 `RecordingLease.placeholder`)。
    case held(RecordingLease?)
    /// 目錄所在的卷不支援 advisory lock(iCloud/網路卷)⇒ fail closed,不錄。
    case unsupportedVolume
    case ioError(Int32)
}

public enum LeaseInspection: Equatable {
    case none
    case alive(RecordingLease)
    case dead(RecordingLease)
    case unreadable(Int32)
}

/// 持有租約的那一方:持 fd＋flock 直到 `release()`。
/// fd 只在 `lock` 內讀寫;`@unchecked Sendable` 的根據＝所有可變狀態都在鎖內。
public final class RecordingLeaseHolder: @unchecked Sendable {
    public static let fileName = "recording.lease"

    /// C2(#2646):`<錄音夾>/.myparrot/`(`MyParrotPaths.protocolDir`;之前是 `~/.config/myparrot`)。
    public static func directory() -> URL { MyParrotPaths.protocolDir }

    public static func leaseURL(in dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    private let lock = NSLock()
    private var fd: Int32
    private var current: RecordingLease
    private let path: String
    private var released = false

    private init(fd: Int32, lease: RecordingLease, path: String) {
        self.fd = fd; self.current = lease; self.path = path
    }

    deinit {
        // 保險:忘了 release 也要把鎖還掉(close 會釋放 flock)。不 unlink——留下的檔會被判成「死了」。
        if !released, fd >= 0 { close(fd) }
    }

    /// 目前持有的租約內容(心跳會更新 heartbeatAt)。
    public var lease: RecordingLease { lock.withLock { current } }

    /// `O_CREAT|O_EXCL|O_NOFOLLOW|O_WRONLY` 0600 ＋ 排他鎖;成功才寫內容。
    /// 排他鎖用 `O_EXLOCK|O_NONBLOCK` 在 open 當下原子取得(與 `flock(LOCK_EX)` 同一種鎖),再補一次
    /// `flock(LOCK_EX|LOCK_NB)` 確認卷真的支援(ENOTSUP ⇒ `.unsupportedVolume`)。
    /// 已有檔:鎖不到 ⇒ `.held(existing)`;鎖得到(前一個持有者已死)⇒ 持鎖確認仍是同一個 inode 才 unlink,重試建檔。
    public static func acquire(_ lease: RecordingLease) -> Result<RecordingLeaseHolder, LeaseError> {
        acquire(lease, in: directory())
    }

    public static func acquire(_ lease: RecordingLease, in dir: URL) -> Result<RecordingLeaseHolder, LeaseError> {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(.ioError((error as NSError).code == 0 ? EIO : Int32(truncatingIfNeeded: (error as NSError).code)))
        }
        if let v = try? dir.resourceValues(forKeys: [.volumeSupportsAdvisoryFileLockingKey]),
           v.volumeSupportsAdvisoryFileLocking == false {
            return .failure(.unsupportedVolume)
        }
        let path = leaseURL(in: dir).path
        for _ in 0..<4 {
            let fd = open(path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
            if fd >= 0 {
                if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                    let e = errno
                    unlink(path); close(fd)
                    return .failure(e == ENOTSUP || e == EOPNOTSUPP ? .unsupportedVolume : .ioError(e))
                }
                let holder = RecordingLeaseHolder(fd: fd, lease: lease, path: path)
                if let e = holder.writeCurrent() {
                    unlink(path); close(fd); holder.released = true
                    return .failure(.ioError(e))
                }
                return .success(holder)
            }
            let e = errno
            if e == ENOTSUP || e == EOPNOTSUPP { return .failure(.unsupportedVolume) }
            guard e == EEXIST else { return .failure(.ioError(e)) }
            // 已有檔:活著 ⇒ held;死了 ⇒ 持鎖清掉再試。
            switch removeIfDead(path: path) {
            case .removed: continue
            case .alive(let existing): return .failure(.held(existing))
            case .gone: continue
            case .error(let err):
                if err == ENOTSUP || err == EOPNOTSUPP { return .failure(.unsupportedVolume) }
                return .failure(.ioError(err))
            }
        }
        // 四次都撞到(極端競爭):當作有人持有。
        if case .alive(let l) = inspect(in: dir) { return .failure(.held(l)) }
        return .failure(.held(nil))
    }

    private enum DeadRemoval { case removed, alive(RecordingLease), gone, error(Int32) }

    /// 已存在的租約檔:用 `O_EXLOCK|O_NONBLOCK` 開(拿得到鎖＝持有者已死);持鎖期間確認路徑仍指向同一個 inode
    /// 才 unlink——避免把「別人剛清掉舊檔、剛建好的新租約」刪掉。
    private static func removeIfDead(path: String) -> DeadRemoval {
        var fd: Int32 = -1
        // 觀察端 `inspect()` 會短暫鎖住死檔(鎖一下就放);撞到時稍等再試,免得把死檔誤判成活著。
        for attempt in 0..<3 {
            fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
            if fd >= 0 { break }
            let e = errno
            if e == ENOENT { return .gone }
            guard e == EWOULDBLOCK || e == EAGAIN else { return .error(e) }
            if attempt == 2 { return .alive(readLease(path: path) ?? .placeholder) }
            usleep(30_000)
        }
        defer { close(fd) }
        var st = stat(), lst = stat()
        guard fstat(fd, &st) == 0 else { return .error(errno) }
        guard lstat(path, &lst) == 0 else { return errno == ENOENT ? .gone : .error(errno) }
        guard st.st_ino == lst.st_ino, st.st_dev == lst.st_dev else { return .gone }   // 已被別人換掉,重試
        if unlink(path) != 0 { return errno == ENOENT ? .gone : .error(errno) }
        return .removed
    }

    /// 每 2 秒由 owner 的主迴圈呼叫:重寫 heartbeatAt。fd 鎖在原 inode,不能 tmp＋rename;改成 pwrite 整檔＋ftruncate。
    /// 呼叫端節流(GUI 掛在 owner 計時器、CLI 掛在主迴圈)——主執行緒卡住 ⇒ 心跳停 ⇒ 對方標「無回應」,這是刻意的。
    public func heartbeat(now: Date = Date()) {
        lock.withLock {
            guard !released else { return }
            current.heartbeatAt = ISO8601.string(now)
        }
        _ = writeCurrent()
    }

    /// 改名(標題變更時同步給非 owner 端顯示)。
    public func update(name: String) {
        lock.withLock { current.name = name }
        _ = writeCurrent()
    }

    /// 先 unlink(仍持鎖,別人看到的是「活著」或「沒有檔」)再 close(釋鎖)。
    /// 規格寫 close → unlink;順序對調是因為 close 之後、unlink 之前若有人清掉死檔並建了新租約,
    /// 我們的 unlink 會刪到別人的新檔(報告 §5 偏差)。
    public func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            var st = stat(), lst = stat()
            if fstat(fd, &st) == 0, lstat(path, &lst) == 0, st.st_ino == lst.st_ino, st.st_dev == lst.st_dev {
                unlink(path)
            }
            close(fd)
            fd = -1
        }
    }

    public var isReleased: Bool { lock.withLock { released } }

    /// 回傳 errno(nil＝成功)。
    @discardableResult
    private func writeCurrent() -> Int32? {
        lock.withLock {
            guard !released, fd >= 0 else { return EBADF }
            guard let data = try? JSONEncoder().encode(current) else { return EINVAL }
            let n = data.withUnsafeBytes { raw in pwrite(fd, raw.baseAddress, raw.count, 0) }
            if n != data.count { return n < 0 ? errno : EIO }
            if ftruncate(fd, off_t(data.count)) != 0 { return errno }
            return nil
        }
    }

    // MARK: - 觀察端

    /// 讀檔＋試 `flock(LOCK_EX|LOCK_NB)` 再立刻解:鎖不到＝活著。
    public static func inspect() -> LeaseInspection { inspect(in: directory()) }

    public static func inspect(in dir: URL) -> LeaseInspection {
        let path = leaseURL(in: dir).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            return e == ENOENT ? .none : .unreadable(e)
        }
        defer { close(fd) }
        let content = readLease(fd: fd)
        let r = flock(fd, LOCK_EX | LOCK_NB)
        let e = errno
        if r == 0 { flock(fd, LOCK_UN) }
        // 心跳覆寫中讀到半截 ⇒ 鎖仍被持有時再讀一次。
        var lease = content
        if lease == nil, r != 0, e == EWOULDBLOCK {
            usleep(50_000)
            lease = readLease(path: path)
        }
        return classify(flockResult: r, errno: e, fileExists: true, lease: lease)
    }

    /// 純函式(SelfTest `leaseClassify`):`(0, _, true)→dead`、`(-1, EWOULDBLOCK, true)→alive`、
    /// `(-1, 其他 errno, true)→unreadable`、`(_, _, false)→none`。lease 讀不到 ⇒ 用 `placeholder`。
    public static func classify(flockResult: Int32, errno err: Int32, fileExists: Bool,
                                lease: RecordingLease? = nil) -> LeaseInspection {
        guard fileExists else { return .none }
        if flockResult == 0 { return .dead(lease ?? .placeholder) }
        if err == EWOULDBLOCK || err == EAGAIN { return .alive(lease ?? .placeholder) }
        return .unreadable(err)
    }

    static func readLease(path: String) -> RecordingLease? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(RecordingLease.self, from: data)
    }

    private static func readLease(fd: Int32) -> RecordingLease? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var offset: off_t = 0
        while true {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, offset) }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            offset += off_t(n)
            if data.count > 64 * 1024 { break }
        }
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(RecordingLease.self, from: data)
    }

    /// 收割端復原完死掉那場後清租約:只在**鎖得到**(持有者已死)且仍是同一個 inode 時才刪。活租約絕不動。
    @discardableResult
    public static func clearIfDead(in dir: URL = directory()) -> Bool {
        if case .removed = removeIfDead(path: leaseURL(in: dir).path) { return true }
        return false
    }

    /// DEBUG `lease break`／測試用:不管死活直接刪租約檔(只給示範夾/暫存夾用)。
    public static func breakLease(in dir: URL = directory()) -> Bool {
        unlink(leaseURL(in: dir).path) == 0
    }
}
