#!/usr/bin/swift
import Darwin

private let fixedDistFD: Int32 = 9

private var testFailUnlinkAfter: Int? = {
    guard let raw = getenv("LIDMUTE_TEST_FAIL_UNLINK_AFTER") else { return nil }
    return Int(String(cString: raw))
}()

private struct FileSystemError: Error, CustomStringConvertible {
    let description: String
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private func fail(_ message: String) throws -> Never {
    throw FileSystemError(description: message)
}

private func errnoMessage(_ operation: String) -> FileSystemError {
    FileSystemError(description: "\(operation): \(String(cString: strerror(errno)))")
}

private func isDirectory(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
}

private func isRegular(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
}

private func identity(_ status: stat) -> FileIdentity {
    FileIdentity(device: status.st_dev, inode: status.st_ino)
}

private func statusForFD(_ fd: Int32) throws -> stat {
    var status = stat()
    if fstat(fd, &status) != 0 {
        throw errnoMessage("fstat fd")
    }
    return status
}

private func validateLeaf(_ name: String) throws {
    if name.isEmpty || name == "." || name == ".." || name.utf8.count > 200 || name.contains("/") {
        try fail("invalid leaf name")
    }
}

private func validateAppName(_ name: String) throws {
    try validateLeaf(name)
    if !name.hasSuffix(".app") || name == ".app" {
        try fail("App name must be a nonempty .app leaf")
    }
}

private func validateStageName(_ name: String) throws {
    try validateLeaf(name)
    if !name.hasPrefix(".lidmute-stage.") || name == ".lidmute-stage." {
        try fail("invalid stage name")
    }
}

private func validateBackupName(_ name: String) throws {
    try validateLeaf(name)
    if !name.hasPrefix(".lidmute-backup.") || name == ".lidmute-backup." {
        try fail("invalid backup name")
    }
}

private func parseFD(_ value: String) throws -> Int32 {
    guard let fd = Int32(value), fd >= 3 else {
        try fail("invalid directory file descriptor")
    }
    var status = stat()
    if fstat(fd, &status) != 0 || !isDirectory(status) {
        throw errnoMessage("fstat dist fd")
    }
    return fd
}

private func openDirectory(parentFD: Int32, name: String) throws -> Int32 {
    let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
        throw errnoMessage("openat \(name)")
    }
    return fd
}

private func statusNoFollow(parentFD: Int32, name: String) throws -> stat? {
    var status = stat()
    if fstatat(parentFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
        return status
    }
    if errno == ENOENT {
        return nil
    }
    throw errnoMessage("fstatat \(name)")
}

private func requireRegular(parentFD: Int32, name: String) throws {
    guard let status = try statusNoFollow(parentFD: parentFD, name: name), isRegular(status) else {
        try fail("expected regular file \(name)")
    }
}

private func appIdentity(parentFD: Int32, name: String) throws -> FileIdentity {
    try validateAppName(name)
    guard let appStatus = try statusNoFollow(parentFD: parentFD, name: name), isDirectory(appStatus) else {
        try fail("expected App directory \(name)")
    }
    let appFD = try openDirectory(parentFD: parentFD, name: name)
    defer { close(appFD) }
    let contentsFD = try openDirectory(parentFD: appFD, name: "Contents")
    defer { close(contentsFD) }
    try requireRegular(parentFD: contentsFD, name: "Info.plist")
    let macOSFD = try openDirectory(parentFD: contentsFD, name: "MacOS")
    defer { close(macOSFD) }
    try requireRegular(parentFD: macOSFD, name: "LidMute")
    try requireRegular(parentFD: macOSFD, name: "LidMuteNativeHost")
    let resourcesFD = try openDirectory(parentFD: contentsFD, name: "Resources")
    defer { close(resourcesFD) }
    try requireRegular(parentFD: resourcesFD, name: "BuildChannel.txt")
    var openedStatus = stat()
    if fstat(appFD, &openedStatus) != 0 {
        throw errnoMessage("fstat App (name)")
    }
    return identity(openedStatus)
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
            String(cString: $0)
        }
    }
}

private func unlinkEntry(parentFD: Int32, name: String, flags: Int32) throws {
    if let remaining = testFailUnlinkAfter {
        if remaining == 0 {
            testFailUnlinkAfter = nil
            try fail("injected unlinkat failure")
        }
        testFailUnlinkAfter = remaining - 1
    }
    if unlinkat(parentFD, name, flags) != 0 {
        throw errnoMessage("unlinkat (name)")
    }
}

private func removeEntry(parentFD: Int32, name: String, requireTopDirectory: Bool) throws {
    guard let status = try statusNoFollow(parentFD: parentFD, name: name) else {
        return
    }
    if requireTopDirectory && !isDirectory(status) {
        try fail("refusing non-directory top-level removal")
    }
    if isDirectory(status) {
        let childFD = try openDirectory(parentFD: parentFD, name: name)
        guard let directory = fdopendir(childFD) else {
            close(childFD)
            throw errnoMessage("fdopendir \(name)")
        }
        while let entry = readdir(directory) {
            let childName = directoryEntryName(entry)
            if childName != "." && childName != ".." {
                try removeEntry(parentFD: childFD, name: childName, requireTopDirectory: false)
            }
        }
        if closedir(directory) != 0 {
            throw errnoMessage("closedir \(name)")
        }
        try unlinkEntry(parentFD: parentFD, name: name, flags: AT_REMOVEDIR)
    } else {
        try unlinkEntry(parentFD: parentFD, name: name, flags: 0)
    }
}

private func randomSuffix() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    arc4random_buf(&bytes, bytes.count)
    let digits = Array("0123456789abcdef".utf8)
    var output = [UInt8]()
    output.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        output.append(digits[Int(byte >> 4)])
        output.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: output, as: UTF8.self)
}

private func createStage(distFD: Int32, appName: String) throws -> String {
    try validateAppName(appName)
    for _ in 0..<128 {
        let stageName = ".lidmute-stage.\(randomSuffix())"
        if mkdirat(distFD, stageName, 0o700) != 0 {
            if errno == EEXIST { continue }
            throw errnoMessage("mkdirat stage")
        }
        let stageFD = try openDirectory(parentFD: distFD, name: stageName)
        defer { close(stageFD) }
        if mkdirat(stageFD, appName, 0o755) != 0 {
            let savedErrno = errno
            try? removeEntry(parentFD: distFD, name: stageName, requireTopDirectory: true)
            errno = savedErrno
            throw errnoMessage("mkdirat staged App")
        }
        return stageName
    }
    try fail("could not allocate an exclusive stage")
}

private func renameExclusive(
    fromFD: Int32,
    from: String,
    toFD: Int32,
    to: String
) throws {
    if renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_EXCL)) != 0 {
        throw errnoMessage("exclusive rename \(from) -> \(to)")
    }
}

private func renameSwap(
    firstFD: Int32,
    first: String,
    secondFD: Int32,
    second: String
) throws {
    if renameatx_np(firstFD, first, secondFD, second, UInt32(RENAME_SWAP)) != 0 {
        throw errnoMessage("swap rename \(first) <-> \(second)")
    }
}

private func restoreAfterSwap(
    stageFD: Int32,
    appName: String,
    distFD: Int32,
    destination: String
) throws {
    try renameSwap(firstFD: stageFD, first: appName, secondFD: distFD, second: destination)
}

private func openInstallLock(distFD: Int32) throws -> Int32 {
    let lockFD = openat(distFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if lockFD < 0 { throw errnoMessage("openat dist install lock") }
    return lockFD
}

private func holdLock(distFD: Int32) throws {
    let lockFD = try openInstallLock(distFD: distFD)
    defer { close(lockFD) }
    if flock(lockFD, LOCK_EX) != 0 { throw errnoMessage("flock install lock") }
    print("LOCKED")
    fflush(stdout)
    var byte: UInt8 = 0
    _ = read(STDIN_FILENO, &byte, 1)
    _ = flock(lockFD, LOCK_UN)
}

private func install(
    distFD: Int32,
    stageName: String,
    appName: String,
    destination: String,
    preferredBackup: String?,
    strictPreferred: Bool
) throws {
    try validateStageName(stageName)
    try validateAppName(appName)
    try validateAppName(destination)
    if let preferredBackup { try validateBackupName(preferredBackup) }

    let lockFD = try openInstallLock(distFD: distFD)
    defer { close(lockFD) }
    if flock(lockFD, LOCK_EX) != 0 { throw errnoMessage("flock install lock") }
    defer { flock(lockFD, LOCK_UN) }

    let stageFD = try openDirectory(parentFD: distFD, name: stageName)
    defer { close(stageFD) }
    let sourceIdentity = try appIdentity(parentFD: stageFD, name: appName)

    let oldStatus = try statusNoFollow(parentFD: distFD, name: destination)
    if oldStatus == nil {
        try renameExclusive(fromFD: stageFD, from: appName, toFD: distFD, to: destination)
        let installedIdentity = try appIdentity(parentFD: distFD, name: destination)
        let sourceStatus = try statusNoFollow(parentFD: stageFD, name: appName)
        if installedIdentity != sourceIdentity || sourceStatus != nil {
            try fail("exclusive install postcondition failed")
        }
        return
    }

    let oldIdentity = try appIdentity(parentFD: distFD, name: destination)
    try renameSwap(firstFD: stageFD, first: appName, secondFD: distFD, second: destination)
    do {
        let installedIdentity = try appIdentity(parentFD: distFD, name: destination)
        let displacedIdentity = try appIdentity(parentFD: stageFD, name: appName)
        if installedIdentity != sourceIdentity || displacedIdentity != oldIdentity {
            try fail("swap install inode postcondition failed")
        }
    } catch {
        try? restoreAfterSwap(stageFD: stageFD, appName: appName, distFD: distFD, destination: destination)
        throw error
    }

    var candidates = [String]()
    if let preferredBackup { candidates.append(preferredBackup) }
    for _ in 0..<128 { candidates.append(".lidmute-backup.\(randomSuffix())") }
    var backupName: String?
    for candidate in candidates {
        if renameatx_np(stageFD, appName, distFD, candidate, UInt32(RENAME_EXCL)) == 0 {
            backupName = candidate
            break
        }
        if errno == EEXIST {
            if strictPreferred && candidate == preferredBackup {
                try restoreAfterSwap(stageFD: stageFD, appName: appName, distFD: distFD, destination: destination)
                throw errnoMessage("exclusive backup rename")
            }
            continue
        }
        let operationError = errnoMessage("exclusive backup rename")
        try? restoreAfterSwap(stageFD: stageFD, appName: appName, distFD: distFD, destination: destination)
        throw operationError
    }
    guard let backupName else {
        try restoreAfterSwap(stageFD: stageFD, appName: appName, distFD: distFD, destination: destination)
        try fail("could not allocate an exclusive backup")
    }

    do {
        let installedIdentity = try appIdentity(parentFD: distFD, name: destination)
        let sourceStatus = try statusNoFollow(parentFD: stageFD, name: appName)
        if installedIdentity != sourceIdentity || sourceStatus != nil {
            try fail("installed App postcondition failed")
        }
    } catch {
        if (try? renameSwap(
            firstFD: distFD,
            first: backupName,
            secondFD: distFD,
            second: destination
        )) != nil {
            try? renameExclusive(fromFD: distFD, from: backupName, toFD: stageFD, to: appName)
        }
        throw error
    }

    // The verified destination is the commit point. If cleanup fails after
    // this point, keep the old tree isolated and report the failure; never
    // restore a backup that may already be partially removed.
    do {
        try removeEntry(parentFD: distFD, name: backupName, requireTopDirectory: true)
    } catch {
        throw FileSystemError(
            description: "verified destination installed; isolated backup \(backupName) cleanup failed; " +
                "leave it for explicit cleanup: \(error)"
        )
    }
}

private func verifyHandle(fd: Int32, repoRoot: String) throws {
    let distStatus = try statusForFD(fd)
    let repoFD = open(repoRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if repoFD < 0 { throw errnoMessage("open repository root") }
    defer { close(repoFD) }
    let canonicalDistFD = try openDirectory(parentFD: repoFD, name: "dist")
    defer { close(canonicalDistFD) }
    let canonicalStatus = try statusForFD(canonicalDistFD)
    var cwdStatus = stat()
    if fstatat(AT_FDCWD, ".", &cwdStatus, 0) != 0 {
        throw errnoMessage("fstat cwd")
    }
    guard identity(distStatus) == identity(canonicalStatus),
          identity(distStatus) == identity(cwdStatus) else {
        try fail("dist handle is not the canonical repository dist directory")
    }
}

private func withDist(arguments: [String]) throws -> Never {
    guard arguments.count >= 4 else { try fail("with-dist requires repo root and a program") }
    let repoRoot = arguments[2]
    let repoFD = open(repoRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if repoFD < 0 { throw errnoMessage("open repository root") }
    defer { close(repoFD) }
    if mkdirat(repoFD, "dist", 0o755) != 0 && errno != EEXIST {
        throw errnoMessage("mkdirat dist")
    }
    let distFD = try openDirectory(parentFD: repoFD, name: "dist")
    defer { if distFD != fixedDistFD { close(distFD) } }
    if distFD != fixedDistFD && dup2(distFD, fixedDistFD) < 0 {
        throw errnoMessage("dup2 dist fd")
    }
    if fcntl(fixedDistFD, F_SETFD, 0) != 0 {
        throw errnoMessage("clear close-on-exec for dist fd")
    }
    if fchdir(fixedDistFD) != 0 {
        throw errnoMessage("fchdir dist fd")
    }
    if setenv("LIDMUTE_DIST_FD", String(fixedDistFD), 1) != 0 ||
        setenv("LIDMUTE_DIST_HANDLE_ACTIVE", "1", 1) != 0 ||
        setenv("LIDMUTE_DIST_ROOT", ".", 1) != 0 {
        throw errnoMessage("set fixed dist environment")
    }

    let execArguments = Array(arguments.dropFirst(3))
    var pointers: [UnsafeMutablePointer<CChar>?] = execArguments.map { strdup($0) }
    defer { for pointer in pointers { if let pointer { free(pointer) } } }
    pointers.append(nil)
    let result = pointers.withUnsafeMutableBufferPointer { buffer in
        execv(buffer[0], buffer.baseAddress)
    }
    if result != 0 { throw errnoMessage("execv \(execArguments[0])") }
    try fail("execv unexpectedly returned")
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { try fail("missing command") }
    switch arguments[1] {
    case "with-dist":
        try withDist(arguments: arguments)
    case "create-stage":
        guard arguments.count == 4 else { try fail("create-stage requires fd and App name") }
        let fd = try parseFD(arguments[2])
        print(try createStage(distFD: fd, appName: arguments[3]))
    case "hold-lock":
        guard arguments.count == 3 else { try fail("hold-lock requires fd") }
        let fd = try parseFD(arguments[2])
        try holdLock(distFD: fd)
    case "verify-handle":
        guard arguments.count == 4 else { try fail("verify-handle requires fd and repo root") }
        let fd = try parseFD(arguments[2])
        try verifyHandle(fd: fd, repoRoot: arguments[3])
    case "remove":
        guard arguments.count == 5 else { try fail("remove requires fd, kind, and basename") }
        let fd = try parseFD(arguments[2])
        let kind = arguments[3]
        let name = arguments[4]
        switch kind {
        case "stage": try validateStageName(name)
        case "backup": try validateBackupName(name)
        case "app": try validateAppName(name)
        default: try fail("invalid removal kind")
        }
        try removeEntry(parentFD: fd, name: name, requireTopDirectory: true)
    case "install":
        guard (6...8).contains(arguments.count) else {
            try fail("install requires fd, stage, App, destination, optional backup and strict")
        }
        let fd = try parseFD(arguments[2])
        let preferred = arguments.count >= 7 ? arguments[6] : nil
        let strict = arguments.count == 8 && arguments[7] == "strict"
        try install(
            distFD: fd,
            stageName: arguments[3],
            appName: arguments[4],
            destination: arguments[5],
            preferredBackup: preferred,
            strictPreferred: strict
        )
    default:
        try fail("unknown command")
    }
}

do {
    try run()
} catch {
    fputs("release-filesystem: \(error)\n", stderr)
    exit(74)
}
