import Foundation
import Darwin

/// Private, independently named local appearance assets. Never conversation files or S3.
public enum TelegramWallpaperFiles {
    /// Returns ownership of a newly installed asset, even if cancellation races
    /// the return. The editor discards it if its presentation is no longer current.
    @concurrent public static func installInBackground(_ prepared: Data, pattern: Bool = false, directory: URL? = nil) async throws -> String {
        try Task.checkCancellation()
        return try pattern ? installPattern(prepared, directory: directory) : install(prepared, directory: directory)
    }
    /// Cleanup must also execute when its calling presentation task was cancelled.
    @concurrent public static func discardInstalled(_ name: String, directory: URL? = nil) async throws {
        guard TelegramLocalWallpaper.image(name).isValid || TelegramWallpaperPattern.validName(name) else { throw TelegramAppearanceError.invalid }
        let root = try rootFD(directory, create: false); defer { close(root) }
        guard unlinkat(root, name, 0) == 0 || errno == ENOENT else { throw TelegramAppearanceError.image }
    }
    public static func readSelection(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw TelegramAppearanceError.image }
        let fd = open(url.path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramAppearanceError.image }; defer { close(fd) }
        return try read(fd, limit:32 * 1024 * 1024)
    }
    public static func install(_ prepared: Data, directory: URL? = nil) throws -> String {
        try installAsset(prepared,extension:"jpg",directory:directory)
    }
    public static func installPattern(_ prepared:Data,directory:URL? = nil) throws -> String {
        guard TelegramWallpaperPattern.normalizedImage(prepared) != nil else { throw TelegramAppearanceError.image }
        return try installAsset(prepared,extension:"png",directory:directory)
    }
    private static func installAsset(_ prepared:Data,extension suffix:String,directory:URL?) throws -> String {
        guard !prepared.isEmpty, prepared.count <= 8 * 1024 * 1024 else { throw TelegramAppearanceError.image }
        let root = try rootFD(directory,create:true); defer { close(root) }
        let name = UUID().uuidString.lowercased() + "." + suffix
        let fd = openat(root,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw TelegramAppearanceError.image }
        do {
            try prepared.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let written = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw TelegramAppearanceError.image }; offset += written
                }
            }
            try Task.checkCancellation()
            guard fsync(fd) == 0, fsync(root) == 0 else { throw TelegramAppearanceError.image }
            try Task.checkCancellation()
            close(fd); return name
        } catch { close(fd); unlinkat(root,name,0); throw error }
    }
    public static func load(_ name: String, directory: URL? = nil) throws -> Data {
        guard TelegramLocalWallpaper.image(name).isValid else { throw TelegramAppearanceError.invalid }
        return try loadAsset(name,directory:directory)
    }
    public static func loadPattern(_ name:String,directory:URL? = nil) throws -> Data {
        guard TelegramWallpaperPattern.validName(name) else { throw TelegramAppearanceError.invalid }
        let bytes = try loadAsset(name,directory:directory)
        guard TelegramWallpaperPattern.normalizedImage(bytes) != nil else { throw TelegramAppearanceError.image }; return bytes
    }
    private static func loadAsset(_ name:String,directory:URL?) throws -> Data {
        let root = try rootFD(directory,create:false); defer { close(root) }
        let fd = openat(root,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramAppearanceError.image }; defer { close(fd) }
        return try read(fd,limit:8 * 1024 * 1024)
    }
    private static func rootFD(_ directory: URL?, create: Bool) throws -> Int32 {
        let root: URL
        if let directory { root = directory }
        else {
            root = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:create)
                .appendingPathComponent("Makosh/Wallpapers",isDirectory:true)
        }
        guard root.isFileURL else { throw TelegramAppearanceError.invalid }
        if create { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        let fd = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramAppearanceError.image }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { close(fd); throw TelegramAppearanceError.image }
        return fd
    }
    private static func read(_ fd: Int32, limit: Int) throws -> Data {
        var before = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= limit else { throw TelegramAppearanceError.image }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data = try handle.read(upToCount:limit+1) ?? Data()
        var after = stat()
        guard fstat(fd,&after) == 0, data.count == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw TelegramAppearanceError.image }
        return data
    }
}
