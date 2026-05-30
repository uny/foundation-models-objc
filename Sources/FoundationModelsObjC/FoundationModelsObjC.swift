import Foundation
import FoundationModels

/// `@objc` mirror of `FoundationModels.SystemLanguageModel`.
///
/// Exposes the on-device model's availability to Objective-C / Kotlin Native
/// consumers that cannot read the Swift-only original.
@objc public class AFMSystemLanguageModel: NSObject {
    /// Mirrors `SystemLanguageModel.default.isAvailable`.
    @objc public static func isAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }
}

/// `@objc` mirror of `FoundationModels.LanguageModelSession`.
///
/// Translates the Swift-only session API (`async`/`await`, `Instructions`,
/// streaming `AsyncSequence`) into completion-handler methods any non-Swift
/// consumer can bind to. Method names follow the Swift original
/// (`respond`, `streamResponse`).
///
/// All mutable state is guarded by `lock`, so the type is safe to drive from
/// several threads at once (hence `@unchecked Sendable`); `final` keeps that
/// guarantee from being broken by an unguarded subclass.
@objc public final class AFMLanguageModelSession: NSObject, @unchecked Sendable {
    private let session: LanguageModelSession

    // The in-flight generation, retained so cancel()/close() can stop it. Foundation
    // Models honors Task cancellation (respond/streamResponse throw CancellationError),
    // so cancelling frees the device instead of running an abandoned generation to
    // completion. Manual completion handlers (rather than `async throws`) are used so we
    // own this Task and can cancel it from outside the calling coroutine.
    private var task: Task<Void, Never>?

    // Monotonic id of the generation currently held in `task`. A finishing task only
    // clears `task` when its id still matches, so a generation that was already replaced
    // by a newer one (or by close()) can never clear the live task.
    private var generation: UInt64 = 0

    // task/generation are written from the calling thread (respond/streamResponse) and
    // read/cleared from other threads via cancel()/close() and each task's own completion
    // — a Kotlin coroutine's cancellation handler runs off-thread. Guard every access so
    // the cross-thread reads/writes are not a race.
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Cancels any previous generation and installs `work` as the session's single
    /// in-flight task. Cancelling the old task, bumping the generation, creating the Task
    /// and storing it all happen under one `lock` acquisition, so a concurrent
    /// cancel()/close() can never observe a half-installed task: it sees either the old
    /// generation or the new one, never the gap between creating and storing it. The task
    /// clears itself on completion (only while it is still current), so cancel() acts only
    /// on a genuinely running generation and the captured handlers are released promptly.
    private func start(_ work: @escaping @Sendable () async -> Void) {
        withLock {
            task?.cancel()
            generation &+= 1
            let id = generation
            task = Task { [weak self] in
                await work()
                self?.clearTask(id)
            }
        }
    }

    private func clearTask(_ id: UInt64) {
        withLock {
            if generation == id { task = nil }
        }
    }

    /// Mirrors `LanguageModelSession(instructions:)`. A nil [instructions] starts a
    /// session without system `Instructions`.
    @objc public init(instructions: String?) {
        if let instructions {
            session = LanguageModelSession {
                Instructions(instructions)
            }
        } else {
            session = LanguageModelSession()
        }
        super.init()
    }

    /// Mirrors `respond(to:options:)`. A negative [temperature] / non-positive
    /// [maxTokens] means "use the model default" (see [options]).
    @objc public func respond(
        to prompt: String,
        temperature: Double,
        maxTokens: Int32,
        completion: @escaping @Sendable (String?, Error?) -> Void
    ) {
        let session = self.session
        let options = Self.options(temperature: temperature, maxTokens: maxTokens)
        start {
            do {
                let response = try await session.respond(to: prompt, options: options)
                completion(response.content, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    /// Mirrors `streamResponse(to:options:)`. [onPartial] receives the framework's
    /// **cumulative** snapshots (callers diff for deltas).
    @objc public func streamResponse(
        to prompt: String,
        temperature: Double,
        maxTokens: Int32,
        onPartial: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let session = self.session
        let options = Self.options(temperature: temperature, maxTokens: maxTokens)
        start {
            do {
                let stream = session.streamResponse(to: prompt, options: options)
                for try await partial in stream {
                    onPartial(partial.content)
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Cancels the in-flight generation. Foundation Models stops at the next token
    /// boundary and the pending respond()/streamResponse() completes with a
    /// CancellationError, which the caller discards on an already-cancelled call.
    @objc public func cancel() {
        withLock { task }?.cancel()
    }

    /// Cancels any in-flight generation and releases the session's retained Task. Bumping
    /// the generation invalidates that task's pending self-clear, so it cannot race a
    /// later start().
    @objc public func close() {
        withLock {
            task?.cancel()
            task = nil
            generation &+= 1
        }
    }

    // Kotlin cannot pass optional primitives across the @objc boundary, so a
    // negative temperature / non-positive maxTokens encodes "unset" → use the
    // Foundation Models default for that field.
    private static func options(temperature: Double, maxTokens: Int32) -> GenerationOptions {
        GenerationOptions(
            temperature: temperature >= 0 ? temperature : nil,
            maximumResponseTokens: maxTokens > 0 ? Int(maxTokens) : nil
        )
    }
}
