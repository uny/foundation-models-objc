import Foundation
import FoundationModels
import os

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
@objc public final class AFMLanguageModelSession: NSObject {
    // The in-flight generation, retained so cancel()/close() can stop it, plus a monotonic
    // id of the generation currently held. Foundation Models honors Task cancellation
    // (respond/streamResponse throw CancellationError), so cancelling frees the device
    // instead of running an abandoned generation to completion. Manual completion handlers
    // (rather than `async throws`) let us own this Task and cancel it from outside the
    // calling coroutine.
    private struct State {
        var task: Task<Void, Never>?
        var generation: UInt64 = 0
    }

    private let session: LanguageModelSession

    // State is written from the calling thread (respond/streamResponse) and read/cleared
    // from other threads via cancel()/close() and each task's own completion — a Kotlin
    // coroutine's cancellation handler runs off-thread. The lock serializes every access
    // so the cross-thread reads/writes are not a race. OSAllocatedUnfairLock is Sendable
    // and shares its storage across copies, so the completion task clears its slot by
    // capturing `lock` rather than `self` — which keeps this type honestly thread-safe
    // without an `@unchecked Sendable` escape hatch.
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Cancels any previous generation and installs `work` as the session's single
    /// in-flight task. Reading the previous task, bumping the generation, creating the new
    /// Task and storing it all happen under one lock acquisition, so a concurrent
    /// cancel()/close() never observes a half-installed task — it sees the old generation
    /// or the new one, never the gap between creating and storing it. The previous task is
    /// cancelled *outside* the lock, because a cancellation handler can run arbitrary work
    /// and must not run under an unfair lock. The task clears itself on completion, but
    /// only while it is still the current generation, so a replaced task can't clear a
    /// live one.
    private func start(_ work: @escaping @Sendable () async -> Void) {
        // Bind the shared lock to a local (its storage is shared across copies) so the
        // completion task captures `lock` by value instead of `self`.
        let lock = self.lock
        let previous = lock.withLock { state -> Task<Void, Never>? in
            let previous = state.task
            state.generation &+= 1
            let id = state.generation
            state.task = Task {
                await work()
                lock.withLock { if $0.generation == id { $0.task = nil } }
            }
            return previous
        }
        previous?.cancel()
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

    /// Mirrors `LanguageModelSession.prewarm()` — loads the model into memory so the
    /// next respond()/streamResponse() avoids the cold-start cost. Best-effort,
    /// synchronous, no-op-safe, and safe to call repeatedly.
    ///
    /// It does not go through start(_:) (that machinery is only for cancellable
    /// in-flight generations) and does not touch the in-flight State/lock, so it is
    /// safe to call alongside or between generations.
    @objc public func prewarm() {
        session.prewarm()
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
        lock.withLock { $0.task }?.cancel()
    }

    /// Cancels any in-flight generation and releases the session's retained Task. Bumping
    /// the generation invalidates that task's pending self-clear so it can't race a later
    /// start(); the cancel runs outside the lock for the same reason as in start().
    @objc public func close() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            let task = state.task
            state.task = nil
            state.generation &+= 1
            return task
        }
        task?.cancel()
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
