import Darwin

enum ArchiveBackupPermissions {
    static func trustedDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == 0 || info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0 else { throw ArchiveBackupError.invalid }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw ArchiveBackupError.invalid
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw ArchiveBackupError.invalid }
        var entry: acl_entry_t?, cursor = ACL_FIRST_ENTRY.rawValue, entries = 0
        while acl_get_entry(acl, cursor, &entry) == 0 {
            cursor = ACL_NEXT_ENTRY.rawValue; entries += 1
            guard entries <= 1024, let entry else { throw ArchiveBackupError.invalid }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw ArchiveBackupError.invalid }
            if tag == ACL_EXTENDED_DENY { continue }
            guard tag == ACL_EXTENDED_ALLOW else { throw ArchiveBackupError.invalid }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else { throw ArchiveBackupError.invalid }
            let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE_CHILD, ACL_DELETE, ACL_WRITE_SECURITY, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES]
            for permission in writes {
                guard acl_get_perm_np(permissions, permission) == 0 else { throw ArchiveBackupError.invalid }
            }
        }
        guard errno == EINVAL else { throw ArchiveBackupError.invalid }
    }
    static func makePrivate(_ fd: Int32, mode: mode_t) throws {
        guard let empty = acl_init(0) else { throw ArchiveBackupError.invalid }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0, fchmod(fd, mode) == 0 else { throw ArchiveBackupError.invalid }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == mode else { throw ArchiveBackupError.invalid }
    }
}
