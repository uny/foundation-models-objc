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
@objc public class AFMLanguageModelSession: NSObject {
    private let session: LanguageModelSession

    // The in-flight generation, retained so cancel()/close() can stop it. Foundation
    // Models honors Task cancellation (respond/streamResponse throw CancellationError),
    // so cancelling frees the device instead of running an abandoned generation to
    // completion. Manual completion handlers (rather than `async throws`) are used so we
    // own this Task and can cancel it from outside the calling coroutine.
    private var task: Task<Void, Never>?

    // task is written from the calling thread (respond/streamResponse) and read/cleared
    // from another thread via cancel()/close() — a Kotlin coroutine's cancellation handler
    // runs off-thread. Guard every access so the cross-thread reads/writes are not a race.
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
        let newTask = Task {
            do {
                let response = try await session.respond(to: prompt, options: options)
                completion(response.content, nil)
            } catch {
                completion(nil, error)
            }
        }
        withLock { task = newTask }
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
        let newTask = Task {
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
        withLock { task = newTask }
    }

    /// Cancels the in-flight generation. Foundation Models stops at the next token
    /// boundary and the pending respond()/streamResponse() completes with a
    /// CancellationError, which the caller discards on an already-cancelled call.
    @objc public func cancel() {
        withLock { task }?.cancel()
    }

    /// Cancels any in-flight generation and releases the session's retained Task.
    @objc public func close() {
        withLock {
            task?.cancel()
            task = nil
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
