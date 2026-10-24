import Darwin
import Foundation

// Read-only follower of the desktop app's local IPC state stream (protocol v11).
// No task-start, interrupt, approval-decision, authentication or config requests are sent.
final class LiveStatusClient: @unchecked Sendable {
    let queue: DispatchQueue
    let socketPath: String
    var fd: Int32 = -1
    var input = Data()
    var output = Data()
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var retry: DispatchWorkItem?
    var handshake: DispatchWorkItem?
    var clientID: String?
    var stopped = false
    var backoff: Double = 1
    var followed = Set<String>()
    var states: [String: [String: Any]] = [:]
    var revisions: [String: Int] = [:]
    var owners: [String: String] = [:]
    var onChange: (() -> Void)?
    var connected: Bool { clientID != nil }
    init(
        queue: DispatchQueue,
        socketPath: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".codex/ipc/ipc.sock"
        ).path
    ) {
        self.queue = queue
        self.socketPath = socketPath
    }
    func start() {
        stopped = false
        connect()
    }
    func connect() {
        guard !stopped, fd < 0 else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            scheduleReconnect()
            return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (i, byte) in bytes.enumerated() { destination[i] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            scheduleReconnect()
            return
        }
        fd = descriptor
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader = source
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.activate()
        send([
            "type": "request", "requestId": UUID().uuidString, "sourceClientId": "initializing-client",
            "method": "initialize", "version": 0, "params": ["clientType": "codex-tasklight-observer"],
        ])
        let timeout = DispatchWorkItem { [weak self] in if self?.clientID == nil { self?.disconnect() } }
        handshake = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }
    func follow(_ ids: Set<String>) {
        let removed = followed.subtracting(ids)
        let added = ids.subtracting(followed)
        followed = ids
        for id in removed {
            announce(id, following: false)
            states[id] = nil
            revisions[id] = nil
            owners[id] = nil
        }
        for id in added { announce(id, following: true) }
    }
    func announce(_ id: String, following: Bool) {
        guard let clientID else { return }
        send([
            "type": "broadcast", "sourceClientId": clientID, "method": "thread-stream-following-changed", "version": 1,
            "params": ["conversationId": id, "hostId": "local", "following": following],
        ])
    }
    func send(_ message: [String: Any]) {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: message), body.count < 1_048_576 else {
            return
        }
        var size = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        output.append(body)
        flush()
    }
    func flush() {
        while !output.isEmpty && fd >= 0 {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count > 0 {
                output.removeFirst(count)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    writer = source
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.activate()
                }
                return
            } else {
                disconnect()
                return
            }
        }
        writer?.cancel()
        writer = nil
    }
    func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while fd >= 0 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                input.append(contentsOf: buffer.prefix(count))
                guard consumeFrames() else {
                    disconnect()
                    return
                }
            } else if count == 0 {
                disconnect()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                disconnect()
                return
            }
        }
    }
    func consumeFrames() -> Bool {
        while input.count >= 4 {
            let prefix = Array(input.prefix(4))
            let length = Int(
                UInt32(prefix[0]) | UInt32(prefix[1]) << 8 | UInt32(prefix[2]) << 16 | UInt32(prefix[3]) << 24)
            guard length > 0 && length <= 67_108_864 else { return false }
            guard input.count >= 4 + length else { return true }
            let body = Data(input.dropFirst(4).prefix(length))
            input.removeFirst(4 + length)
            guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
            receive(message)
        }
        return true
    }
    func receive(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let method = message["method"] as? String ?? ""
        if type == "response", method == "initialize", let result = message["result"] as? [String: Any],
            let id = result["clientId"] as? String
        {
            clientID = id
            backoff = 1
            handshake?.cancel()
            handshake = nil
            for thread in followed { announce(thread, following: true) }
            onChange?()
            return
        }
        if type == "client-discovery-request", let id = message["requestId"] {
            send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            return
        }
        guard type == "broadcast", let params = message["params"] as? [String: Any] else { return }
        if method == "client-status-changed", params["clientId"] as? String != clientID {
            if params["status"] as? String == "connected" {
                for thread in followed { announce(thread, following: true) }
            } else if let owner = params["clientId"] as? String, params["status"] as? String == "disconnected" {
                for id in Array(owners.keys) where owners[id] == owner {
                    states[id] = nil
                    revisions[id] = nil
                    owners[id] = nil
                }
                onChange?()
            }
            return
        }
        guard method == "thread-stream-state-changed", message["version"] as? Int == 11,
            params["hostId"] as? String == "local", let id = params["conversationId"] as? String, followed.contains(id),
            let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int
        else { return }
        let owner = message["sourceClientId"] as? String
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            let fields = Set(["threadRuntimeStatus", "requests", "externalRequests", "threadGoalResumeConfirmation"])
            states[id] = state.filter { fields.contains($0.key) }
            revisions[id] = revision
            owners[id] = owner
        } else if change["type"] as? String == "patches", let patches = change["patches"] as? [[String: Any]] {
            guard let base = change["baseRevision"] as? Int, base == revisions[id], owners[id] == owner,
                var state = states[id]
            else {
                states[id] = nil
                revisions[id] = nil
                announce(id, following: true)
                onChange?()
                return
            }
            do {
                for patch in patches {
                    guard let path = patch["path"] as? [Any], let field = path.first as? String,
                        ["threadRuntimeStatus", "requests", "externalRequests", "threadGoalResumeConfirmation"]
                            .contains(field)
                    else { continue }
                    state = try StatePatch.apply(
                        state, path: path, operation: patch["op"] as? String ?? "", value: patch["value"])
                }
                states[id] = state
                revisions[id] = revision
            } catch {
                states[id] = nil
                revisions[id] = nil
                announce(id, following: true)
            }
        } else {
            return
        }
        onChange?()
    }
    func reading(for id: String, fallback: Reading) -> Reading {
        if !fallback.pendingQuestionIDs.isEmpty { return fallback.expiring() }
        guard connected else { return Reading(detail: "实时状态连接中，暂时无法确认是否等待审批") }
        guard let state = states[id] else {
            if fallback.state == .running || fallback.state == .waiting { return Reading(detail: "等待桌面端的实时状态快照") }
            return fallback
        }
        return Self.derive(state, fallback: fallback)
    }
    static func derive(_ state: [String: Any], fallback: Reading) -> Reading {
        if !fallback.pendingQuestionIDs.isEmpty { return fallback.expiring() }
        let status = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        let flags = status["activeFlags"] as? [String] ?? []
        let pending =
            ((state["requests"] as? [[String: Any]] ?? []) + (state["externalRequests"] as? [[String: Any]] ?? []))
            .contains { request in
                if request["completed"] as? Bool == true || request["resolved"] as? Bool == true
                    || request["completedAtMs"] is NSNumber
                {
                    return false
                }
                let method = request["method"] as? String ?? ""
                return [
                    "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                    "item/permissions/requestApproval", "item/tool/requestUserInput", "tool/requestUserInput",
                    "mcpServer/elicitation/request", "execCommandApproval", "applyPatchApproval",
                ].contains(method)
            }
        if pending || flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") {
            return Reading(state: .waiting, lastEvent: fallback.lastEvent, detail: "等待你确认或审批，处理后会自动恢复")
        }
        switch status["type"] as? String {
        case "active": return Reading(state: .running, lastEvent: fallback.lastEvent, detail: "实时状态：正在执行")
        case "idle":
            // Idle only means execution stopped; the log carries its outcome.
            if fallback.state == .failed { return fallback }
            return Reading(state: .completed, lastEvent: fallback.lastEvent, detail: "实时状态：本轮已结束")
        case "systemError":
            return Reading(state: .failed, lastEvent: fallback.lastEvent, detail: "实时状态：任务异常，请在 Codex 查看")
        default: return fallback
        }
    }
    func disconnect() {
        handshake?.cancel()
        handshake = nil
        writer?.cancel()
        writer = nil
        if let reader { reader.cancel() } else if fd >= 0 { close(fd) }
        reader = nil
        fd = -1
        input.removeAll()
        output.removeAll()
        clientID = nil
        states.removeAll()
        revisions.removeAll()
        owners.removeAll()
        onChange?()
        scheduleReconnect()
    }
    func scheduleReconnect() {
        guard !stopped, retry == nil else { return }
        let job = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.connect()
        }
        retry = job
        queue.asyncAfter(deadline: .now() + backoff, execute: job)
        backoff = min(30, backoff * 2)
    }
    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        for id in followed { announce(id, following: false) }
        disconnect()
    }
}

enum StatePatch {
    static func apply(_ object: [String: Any], path: [Any], operation: String, value: Any?) throws -> [String: Any] {
        guard
            let result = try edit(object, path: ArraySlice(path), operation: operation, value: value) as? [String: Any]
        else { throw CocoaError(.coderInvalidValue) }
        return result
    }
    private static func edit(_ node: Any, path: ArraySlice<Any>, operation: String, value: Any?) throws -> Any {
        guard let head = path.first else {
            guard operation == "add" || operation == "replace", let value else { throw CocoaError(.coderInvalidValue) }
            return value
        }
        let tail = path.dropFirst()
        if var dictionary = node as? [String: Any], let key = head as? String {
            if tail.isEmpty {
                if operation == "remove" {
                    dictionary.removeValue(forKey: key)
                } else if operation == "add" || operation == "replace", let value {
                    dictionary[key] = value
                } else {
                    throw CocoaError(.coderInvalidValue)
                }
            } else {
                guard let child = dictionary[key] else { throw CocoaError(.coderInvalidValue) }
                dictionary[key] = try edit(child, path: tail, operation: operation, value: value)
            }
            return dictionary
        }
        if var array = node as? [Any] {
            let index = (head as? Int) ?? (head as? String).flatMap(Int.init)
            guard let index, index >= 0 else { throw CocoaError(.coderInvalidValue) }
            if tail.isEmpty && operation == "add", index <= array.count, let value {
                array.insert(value, at: index)
                return array
            }
            guard index < array.count else { throw CocoaError(.coderInvalidValue) }
            if tail.isEmpty && operation == "remove" {
                array.remove(at: index)
            } else {
                array[index] = try edit(array[index], path: tail, operation: operation, value: value)
            }
            return array
        }
        throw CocoaError(.coderInvalidValue)
    }
}
