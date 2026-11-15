import Foundation

public struct ClaudeReply: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ClaudeRunFailure: Error, Equatable, Sendable {
    case launch(String)
    case timedOut
}

/// 子プロセスを同期で実行する。呼び出し元のスレッドをふさぐので、主スレッドから呼ばない。
public enum ClaudeRunner {
    public static let timeout: TimeInterval = 30
    // 設計値。
    public static let killGrace: TimeInterval = 2
    static let drainWait: TimeInterval = 2

    /// 終了コードが 0 以外でも `ClaudeReply` を返す。
    public static func run(
        _ invocation: ClaudeInvocation,
        timeout: TimeInterval = ClaudeRunner.timeout,
        killGrace: TimeInterval = ClaudeRunner.killGrace
    ) -> Result<ClaudeReply, ClaudeRunFailure> {
        ProcessJob(invocation: invocation, timeout: timeout, killGrace: killGrace).execute()
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let finished = DispatchSemaphore(value: 0)

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.signal()
            } else {
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
            }
        }
    }

    /// 孫プロセスがパイプを握り続けても、終了後に待つのは `limit` 秒まで。
    func waitForEnd(limit: TimeInterval, pipe: Pipe) {
        _ = finished.wait(timeout: .now() + limit)
        pipe.fileHandleForReading.readabilityHandler = nil
    }
}

private final class ProcessJob: @unchecked Sendable {
    private let invocation: ClaudeInvocation
    private let timeout: TimeInterval
    private let killGrace: TimeInterval
    private let lock = NSLock()
    private var timedOut = false

    init(invocation: ClaudeInvocation, timeout: TimeInterval, killGrace: TimeInterval) {
        self.invocation = invocation
        self.timeout = timeout
        self.killGrace = killGrace
    }

    func execute() -> Result<ClaudeReply, ClaudeRunFailure> {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.directory
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = Collector(), err = Collector()
        out.attach(to: outPipe)
        err.attach(to: errPipe)

        do { try process.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.launch(error.localizedDescription))
        }

        let timer = DispatchWorkItem { [self] in
            lock.lock()
            timedOut = true
            lock.unlock()
            terminate(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        out.waitForEnd(limit: ClaudeRunner.drainWait, pipe: outPipe)
        err.waitForEnd(limit: ClaudeRunner.drainWait, pipe: errPipe)

        lock.lock()
        let wasTimedOut = timedOut
        lock.unlock()
        if wasTimedOut { return .failure(.timedOut) }
        return .success(ClaudeReply(exitCode: process.terminationStatus, stdout: out.data, stderr: err.data))
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
