#!/usr/bin/env python3
"""Production Swift socket lifecycle with a synthetic Unix peer and controlled syscall scheduling."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/CodexUsageWidget/Services/AFUnixWebSocket.swift"

FIXTURE = r'''
func debugLog(_ value: String) {}

enum SocketFixtureIO {
    static let mode = CommandLine.arguments[2]
    static let entered = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    static let lock = NSLock()
    static var descriptor: Int32 = -1
    static var gated = false
    static var receivedHandshake = false

    static func pause(_ kind: String, fd: Int32, blocking: Bool = true) {
        lock.lock()
        let match = mode == kind && !gated
        if match { gated = true; descriptor = fd }
        lock.unlock()
        if match {
            entered.signal()
            if blocking { precondition(release.wait(timeout: .now() + 5) == .success) }
        }
    }

    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
        let result = Darwin.connect(fd, address, length)
        if result == 0 { pause("connect", fd: fd) }
        return result
    }

    static func write(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
        let first = bytes?.load(as: UInt8.self)
        if first == 71 { pause("handshake", fd: fd) }
        if first == 0x81 { pause("send", fd: fd) }
        if first == 0x8A { pause("pong", fd: fd) }
        if count > 100_000 { pause("blocked", fd: fd, blocking: false) }
        return Darwin.write(fd, bytes, count)
    }

    static func read(_ fd: Int32, _ bytes: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        lock.lock(); let afterHandshake = receivedHandshake; lock.unlock()
        if afterHandshake { pause("read", fd: fd) }
        let result = Darwin.read(fd, bytes, count)
        if result > 0, bytes?.load(as: UInt8.self) == 72 {
            lock.lock(); receivedHandshake = true; lock.unlock()
        }
        return result
    }
}

final class Observations {
    let lock = NSLock()
    var ready = 0
    var messages: [Data] = []
    func noteReady() { lock.lock(); ready += 1; lock.unlock() }
    func noteMessage(_ data: Data) { lock.lock(); messages.append(data); lock.unlock() }
    func snapshot() -> (Int, [Data]) { lock.lock(); defer { lock.unlock() }; return (ready, messages) }
}

@main struct Fixture {
    static func main() {
        let mode = SocketFixtureIO.mode
        let observations = Observations()
        let ready = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let client = AFUnixWebSocket(socketPath: CommandLine.arguments[1], maximumMessageBytes: 4 * 1024 * 1024,
                                     callbackQueue: DispatchQueue(label: "fixture.callback"))
        client.start(onReady: { observations.noteReady(); ready.signal() },
                     onMessage: { observations.noteMessage($0) }, onDisconnect: { disconnected.signal() })
        var sendSucceeded = false
        if mode == "send" || mode == "blocked" || mode == "normal" {
            precondition(ready.wait(timeout: .now() + 3) == .success)
        }
        if mode == "normal" {
            precondition(client.sendText(Data("fixture-client".utf8)))
            for _ in 0..<100 where observations.snapshot().1.isEmpty { usleep(10_000) }
            precondition(observations.snapshot().1 == [Data("fixture-message".utf8)])
            client.close()
            precondition(disconnected.wait(timeout: .now() + 2) == .success)
            print("PASS normal handshake / text / ping-pong / close")
            return
        }
        if mode == "send" || mode == "blocked" {
            DispatchQueue.global().async {
                let data = mode == "blocked" ? Data(repeating: 97, count: 2 * 1024 * 1024) : Data("fixture-client".utf8)
                sendSucceeded = client.sendText(data)
                sent.signal()
            }
        }
        precondition(SocketFixtureIO.entered.wait(timeout: .now() + 3) == .success)
        if mode == "blocked" { usleep(100_000) }
        let started = Date()
        client.close()
        precondition(Date().timeIntervalSince(started) < 0.5, "close must not wait on a blocked writer")
        let fd = SocketFixtureIO.descriptor
        let descriptorWasClosed = fcntl(fd, F_GETFD) == -1 && errno == EBADF
        var replacement: Int32 = -1
        var peer: Int32 = -1
        if descriptorWasClosed && mode != "blocked" {
            var pair: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            if pair[1] == fd { pair.swapAt(0, 1) }
            if pair[0] != fd { precondition(dup2(pair[0], fd) == fd); Darwin.close(pair[0]) }
            replacement = fd; peer = pair[1]
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(peer, F_SETFL, O_NONBLOCK)
            if mode == "read" {
                let payload = Data("unrelated-fixture".utf8)
                let frame = Data([0x81, UInt8(payload.count)]) + payload
                _ = frame.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
            }
        }
        SocketFixtureIO.release.signal()
        if mode == "send" || mode == "blocked" {
            precondition(sent.wait(timeout: .now() + 2) == .success, "shutdown must interrupt sender")
        }
        usleep(350_000)
        var leakedBytes = 0
        if peer >= 0 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            leakedBytes = max(0, Darwin.read(peer, &bytes, bytes.count))
            Darwin.shutdown(peer, SHUT_RDWR); Darwin.close(peer)
            Darwin.shutdown(replacement, SHUT_RDWR); Darwin.close(replacement)
        }
        let state = observations.snapshot()
        client.close()
        let ended = disconnected.wait(timeout: .now() + 2) == .success
        let okay = ended && leakedBytes == 0 && !state.1.contains(Data("unrelated-fixture".utf8))
            && (mode == "blocked" || !descriptorWasClosed)
            && (!(mode == "connect" || mode == "handshake") || state.0 == 0)
            && (!(mode == "send" || mode == "blocked") || !sendSucceeded)
        print("RESULT \(mode) safe=\(okay) reused=\(descriptorWasClosed) leakedBytes=\(leakedBytes) ready=\(state.0)")
        if !okay { exit(1) }
    }
}
'''


def receive_exact(connection, length):
    result = b""
    while len(result) < length:
        data = connection.recv(length - len(result))
        if not data:
            raise EOFError()
        result += data
    return result


def serve(server, mode, done, errors):
    try:
        server.settimeout(5)
        connection, _ = server.accept()
        with connection:
            connection.settimeout(5)
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                header += receive_exact(connection, 1)
            key = next(row.split(b":", 1)[1].strip() for row in header.split(b"\r\n")
                       if row.lower().startswith(b"sec-websocket-key:"))
            accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
            connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            if mode == "pong":
                connection.sendall(b"\x89\x01p")
            if mode == "normal":
                connection.sendall(b"\x89\x01p\x81\x0ffixture-message")
                frames = []
                for _ in range(2):
                    first, second = receive_exact(connection, 2)
                    length = second & 127
                    if length == 126:
                        length = struct.unpack("!H", receive_exact(connection, 2))[0]
                    mask = receive_exact(connection, 4)
                    payload = receive_exact(connection, length)
                    frames.append((first & 15, bytes(b ^ mask[i % 4] for i, b in enumerate(payload))))
                assert sorted(frames) == [(1, b"fixture-client"), (10, b"p")]
            done.wait(5)
    except (EOFError, BrokenPipeError, ConnectionResetError):
        if mode == "normal":
            errors.append("normal_peer_closed_early")
    except Exception as error:
        errors.append(type(error).__name__)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-file", type=Path, default=SOURCE)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    original = args.source_file.read_bytes()
    # Only scheduling wrappers are substituted in the disposable compiler input;
    # every wrapped operation still executes the real Darwin syscall.
    instrumented = original.decode()
    for syscall in ("connect", "write", "read"):
        instrumented = instrumented.replace("Darwin." + syscall + "(", "SocketFixtureIO." + syscall + "(")
    results = []
    with tempfile.TemporaryDirectory(prefix="agb-ws-", dir="/tmp") as temporary:
        directory = Path(temporary)
        swift = directory / "fixture.swift"
        swift.write_text(instrumented + "\n" + FIXTURE)
        binary = directory / "fixture"
        build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)],
                               capture_output=True, text=True, timeout=120)
        if build.returncode:
            print(build.stderr.replace(temporary, "<fixture>"))
            raise SystemExit(build.returncode)
        for mode in ("normal", "send", "read", "pong", "handshake", "connect", "blocked"):
            path = directory / (mode + ".sock")
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path)); server.listen(1)
                done, errors = threading.Event(), []
                thread = threading.Thread(target=serve, args=(server, mode, done, errors), daemon=True)
                thread.start()
                run = subprocess.run([str(binary), str(path), mode], capture_output=True, text=True, timeout=12)
                done.set(); thread.join(timeout=6)
                item = {"mode": mode, "exitCode": run.returncode, "output": run.stdout.strip(), "peerErrors": errors}
                results.append(item); print(json.dumps(item), flush=True)
    unchanged = args.source_file.read_bytes() == original
    okay = unchanged and all(x["exitCode"] == 0 and not x["peerErrors"] for x in results)
    if args.receipt:
        args.receipt.write_text(json.dumps({"passed": okay, "inputsUnchanged": unchanged,
            "sourceSHA256": hashlib.sha256(original).hexdigest(), "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "cases": results, "realDaemonConnections": 0, "externalNetworkCalls": 0}, indent=2) + "\n")
    raise SystemExit(0 if okay else 1)


if __name__ == "__main__":
    main()
