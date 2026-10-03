import Darwin
import Foundation

enum BoundedLocalProcessError: Error { case outputTooLarge, failed, timedOut, cancelled }

/// Runs one command in its own process group and drains stdout with byte/time limits.
enum BoundedLocalProcess {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        maximumOutputBytes: Int = 1_024 * 1_024,
        timeout: TimeInterval = 5,
        allowedExitCodes: Set<Int32> = [0],
        stream: ((Data) throws -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
        includeStandardError: Bool = false,
        awaitCleanup: Bool = false
    ) throws -> Data {
        guard maximumOutputBytes >= 0, !allowedExitCodes.isEmpty else {
            throw BoundedLocalProcessError.failed
        }

        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else { throw BoundedLocalProcessError.failed }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        guard setCloseOnExec(readDescriptor), setCloseOnExec(writeDescriptor) else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw BoundedLocalProcessError.failed
        }
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
            posix_spawnattr_init(&attributes) == 0
        else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw BoundedLocalProcessError.failed
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
            (includeStandardError
                ? posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO)
                : posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)) == 0,
            posix_spawn_file_actions_addclose(&actions, readDescriptor) == 0,
            posix_spawn_file_actions_addclose(&actions, writeDescriptor) == 0,
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw BoundedLocalProcessError.failed
        }

        let argvStrings = [executable.path] + arguments
        let environmentStrings = environment?.map { "\($0.key)=\($0.value)" }
        guard argvStrings.allSatisfy({ !$0.contains("\0") }),
            environmentStrings?.allSatisfy({ !$0.contains("\0") }) != false
        else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw BoundedLocalProcessError.failed
        }
        var argv = argvStrings.map { strdup($0) } + [nil]
        var customEnvironment = environmentStrings?.map { strdup($0) }.appending(nil)
        defer {
            for pointer in argv {
                if let pointer { Darwin.free(UnsafeMutableRawPointer(pointer)) }
            }
            for pointer in customEnvironment ?? [] {
                if let pointer { Darwin.free(UnsafeMutableRawPointer(pointer)) }
            }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }),
            customEnvironment?.dropLast().allSatisfy({ $0 != nil }) != false
        else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw BoundedLocalProcessError.failed
        }

        var pid: pid_t = 0
        let spawnResult: Int32 = executable.path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                if customEnvironment != nil {
                    return customEnvironment!.withUnsafeMutableBufferPointer { environmentBuffer in
                        posix_spawn(
                            &pid, executablePath, &actions, &attributes,
                            argvBuffer.baseAddress!, environmentBuffer.baseAddress!)
                    }
                }
                return posix_spawn(
                    &pid, executablePath, &actions, &attributes,
                    argvBuffer.baseAddress!, environ)
            }
        }
        Darwin.close(writeDescriptor)
        guard spawnResult == 0 else {
            Darwin.close(readDescriptor)
            throw BoundedLocalProcessError.failed
        }

        var didReap = false
        var waitStatus: Int32 = 0
        var completedSuccessfully = false
        defer {
            Darwin.close(readDescriptor)
            if !completedSuccessfully {
                terminateProcessGroup(pid: pid, didReap: &didReap, waitStatus: &waitStatus)
                // Login reservations and staging must outlive every owned process.
                // This runs on the session's worker, never the UI thread.
                while awaitCleanup && (!didReap || processGroupExists(pid: pid)) {
                    Thread.sleep(forTimeInterval: 1)
                    terminateProcessGroup(pid: pid, didReap: &didReap, waitStatus: &waitStatus)
                }
            }
        }

        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags >= 0, fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw BoundedLocalProcessError.failed
        }
        let duration = timeout.isFinite ? max(0.05, min(timeout, stream == nil ? 60 : 15 * 60)) : 5
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(duration * 1_000_000_000)
        var data = Data()
        var receivedBytes = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var reachedEOF = false

        while !reachedEOF || !didReap {
            if isCancelled?() == true { throw BoundedLocalProcessError.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw BoundedLocalProcessError.timedOut
            }
            updateExitStatus(pid: pid, didReap: &didReap, status: &waitStatus)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(readDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                guard receivedBytes <= maximumOutputBytes,
                    count <= maximumOutputBytes - receivedBytes
                else { throw BoundedLocalProcessError.outputTooLarge }
                receivedBytes += count
                let chunk = Data(buffer.prefix(count))
                if let stream { try stream(chunk) } else { data.append(chunk) }
            } else if count == 0 {
                reachedEOF = true
                if !didReap { Thread.sleep(forTimeInterval: 0.01) }
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                // A reaped direct child with an open stdout pipe means a descendant
                // inherited it. Output is incomplete, so fail and clean this group.
                if didReap, !reachedEOF { throw BoundedLocalProcessError.failed }
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                throw BoundedLocalProcessError.failed
            }
        }

        guard let exitCode = exitCode(from: waitStatus), allowedExitCodes.contains(exitCode) else {
            throw BoundedLocalProcessError.failed
        }
        // stdout EOF and the direct child's exit do not prove that descendants
        // which closed stdio have left the dedicated process group.
        guard !processGroupExists(pid: pid) else { throw BoundedLocalProcessError.failed }
        completedSuccessfully = true
        return data
    }

    private static func updateExitStatus(pid: pid_t, didReap: inout Bool, status: inout Int32) {
        guard !didReap else { return }
        while true {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                didReap = true
                return
            }
            if result == 0 { return }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == ECHILD {
                // Do not manufacture a successful exit code when this caller did
                // not reap the child and therefore cannot verify its status.
                status = -1
                didReap = true
            }
            return
        }
    }

    @discardableResult
    private static func waitForExit(
        pid: pid_t,
        deadline: UInt64,
        didReap: inout Bool,
        status: inout Int32
    ) -> Bool {
        while !didReap, DispatchTime.now().uptimeNanoseconds < deadline {
            updateExitStatus(pid: pid, didReap: &didReap, status: &status)
            if !didReap { Thread.sleep(forTimeInterval: 0.01) }
        }
        return didReap
    }

    private static func terminateProcessGroup(pid: pid_t, didReap: inout Bool, waitStatus: inout Int32) {
        _ = Darwin.kill(-pid, SIGTERM)
        let termDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        if !waitForExit(pid: pid, deadline: termDeadline, didReap: &didReap, status: &waitStatus) {
            _ = Darwin.kill(-pid, SIGKILL)
            let killDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            _ = waitForExit(pid: pid, deadline: killDeadline, didReap: &didReap, status: &waitStatus)
        } else {
            // The direct child may be reaped while descendants remain in the
            // dedicated group. Kill the remainder without touching other launches.
            _ = Darwin.kill(-pid, SIGKILL)
        }
    }

    private static func processGroupExists(pid: pid_t) -> Bool {
        if Darwin.kill(-pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func exitCode(from status: Int32) -> Int32? {
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }
}

private extension Array where Element == UnsafeMutablePointer<CChar>? {
    func appending(_ element: Element) -> Self {
        var copy = self
        copy.append(element)
        return copy
    }
}
