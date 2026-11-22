import Darwin
import Darwin.membership  // an explicit submodule: plain `import Darwin` doesn't bring in mbr_*
import Foundation

/// Whether the current user can make admin changes, asked before BrewxPort prompts for a password.
///
/// authd answers a non-administrator's correct password with the same -60005 as a wrong password, so without this
/// a standard user on a MacPorts run would be told "That password didn't work". Returns nil when the check itself
/// fails; callers then go ahead and let authd and sudo decide.
public typealias AdminCheck = @Sendable () -> Bool?

public enum AdminMembership {
    /// `mbr_check_membership` of this process's user in the local "admin" group, through their UUIDs
    /// (`mbr_uid_to_uuid`, `mbr_gid_to_uuid`), so nested and directory memberships count too.
    @Sendable public static func currentUserIsAdmin() -> Bool? {
        isAdmin(uid: getuid())
    }

    /// The same check for any uid (the helper asks it about the XPC requester). Nil when the check itself fails.
    @Sendable public static func isAdmin(uid: uid_t) -> Bool? {
        guard let group = getgrnam("admin") else { return nil }
        let gid = group.pointee.gr_gid
        var user = [UInt8](repeating: 0, count: 16)
        var admin = [UInt8](repeating: 0, count: 16)
        guard mbr_uid_to_uuid(uid, &user) == 0, mbr_gid_to_uuid(gid, &admin) == 0 else { return nil }
        var isMember: Int32 = 0
        guard mbr_check_membership(user, admin, &isMember) == 0 else { return nil }
        return isMember != 0
    }

    /// Setup is for administrators only: the helper's right accepts any admin's password, while the requester may
    /// be a standard user. A failed check refuses too. Nil means go.
    public static func setupRefusal(uid: uid_t, isAdmin: (uid_t) -> Bool? = isAdmin(uid:)) -> String? {
        isAdmin(uid) == true ? nil : "Only an administrator can set up package managers."
    }
}
