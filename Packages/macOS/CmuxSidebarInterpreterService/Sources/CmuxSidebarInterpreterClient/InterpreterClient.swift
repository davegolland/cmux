import CmuxSwiftRender
import Foundation

/// Supervises an out-of-process ``RenderInterpreterRunner`` worker and renders
/// untrusted sidebar source through it, so an interpreter crash, hang, or
/// runaway never takes down the host.
///
/// The host calls ``render(source:state:)``; the request is encoded and sent to
/// a worker process (the `cmux-sidebar-interpreter` executable), which replies
/// with a ``RenderNode``. If the worker crashes (its pipe closes) or fails to
/// answer within `timeout`, the call returns `nil` and the worker is relaunched
/// on the next render. Responses are correlated by id, so concurrent renders
/// are safe.
///
/// ```swift
/// let client = InterpreterClient(executableURL: workerURL)
/// let node = await client.render(source: source, state: dataContext)
/// // node == nil  ⇒  show the sidebar's error/empty state
/// ```
public actor InterpreterClient {
    /// A canceled render cannot be withdrawn from the worker's pipe. Keep the
    /// number of outstanding requests bounded, then terminate the worker when
    /// cancellation removes an in-flight request so hostile work cannot stay
    /// queued until every caller's timeout.
    nonisolated static let maximumInFlightRequests = 64

    /// Location of the worker executable (bundled in the app, injected in tests).
    nonisolated let executableURL: URL
    /// Extra environment for the worker process (used by tests for fault injection).
    nonisolated let extraEnvironment: [String: String]
    /// How long to wait for a single response before terminating the worker.
    nonisolated let timeout: Duration
    /// Arguments passed to the worker process (e.g. the worker-mode flag when
    /// re-executing the host app binary).
    nonisolated let arguments: [String]

    private var child: Child?
    private var generation: Int = 0
    private var nextID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<InterpreterResponse?, Never>] = [:]

    /// Creates a client that launches `executableURL` on demand.
    ///
    /// - Parameters:
    ///   - executableURL: The worker binary to run.
    ///   - timeout: Per-render deadline; on expiry the worker is killed and the
    ///     render returns `nil`. Defaults to 2 seconds.
    ///   - arguments: Arguments for the worker process (defaults to none; the
    ///     re-exec-self factory passes the worker-mode flag).
    ///   - extraEnvironment: Additional environment for the worker process.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        timeout: Duration = .seconds(2),
        environment extraEnvironment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = RenderWorkerDeadline.clamp(timeout)
        self.extraEnvironment = extraEnvironment
    }

    /// Renders `source` against `state` in the worker process.
    ///
    /// - Returns: the interpreted ``RenderNode``, or `nil` if the worker
    ///   produced no view, crashed, or timed out. Never throws and never
    ///   crashes the host regardless of what the source does.
    public func render(source: String, state: [String: SwiftValue]) async -> RenderNode? {
        guard !Task.isCancelled else { return nil }
        let id = nextID
        nextID &+= 1
        let request = InterpreterRequest(id: id, source: source, state: state)
        guard request.isWithinSecurityLimits() else { return nil }
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        guard data.count <= LengthPrefixedMessageChannel.maximumFrameLength else { return nil }
        guard waiters.count < Self.maximumInFlightRequests else { return nil }

        let writer: RenderWorkerWritePump
        let workerGeneration: Int
        do {
            (writer, workerGeneration) = try ensureRunning()
        } catch {
            return nil
        }

        let outbound = RenderWorkerOutboundWrite(
            data: data,
            remainingRelaunches: 0,
            ackSequence: nil
        )

        // Bounded, cancellable deadline: if no reply lands in `timeout`, fail
        // this waiter and terminate the worker (its closing pipe ends the
        // reader). This is a genuine timeout, not a poll/settle. The waiter is
        // registered before enqueueing so a fast worker response cannot race
        // and get discarded.
        let deadline = timeout
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self else { return }
            await self.timedOut(id: id)
        }
        defer { watchdog.cancel() }

        let client = self
        let response = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<InterpreterResponse?, Never>) in
                // Cancellation can race the operation closure before it gets
                // onto this actor. Do not install a waiter for an already
                // canceled task.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waiters[id] = continuation
                let accepted = writer.enqueue(outbound) { [weak self] in
                    guard let self else { return }
                    Task { await self.writeFailed(id: id, generation: workerGeneration) }
                }
                if !accepted {
                    // Queue overflow or a failed writer is a worker failure. Resume
                    // this caller now; the callback may not run for a rejected
                    // enqueue.
                    let waiter = waiters.removeValue(forKey: id)
                    waiter?.resume(returning: nil)
                    if workerGeneration == generation {
                        discardWorker()
                    }
                }
            }
        }, onCancel: {
            Task { [client, id] in
                await client.cancelRequest(id: id)
            }
        })
        guard let response, response.id == id else { return nil }
        return response.node
    }

    /// Terminates the worker and fails any in-flight renders. Call from the
    /// owner's teardown (e.g. when the sidebar disappears).
    public func shutdown() {
        discardWorker()
        failAllWaiters()
    }

    // MARK: - Worker lifecycle

    private func ensureRunning() throws -> (RenderWorkerWritePump, Int) {
        if let child, child.process.isRunning {
            return (child.writer, child.generation)
        }
        return try launch()
    }

    private func launch() throws -> (RenderWorkerWritePump, Int) {
        generation &+= 1
        let gen = generation

        let process = Process()
        process.executableURL = executableURL
        if !arguments.isEmpty { process.arguments = arguments }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.environment = SidebarWorkerEnvironment.make(extra: extraEnvironment)

        let channel = try LengthPrefixedMessageChannel(
            readFD: stdout.fileHandleForReading.fileDescriptor,
            writeFD: stdin.fileHandleForWriting.fileDescriptor
        )
        let writer = RenderWorkerWritePump(
            channel: channel,
            generation: gen,
            writeTimeout: timeout
        )
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.workerEnded(generation: gen) }
        }

        try process.run()
        // The host owns stdin's write end and stdout's read end. Keeping the
        // other parent copies open would hide worker EOF/EPIPE from the
        // channel, and a crashed worker could then strand its reader thread.
        // Close them as soon as the child has inherited its endpoints.
        do {
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
        } catch {
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
        child = Child(
            process: process,
            channel: channel,
            writer: writer,
            generation: gen,
            stdin: stdin,
            stdout: stdout
        )

        // Reader thread: blocks draining framed responses off the worker's
        // stdout descriptor and hands each to the actor. The channel is fd-
        // backed and Sendable; FileHandle is not, so we never capture it.
        let readChannel = channel
        let reader = Thread { [weak self] in
            var invalidFrameCount = 0
            while let data = readChannel.receiveMessage() {
                guard JSONFrameGuard.isBounded(data),
                      let response = try? JSONDecoder().decode(InterpreterResponse.self, from: data),
                      response.isWithinSecurityLimits() else {
                    invalidFrameCount += 1
                    if invalidFrameCount >= JSONFrameGuard.maximumConsecutiveInvalidFrames {
                        Task { [weak self] in
                            await self?.protocolViolation(generation: gen)
                        }
                        break
                    }
                    continue
                }
                invalidFrameCount = 0
                Task { [weak self] in
                    guard let self else { return }
                    await self.deliver(response, generation: gen)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                await self.workerEnded(generation: gen)
            }
        }
        reader.stackSize = 1 << 20
        reader.name = "cmux-sidebar-interpreter-reader"
        reader.start()

        return (writer, gen)
    }

    private func deliver(_ response: InterpreterResponse, generation gen: Int) {
        guard gen == generation else { return } // ignore a superseded worker
        waiters.removeValue(forKey: response.id)?.resume(returning: response)
    }

    private func protocolViolation(generation gen: Int) {
        guard gen == generation else { return }
        // A peer that repeatedly emits invalid frames is not making progress.
        // Drop it so the next request gets a clean worker instead of spending
        // an unbounded amount of CPU in the reader loop.
        discardWorker()
    }

    private func timedOut(id: UInt64) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        // Discard the worker synchronously (not just terminate and wait for the
        // async termination handler) so the next render relaunches a fresh one
        // instead of reusing the dying process.
        discardWorker()
    }

    /// Called by the write pump when the worker pipe is broken or a write
    /// deadline expires. This runs independently of the actor's render call,
    /// so a full pipe cannot park the actor and prevent recovery.
    private func writeFailed(id: UInt64, generation gen: Int) {
        guard gen == generation else { return }
        waiters.removeValue(forKey: id)?.resume(returning: nil)
        discardWorker()
    }

    /// A worker has no cancellation message. Closing the generation is the
    /// only way to stop a canceled request that is already being interpreted.
    private func cancelRequest(id: UInt64) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        discardWorker()
    }

    /// Terminates the current worker and forgets it, so ``ensureRunning()``
    /// relaunches on the next render. The old worker's reader/termination
    /// handler run under its now-stale generation and no-op.
    private func discardWorker() {
        generation &+= 1
        if let doomed = child {
            doomed.writer.cancel()
            try? doomed.stdin.fileHandleForWriting.close()
            // Closing the read descriptor also wakes a reader that is blocked
            // in receiveMessage while the terminated worker is being reaped.
            try? doomed.stdout.fileHandleForReading.close()
            if doomed.process.isRunning {
                doomed.process.terminate()
            }
        }
        child = nil
        // Any other requests were sent to the same serial worker and cannot
        // complete after its generation is discarded. Resume them now instead
        // of retaining continuations until their independent deadlines.
        failAllWaiters()
    }

    private func workerEnded(generation gen: Int) {
        guard gen == generation else { return }
        if let ended = child {
            ended.writer.cancel()
            try? ended.stdin.fileHandleForWriting.close()
            try? ended.stdout.fileHandleForReading.close()
        }
        child = nil
        failAllWaiters()
    }

    private func failAllWaiters() {
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: nil)
        }
    }
}

/// A running worker process and the channel/pipes that feed it. Held only by
/// the ``InterpreterClient`` actor, so its non-`Sendable` members are safe.
private struct Child {
    let process: Process
    let channel: LengthPrefixedMessageChannel
    let writer: RenderWorkerWritePump
    let generation: Int
    let stdin: Pipe
    let stdout: Pipe
}
