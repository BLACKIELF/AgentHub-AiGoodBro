#!/usr/bin/env python3
"""One-shot Companion IPC client. No model CLI, App start, or retry loop.

Windows only; run with the native-selected Python using -I -B. The native
installer supplies config/runtime-paths.json beside this bin directory.
The unsigned App binding is explicitly created by that App's enable action.
This is a same-user local trust boundary, not protection from that user
deliberately replacing the installed script or private source binding.
"""
import argparse
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import time

ABI = 1
MAX_FRAME = 96 * 1024
HEX = re.compile(r"[0-9a-f]{64}\Z")
TASK_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
ISSUE = re.compile(r"[a-z][a-z0-9_]{0,95}\Z")


class ClientError(Exception):
    def __init__(self, code):
        self.code = code


def fail(code):
    raise ClientError(code)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            fail("companion_invalid_response")
        value[key] = item
    return value


def decode(data, maximum=MAX_FRAME):
    if not isinstance(data, bytes) or not 0 < len(data) <= maximum:
        fail("companion_invalid_response")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        fail("companion_invalid_response")


def keys(value, names):
    if not isinstance(value, dict) or set(value) != set(names):
        fail("companion_invalid_response")


def digest(value):
    return isinstance(value, str) and HEX.fullmatch(value) is not None


def task(value):
    keys(value, ("taskId", "actionHash", "scopeSha256"))
    if not isinstance(value["taskId"], str) or not TASK_ID.fullmatch(value["taskId"]):
        fail("companion_invalid_response")
    if not digest(value["actionHash"]) or not digest(value["scopeSha256"]):
        fail("companion_invalid_response")


def response(data, request_id):
    value = decode(data)
    keys(value, ("abi", "requestId", "result", "issueCode"))
    if type(value["abi"]) is not int or value["abi"] != ABI or value["requestId"] != request_id:
        fail("companion_invalid_response")
    issue = value["issueCode"]
    if issue is not None:
        if value["result"] is not None or not isinstance(issue, str) or not ISSUE.fullmatch(issue):
            fail("companion_invalid_response")
        fail(issue)
    result = value["result"]
    if not isinstance(result, dict):
        fail("companion_invalid_response")
    state = result.get("state")
    if state in ("unknown", "missing", "cancelled"):
        keys(result, ("state",))
    elif state in ("ready", "reserved"):
        required = ["state", "scopeSha256", "validUntilMs"]
        if state == "reserved":
            required.append("leaseId")
            if not digest(result.get("leaseId")):
                fail("companion_invalid_response")
        keys(result, required)
        if not digest(result["scopeSha256"]) or type(result["validUntilMs"]) is not int or result["validUntilMs"] <= 0:
            fail("companion_invalid_response")
    elif state in ("created", "accepted"):
        keys(result, ("state", "task", "taskState"))
        task(result["task"])
        if result["taskState"] not in ("awaitingApproval", "starting", "running", "awaitingAcceptance", "failed", "cancelled", "uncertain"):
            fail("companion_invalid_response")
        if state == "accepted" and result["taskState"] == "awaitingApproval":
            fail("companion_invalid_response")
    else:
        fail("companion_invalid_response")
    return result


def invoke_once(transport, request):
    """After write may begin, every non-exact outcome is Unknown. Never retry."""
    if not digest(request.get("requestId")) or request.get("abi") != ABI:
        fail("companion_invalid_request")
    data = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not 0 < len(data) <= MAX_FRAME:
        fail("companion_invalid_request")
    frame = struct.pack("<I", len(data)) + data
    transport.authenticate()
    # A failed/late authentication has no write; no caller-controlled override.
    attempted = False
    try:
        transport.recheck()
        attempted = True
        transport.write_once(frame)
        raw = transport.read_frame()
        result = response(raw, request["requestId"])
        allowed = {
            "preflight": {"ready", "unknown"}, "refresh": {"ready", "unknown"},
            "reserve": {"reserved", "unknown"}, "run": {"created", "accepted", "unknown"},
            "status": {"missing", "created", "accepted", "unknown"},
            "cancelReservation": {"cancelled", "unknown"},
        }
        if result["state"] not in allowed.get(request["method"]["kind"], set()):
            fail("companion_invalid_response")
        return result
    except (Exception, KeyboardInterrupt):
        if attempted:
            return {"state": "unknown"}
        raise


class WinTransport:
    """Only private native source binding + OS connected-peer facts are trusted.

    The constructor is internal to this installed script. CLI cannot supply a
    pipe, App hash, or alternate source binding. Synthetic native tests use a
    private copied Skill layout with the same fixed runtime-config schema.
    """
    def __init__(self, runtime_config, request_id, seconds=15):
        if os.name != "nt":
            fail("companion_windows_required")
        self.end = time.monotonic() + seconds
        self.request_id = request_id
        self.stack = contextlib.ExitStack()
        self.k = ctypes.WinDLL("kernel32", use_last_error=True)
        self.a = ctypes.WinDLL("advapi32", use_last_error=True)
        self.h = ctypes.c_void_p
        self.u = ctypes.c_uint32
        self.p = ctypes.POINTER
        self._apis()
        self.config_path = Path(runtime_config)
        self.pipe = None

    def _apis(self):
        h, u, p = self.h, self.u, self.p
        def api(dll, name, result, arguments):
            fn = getattr(dll, name)
            fn.restype, fn.argtypes = result, arguments
        api(self.k, "CreateFileW", h, [ctypes.c_wchar_p,u,u,h,u,u,h])
        api(self.k, "CloseHandle", ctypes.c_int, [h])
        api(self.k, "LocalFree", h, [h])
        api(self.k, "ReadFile", ctypes.c_int, [h,h,u,p(u),h])
        api(self.k, "WriteFile", ctypes.c_int, [h,h,u,p(u),h])
        api(self.k, "GetFileInformationByHandle", ctypes.c_int, [h,h])
        api(self.k, "GetFinalPathNameByHandleW", u, [h,ctypes.c_wchar_p,u,u])
        api(self.k, "GetCurrentProcess", h, [])
        api(self.k, "GetCurrentProcessId", u, [])
        api(self.k, "OpenProcess", h, [u,ctypes.c_int,u])
        api(self.k, "GetProcessTimes", ctypes.c_int, [h,h,h,h,h])
        api(self.k, "ProcessIdToSessionId", ctypes.c_int, [u,p(u)])
        api(self.k, "QueryFullProcessImageNameW", ctypes.c_int, [h,u,ctypes.c_wchar_p,p(u)])
        api(self.k, "GetNamedPipeServerProcessId", ctypes.c_int, [h,p(u)])
        api(self.k, "WaitForSingleObject", u, [h,u])
        api(self.k, "CreateEventW", h, [h,ctypes.c_int,ctypes.c_int,ctypes.c_wchar_p])
        api(self.k, "GetOverlappedResult", ctypes.c_int, [h,h,p(u),ctypes.c_int])
        api(self.k, "CancelIoEx", ctypes.c_int, [h,h])
        api(self.a, "OpenProcessToken", ctypes.c_int, [h,u,p(h)])
        api(self.a, "GetTokenInformation", ctypes.c_int, [h,u,h,u,p(u)])
        api(self.a, "EqualSid", ctypes.c_int, [h,h])
        api(self.a, "IsValidSid", ctypes.c_int, [h])
        api(self.a, "GetLengthSid", u, [h])
        api(self.a, "IsWellKnownSid", ctypes.c_int, [h,u])
        api(self.a, "GetSecurityInfo", u, [h,u,u,p(h),h,p(h),h,p(h)])
        api(self.a, "IsValidAcl", ctypes.c_int, [h])
        api(self.a, "GetAce", ctypes.c_int, [h,u,p(h)])

    def close(self):
        self.stack.close()

    def _check_time(self):
        if time.monotonic() >= self.end:
            fail("companion_ipc_timeout")

    def _owned(self, handle):
        if not handle or handle == ctypes.c_void_p(-1).value:
            fail("companion_native_unavailable")
        self.stack.callback(self.k.CloseHandle, handle)
        return handle

    def _token(self, process):
        token = self.h()
        if not self.a.OpenProcessToken(process, 8, ctypes.byref(token)):
            fail("companion_peer_untrusted")
        return self._owned(token.value)

    def _user(self, token):
        size = self.u()
        self.a.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
        if not 16 <= size.value <= 65536:
            fail("companion_peer_untrusted")
        data = ctypes.create_string_buffer(size.value)
        if not self.a.GetTokenInformation(token, 1, data, size, ctypes.byref(size)):
            fail("companion_peer_untrusted")
        sid = ctypes.cast(data, self.p(self.h))[0]
        if not self.a.IsValidSid(sid):
            fail("companion_peer_untrusted")
        return data, sid

    def _unelevated(self, token):
        value, size = self.u(1), self.u()
        if not self.a.GetTokenInformation(token, 20, ctypes.byref(value), 4, ctypes.byref(size)) or value.value:
            fail("companion_peer_untrusted")

    def _private(self, handle, kind, exact_private=True):
        owner, acl, descriptor = self.h(), self.h(), self.h()
        status = self.a.GetSecurityInfo(handle, kind, 1 | 4, ctypes.byref(owner), None, ctypes.byref(acl), None, ctypes.byref(descriptor))
        try:
            if status or not owner.value or not acl.value or not self.a.IsValidSid(owner) or not self.a.IsValidAcl(acl) or not self.a.EqualSid(owner, self.current_sid):
                fail("companion_peer_untrusted")
            acl_head = ctypes.string_at(acl, 8)
            count = struct.unpack_from("<H", acl_head, 4)[0]
            for index in range(count):
                ace = self.h()
                if not self.a.GetAce(acl, index, ctypes.byref(ace)) or not ace.value:
                    fail("companion_peer_untrusted")
                kind_ace, flags, size, mask = struct.unpack("<BBHI", ctypes.string_at(ace, 8))
                if size < 12:
                    fail("companion_peer_untrusted")
                if flags & 8 or kind_ace == 1:
                    continue
                sid = ace.value + 8
                if kind_ace != 0 or not self.a.IsValidSid(sid) or 8 + self.a.GetLengthSid(sid) > size:
                    fail("companion_peer_untrusted")
                trusted = self.a.EqualSid(sid, self.current_sid) or self.a.IsWellKnownSid(sid, 22)
                # Private native binding/locator: no outsiders, even read-only.
                # Runtime config may have ordinary read-only ACEs, never writes.
                allowed_read = 0 if exact_private else 0x120089
                if not trusted and mask & ~allowed_read:
                    fail("companion_peer_untrusted")
        finally:
            if descriptor.value:
                self.k.LocalFree(descriptor)

    def _info(self, handle):
        raw = ctypes.create_string_buffer(52)
        if not self.k.GetFileInformationByHandle(handle, raw):
            fail("companion_peer_untrusted")
        words = struct.unpack("<13I", raw.raw)
        if words[0] & 0x400:
            fail("companion_peer_untrusted")
        return {"attributes": words[0], "volume": words[7], "length": (words[8] << 32) | words[9],
                "links": words[10], "index": (words[11] << 32) | words[12], "written": (words[6] << 32) | words[5]}

    def _path(self, handle):
        data = ctypes.create_unicode_buffer(32768)
        n = self.k.GetFinalPathNameByHandleW(handle, data, len(data), 0)
        if not 0 < n < len(data):
            fail("companion_peer_untrusted")
        value = data.value
        if not re.fullmatch(r"\\\\\?\\[A-Za-z]:\\.+", value):
            fail("companion_local_path_required")
        return value

    def _open_file(self, path, directory=False):
        if not isinstance(path, (str, Path)) or "\0" in str(path):
            fail("companion_local_path_required")
        value = str(path)
        plain = value[4:] if value.startswith("\\\\?\\") else value
        if not re.match(r"[A-Za-z]:[\\/]", plain) or ".." in re.split(r"[\\/]", plain):
            fail("companion_local_path_required")
        # Hold ancestors without write/delete sharing, refusing reparse points.
        for parent in reversed(Path(value).parents):
            h = self._owned(self.k.CreateFileW(str(parent), 0x80000000, 1, None, 3, 0x02200000, None))
            if not self._info(h)["attributes"] & 0x10:
                fail("companion_peer_untrusted")
        handle = self._owned(self.k.CreateFileW(value, 0x80000000, 1, None, 3, 0x00200000 | (0x02000000 if directory else 0), None))
        info = self._info(handle)
        if bool(info["attributes"] & 0x10) != directory or (not directory and info["links"] != 1):
            fail("companion_peer_untrusted")
        return handle

    def _read_file(self, path, limit, private=True):
        handle = self._open_file(path)
        self._private(handle, 1, private)
        before = self._info(handle)
        if before["length"] > limit:
            fail("companion_invalid_runtime_config")
        data = ctypes.create_string_buffer(before["length"] + 1)
        count = self.u()
        if not self.k.ReadFile(handle, data, len(data), ctypes.byref(count), None) or count.value != before["length"] or self._info(handle) != before:
            fail("companion_peer_untrusted")
        return data.raw[:count.value]

    def _birth(self, process):
        times = (ctypes.c_uint64 * 4)()
        if not self.k.GetProcessTimes(process, ctypes.byref(times, 0), ctypes.byref(times, 8), ctypes.byref(times, 16), ctypes.byref(times, 24)):
            fail("companion_peer_untrusted")
        return times[0]

    def _session(self, pid):
        value = self.u()
        if not self.k.ProcessIdToSessionId(pid, ctypes.byref(value)):
            fail("companion_peer_untrusted")
        return value.value

    def _process_image(self, process):
        data, size = ctypes.create_unicode_buffer(32768), self.u(32768)
        if not self.k.QueryFullProcessImageNameW(process, 0, data, ctypes.byref(size)) or not 0 < size.value < 32768:
            fail("companion_peer_untrusted")
        handle = self._open_file(data.value)
        return handle, self._path(handle)

    def authenticate(self):
        current_token = self._token(self.k.GetCurrentProcess())
        self._unelevated(current_token)
        self.current_user, self.current_sid = self._user(current_token)
        config = decode(self._read_file(self.config_path, 16384, False), 16384)
        keys(config, ("schemaVersion", "python", "adapterABI", "bridgeRoot"))
        if type(config["schemaVersion"]) is not int or type(config["adapterABI"]) is not int or config["schemaVersion"] != 1 or config["adapterABI"] != ABI:
            fail("companion_invalid_runtime_config")
        selected = self._open_file(config["python"])
        current_image, current_path = self._process_image(self.k.GetCurrentProcess())
        if self._info(selected) != self._info(current_image) or self._path(selected) != current_path:
            fail("companion_interpreter_changed")
        root = Path(config["bridgeRoot"])
        root_handle = self._open_file(root, True)
        self._private(root_handle, 1)
        source_raw = self._read_file(root / "app-source-v1.json", 16384)
        source = decode(source_raw, 16384)
        keys(source, ("schema", "role", "abi", "image"))
        if type(source["schema"]) is not int or type(source["abi"]) is not int or source["schema"] != 1 or source["role"] != "appSource" or source["abi"] != ABI:
            fail("companion_enable_required")
        image = source["image"]
        keys(image, ("path", "volume", "index", "length", "written", "sha256"))
        if not digest(image["sha256"]) or any(type(image[k]) is not int for k in ("volume", "index", "length", "written")):
            fail("companion_peer_untrusted")
        locator = decode(self._read_file(root / "receiver-v1.json", 16384), 16384)
        keys(locator, ("schema", "role", "abi", "pid", "birth", "session", "pipe", "sourceSha256", "epoch"))
        if type(locator["schema"]) is not int or type(locator["abi"]) is not int or locator["schema"] != 1 or locator["role"] != "runtimeLocator" or locator["abi"] != ABI or locator["sourceSha256"] != hashlib.sha256(source_raw).hexdigest() or not digest(locator["epoch"]):
            fail("companion_peer_untrusted")
        if any(type(locator[k]) is not int for k in ("pid", "birth", "session")) or locator["pid"] <= 0:
            fail("companion_peer_untrusted")
        if not isinstance(locator["pipe"], str) or not re.fullmatch(r"\\\\\.\\pipe\\AiGoodBro-companion-v1-[0-9a-f]{32}", locator["pipe"]):
            fail("companion_peer_untrusted")
        self._check_time()
        # OPEN_EXISTING, overlapped, identification-only impersonation level.
        self.pipe = self._owned(self.k.CreateFileW(locator["pipe"], 0xC0000000, 0, None, 3, 0x40110000, None))
        self._private(self.pipe, 6)
        pid = self.u()
        if not self.k.GetNamedPipeServerProcessId(self.pipe, ctypes.byref(pid)) or pid.value != locator["pid"]:
            fail("companion_peer_untrusted")
        self.pid = pid.value
        self.process = self._owned(self.k.OpenProcess(0x00101000, False, self.pid))
        other = self._token(self.process)
        self._unelevated(other)
        self.other_user, other_sid = self._user(other)
        if not self.a.EqualSid(self.current_sid, other_sid) or self._session(self.pid) != self._session(self.k.GetCurrentProcessId()) or self._session(self.pid) != locator["session"]:
            fail("companion_peer_untrusted")
        self.born, self.session = locator["birth"], locator["session"]
        self.image_handle, self.image_path = self._process_image(self.process)
        self.image_info = self._info(self.image_handle)
        if self.image_path != image["path"] or any(self.image_info[k] != image[k] for k in ("volume", "index", "length", "written")) or not 64 <= image["length"] <= 512 * 1024 * 1024:
            fail("companion_peer_untrusted")
        sha, length = hashlib.sha256(), 0
        while True:
            self._check_time()
            block, count = ctypes.create_string_buffer(65536), self.u()
            if not self.k.ReadFile(self.image_handle, block, len(block), ctypes.byref(count), None):
                fail("companion_peer_untrusted")
            if not count.value:
                break
            length += count.value
            if length > image["length"]:
                fail("companion_peer_untrusted")
            sha.update(block.raw[:count.value])
        if length != image["length"] or sha.hexdigest() != image["sha256"]:
            fail("companion_peer_untrusted")
        self.recheck()

    def recheck(self):
        self._check_time()
        self._private(self.pipe, 6)
        pid = self.u()
        if self.k.WaitForSingleObject(self.process, 0) != 258 or self._birth(self.process) != self.born or not self.k.GetNamedPipeServerProcessId(self.pipe, ctypes.byref(pid)) or pid.value != self.pid or self._session(self.pid) != self.session or self._info(self.image_handle) != self.image_info:
            fail("companion_peer_untrusted")

    def _fatal_pending_io(self):
        # Only this one-shot client's own pending I/O is affected. Do not free
        # its OVERLAPPED/buffer while Windows may still reference them.
        print(json.dumps({"requestId": self.request_id, "result": {"state": "unknown"}}), flush=True)
        os._exit(3)

    def _io(self, data=None, size=0):
        class Overlapped(ctypes.Structure):
            _fields_ = [("internal", ctypes.c_size_t), ("high", ctypes.c_size_t), ("offset", ctypes.c_uint32), ("offsetHigh", ctypes.c_uint32), ("event", ctypes.c_void_p)]
        self._check_time()
        event = self.k.CreateEventW(None, True, False, None)
        if not event:
            fail("companion_native_unavailable")
        overlapped = Overlapped(event=event)
        buffer = ctypes.create_string_buffer(data, len(data)) if data is not None else ctypes.create_string_buffer(size)
        count = self.u()
        try:
            fn = self.k.WriteFile if data is not None else self.k.ReadFile
            ok = fn(self.pipe, buffer, len(buffer), ctypes.byref(count), ctypes.byref(overlapped))
            if not ok and ctypes.get_last_error() != 997:
                fail("companion_ipc_disconnected")
            if not ok:
                wait = max(1, min(15000, int((self.end - time.monotonic()) * 1000)))
                if self.k.WaitForSingleObject(event, wait) != 0:
                    self.k.CancelIoEx(self.pipe, ctypes.byref(overlapped))
                    if self.k.WaitForSingleObject(event, 1000) != 0:
                        self._fatal_pending_io()
                    self.k.GetOverlappedResult(self.pipe, ctypes.byref(overlapped), ctypes.byref(count), False)
                    fail("companion_ipc_timeout")
                if not self.k.GetOverlappedResult(self.pipe, ctypes.byref(overlapped), ctypes.byref(count), False):
                    fail("companion_ipc_disconnected")
            self._check_time()
            return count.value if data is not None else buffer.raw[:count.value]
        finally:
            self.k.CloseHandle(event)

    def write_once(self, frame):
        if self._io(data=frame) != len(frame):
            fail("companion_ipc_short_write")

    def _read(self, length):
        data = bytearray()
        while len(data) < length:
            block = self._io(size=length-len(data))
            if not block:
                fail("companion_ipc_disconnected")
            data.extend(block)
        return bytes(data)

    def read_frame(self):
        length = struct.unpack("<I", self._read(4))[0]
        if not 0 < length <= MAX_FRAME:
            fail("companion_invalid_response")
        return self._read(length)


def build_request(args, stdin):
    if not digest(args.request_id):
        fail("companion_invalid_request")
    if args.command in ("preflight", "refresh", "reserve", "run"):
        if args.profile_id is None or args.profile_id <= 0 or not args.project or len(args.project) > 4096 or any(c in args.project for c in "\0\r\n"):
            fail("companion_invalid_scope")
        selector = {"profileId": args.profile_id, "project": args.project}
    if args.command in ("preflight", "refresh"):
        method = {"kind": args.command, "selector": selector}
    elif args.command in ("reserve", "run"):
        raw = stdin.read(65537)
        if not raw or len(raw) > 65536:
            fail("companion_invalid_prompt")
        try:
            prompt = raw.decode("utf-8")
        except UnicodeError:
            fail("companion_invalid_prompt")
        if not prompt.strip() or "\0" in prompt:
            fail("companion_invalid_prompt")
        method = {"kind": args.command, "intent": {"selector": selector, "prompt": prompt, "model": None, "effort": None, "tier": None}}
        if args.command == "run":
            if not digest(args.lease_id):
                fail("companion_invalid_lease")
            method["leaseId"] = args.lease_id
    elif args.command == "status":
        if not digest(args.operation_id):
            fail("companion_invalid_request")
        method = {"kind": "status", "operationId": args.operation_id}
    else:
        if not digest(args.lease_id):
            fail("companion_invalid_lease")
        method = {"kind": "cancelReservation", "leaseId": args.lease_id}
    return {"abi": ABI, "requestId": args.request_id, "method": method}


def main():
    parser = argparse.ArgumentParser(description="Explicit existing-App Companion IPC; prompts use stdin. No App/model is started by this client.")
    parser.add_argument("command", choices=("preflight", "refresh", "reserve", "run", "status", "cancel-reservation"))
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--profile-id", type=int)
    parser.add_argument("--project")
    parser.add_argument("--lease-id")
    parser.add_argument("--operation-id")
    args = parser.parse_args()
    transport = None
    try:
        request = build_request(args, sys.stdin.buffer)
        config = Path(__file__).absolute().parent.parent / "config" / "runtime-paths.json"
        transport = WinTransport(config, args.request_id)
        result = invoke_once(transport, request)
        print(json.dumps({"requestId": args.request_id, "result": result}, separators=(",", ":")))
        return 3 if result["state"] == "unknown" else 0
    except (ClientError, OSError, ValueError, TypeError):
        # No raw Win32 message, path, prompt, token or peer payload in output.
        print(json.dumps({"requestId": args.request_id, "issueCode": "companion_client_unavailable"}, separators=(",", ":")))
        return 2
    finally:
        if transport is not None:
            transport.close()


if __name__ == "__main__":
    raise SystemExit(main())
