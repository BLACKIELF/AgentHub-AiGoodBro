#!/usr/bin/env python3
"""Real native socket client, synthetic local server; no account/model/UI access."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
services = root / "Sources/CodexUsageWidget/Services"
source = (services / "CodexAppServerTaskClient.swift").read_text()
prefix = source[:source.index("enum POSIXPipeReaderError")]
client = source[source.index("final class CodexAppServerTaskClient:"):]
runtime = (root / "Sources/CodexUsageWidget/Domain/TaskRuntime.swift").read_text()
runtime = runtime[runtime.index("enum TaskRuntimeState:"):runtime.index("enum TaskAttentionKind:")]
stubs = '''
enum TaskColumnKind { case active, done, pending }
struct PerformanceSpan {}
enum PerformanceEvent { case appServerTasks }
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    func begin(_ event: PerformanceEvent) -> PerformanceSpan { PerformanceSpan() }
    func end(_ span: PerformanceSpan, success: Bool = true) {}
}
func debugLog(_ value: String) {}
'''
fixture = '''
@main struct Fixture {
    @MainActor static func main() async {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let client = CodexAppServerTaskClient(homeDirectory: home)
        var connected = false
        client.onSnapshot = { connected = $0.connectionMode != .disconnected }
        client.start(reason: .startup)
        if mode != "offline" {
            for _ in 0..<300 where !connected { try? await Task.sleep(nanoseconds: 10_000_000) }
            precondition(connected, "synthetic socket did not initialize")
        }
        let admission = WeChatCodexSendAdmission()
        if mode == "cancelled" { admission.cancel() }
        let result = await client.createPersonalWeChatThread(admission: admission)
        switch result {
        case .created(let id):
            precondition(mode == "success" && id == "10000000-0000-4000-8000-000000000001")
            precondition(admission.wasRequestAttempted)
        case .uncertain:
            precondition(mode == "lost" || mode == "rejected")
            precondition(admission.wasRequestAttempted)
        case .unavailable:
            precondition(mode == "offline" || mode == "cancelled")
            precondition(!admission.wasRequestAttempted)
        }
        client.stop()
        print("PASS native thread creation: " + mode)
    }
}
'''


def exactly(connection, count):
    data = b""
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def receive(connection):
    first, second = exactly(connection, 2)
    length = second & 127
    if length == 126:
        length = struct.unpack("!H", exactly(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", exactly(connection, 8))[0]
    assert length < 65536
    mask = exactly(connection, 4) if second & 128 else b""
    data = exactly(connection, length)
    if mask:
        data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
    if first & 15 == 8:
        raise EOFError()
    return json.loads(data)


def send(connection, value):
    data = json.dumps(value).encode()
    header = bytes([0x81, len(data)]) if len(data) < 126 else b"\x81\x7e" + struct.pack("!H", len(data))
    connection.sendall(header + data)


with tempfile.TemporaryDirectory(prefix="wx-rpc-", dir="/tmp") as temporary:
    directory = Path(temporary).resolve()
    swift = directory / "fixture.swift"
    swift.write_text("\n".join([prefix, stubs, runtime,
        (services / "AFUnixWebSocket.swift").read_text(),
        (services / "CodexDesktopIPC.swift").read_text(),
        (services / "WeChatCodexConversation.swift").read_text(), client, fixture]))
    binary = directory / "fixture"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    for mode in ["success", "lost", "rejected", "cancelled", "offline"]:
        home = directory / mode
        socket_path = home / ".codex/app-server-control/app-server-control.sock"
        socket_path.parent.mkdir(parents=True)
        calls, errors = [], []
        server = socket.socket(socket.AF_UNIX)
        if mode != "offline":
            server.bind(str(socket_path))
            server.listen(1)

        def serve():
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(10)
                    header = b""
                    while not header.endswith(b"\r\n\r\n"):
                        header += exactly(connection, 1)
                    key = next(row.split(b":", 1)[1].strip() for row in header.split(b"\r\n") if row.lower().startswith(b"sec-websocket-key:"))
                    accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                    connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                    while True:
                        request = receive(connection)
                        method = request.get("method")
                        if "id" not in request:
                            continue
                        result = {}
                        if method == "thread/list":
                            result = {"data": [], "nextCursor": None}
                        elif method == "thread/start":
                            calls.append(method)
                            assert request["params"] == {"cwd": str(home / "Library/Application Support/CodexAccountManagerNext/PersonalWeChat/Workspace"), "ephemeral": False}
                            if mode == "lost":
                                return
                            if mode == "rejected":
                                send(connection, {"id": request["id"], "error": {"code": -32600, "message": "synthetic rejection"}})
                                continue
                            result = {"thread": {"id": "10000000-0000-4000-8000-000000000001"}}
                        elif method == "thread/name/set":
                            calls.append(method)
                            assert request["params"] == {"threadId": "10000000-0000-4000-8000-000000000001", "name": "微信专用对话"}
                        else:
                            assert method == "initialize"
                        send(connection, {"id": request["id"], "result": result})
            except EOFError:
                pass
            except Exception as error:
                errors.append(repr(error))

        worker = threading.Thread(target=serve, daemon=True)
        if mode != "offline":
            worker.start()
        subprocess.run([str(binary), str(home), mode], check=True, timeout=20)
        if mode != "offline":
            worker.join(2)
            assert not worker.is_alive() and not errors, errors
        server.close()
        expected = ["thread/start", "thread/name/set"] if mode == "success" else ["thread/start"] if mode in ["lost", "rejected"] else []
        assert calls == expected, (mode, calls)
