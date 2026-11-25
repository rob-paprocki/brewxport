import Darwin

/// Looks a uid up in the user database with `getpwuid_r`, which is safe to call from several threads at once
/// (`getpwuid` shares one static record, so it isn't).
public enum UserDatabase {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// Empty if the record has none.
        public let home: String
    }

    /// Never grow the buffer past this, so a broken directory service can't make the lookup loop forever.
    static let maxBufferBytes = 1 << 20

    /// The account name and home folder for `uid`, or nil if there's no such user or the lookup fails.
    public static func entry(for uid: uid_t) -> Entry? {
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var size = suggested > 0 ? suggested : 4096
        while true {
            // The record's strings point into the buffer, so they're copied out while it's still allocated.
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
            defer { buffer.deallocate() }
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            let code = getpwuid_r(uid, &record, buffer, size, &result)
            if code == ERANGE, size < maxBufferBytes {
                size = min(size * 2, maxBufferBytes)
                continue
            }
            guard code == 0, result != nil, let name = record.pw_name else { return nil }
            let text = String(cString: name)
            guard !text.isEmpty else { return nil }
            let home = record.pw_dir.map { String(cString: $0) } ?? ""
            return Entry(name: text, home: home)
        }
    }
}
