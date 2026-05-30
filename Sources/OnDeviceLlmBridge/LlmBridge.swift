import Foundation
import FoundationModels

@objc public class OnDeviceLlmBridge: NSObject {
    private var session: LanguageModelSession?

    // The in-flight generation, retained so cancel()/close() can stop it. Foundation
    // Models honors Task cancellation (respond/streamResponse throw CancellationError),
    // so cancelling frees the device instead of running an abandoned generation to
    // completion. Manual completion handlers (rather than `async throws`) are used so we
    // own this Task and can cancel it from outside the Kotlin coroutine.
    private var task: Task<Void, Never>?

    // session/task are written from the calling coroutine thread (createSession,
    // generate) and read/cleared from another thread via cancel()/close() — the Kotlin
    // coroutine's cancellation handler runs off-thread. Guard every access so the
    // cross-thread reads/writes are not a data race.
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    @objc public static func isAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    @objc public func createSession(_ instructions: String?) {
        let newSession: LanguageModelSession
        if let instructions {
            newSession = LanguageModelSession {
                Instructions(instructions)
            }
        } else {
            newSession = LanguageModelSession()
        }
        withLock { session = newSession }
    }

    @objc public func generate(
        _ prompt: String,
        temperature: Double,
        maxTokens: Int32,
        completion: @escaping @Sendable (String?, Error?) -> Void
    ) {
        guard let session = withLock({ session }) else {
            completion(nil, Self.notInitialized)
            return
        }
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

    @objc public func streamGenerate(
        _ prompt: String,
        temperature: Double,
        maxTokens: Int32,
        onPartial: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard let session = withLock({ session }) else {
            completion(Self.notInitialized)
            return
        }
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

    // Cancels the in-flight generation. Foundation Models stops at the next token
    // boundary and the pending generate()/streamGenerate() completes with a
    // CancellationError, which the Kotlin side discards on an already-cancelled call.
    @objc public func cancel() {
        withLock { task }?.cancel()
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

    private static var notInitialized: NSError {
        NSError(
            domain: "dev.ynagai.ondevice",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Session not initialized"]
        )
    }

    @objc public func close() {
        withLock {
            task?.cancel()
            task = nil
            session = nil
        }
    }
}
