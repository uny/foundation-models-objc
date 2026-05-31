import Foundation
import FoundationModels
import os

/// Availability of the on-device model, mirroring `SystemLanguageModel.Availability`.
///
/// Kotlin cannot read the Swift enum with its associated `UnavailableReason`, so the
/// reason is flattened into distinct cases. `.available` means generation can proceed;
/// every other case is a reason the model is currently unusable.
@objc public enum AFMModelAvailability: Int {
    case available = 0
    case unavailableDeviceNotEligible = 1
    case unavailableAppleIntelligenceNotEnabled = 2
    case unavailableModelNotReady = 3
    /// A reason added by a future OS that this wrapper does not yet map.
    case unavailableUnknown = 4
}

/// Specialization of the base model, mirroring `SystemLanguageModel.UseCase`.
@objc public enum AFMUseCase: Int {
    case general = 0
    case contentTagging = 1
}

/// How the model samples tokens, mirroring `GenerationOptions.SamplingMode`.
///
/// `.greedy` is deterministic. `.topK` / `.nucleus` read the matching field on
/// `AFMGenerationOptions` (`samplingTopK` / `samplingProbabilityThreshold`).
@objc public enum AFMSamplingMode: Int {
    /// Leave sampling unset — the model picks its default strategy.
    case `default` = 0
    /// Always choose the most likely token.
    case greedy = 1
    /// Sample from a fixed number of the highest-probability tokens (`samplingTopK`).
    case topK = 2
    /// Nucleus sampling over a probability mass threshold (`samplingProbabilityThreshold`).
    case nucleus = 3
}

/// Stable error codes for failures surfaced by `respond`/`streamResponse`, mapped from
/// `LanguageModelSession.GenerationError` (whose Swift cases Kotlin cannot switch on).
///
/// Errors are delivered as `NSError` in `AFMLanguageModelSession.errorDomain` with one of
/// these `code` values; the original framework error is preserved under
/// `NSUnderlyingErrorKey` and its message under `NSLocalizedDescriptionKey`.
@objc public enum AFMGenerationErrorCode: Int {
    /// Not a `GenerationError` (or a case added by a future OS).
    case unknown = 0
    /// The in-flight generation was cancelled (`CancellationError`).
    case cancelled = 1
    case exceededContextWindowSize = 2
    case assetsUnavailable = 3
    case guardrailViolation = 4
    case unsupportedGuide = 5
    case unsupportedLanguageOrLocale = 6
    case decodingFailure = 7
    case rateLimited = 8
    case concurrentRequests = 9
    case refusal = 10
}

/// `@objc` mirror of `FoundationModels.GenerationOptions`.
///
/// A reference type so it crosses the `@objc` boundary as one argument and stays
/// extensible. Sentinel defaults encode "unset" the same way the primitive
/// `respond(to:temperature:maxTokens:completion:)` overload does: a negative
/// `temperature` / non-positive `maximumResponseTokens` means "use the model default".
@objc public final class AFMGenerationOptions: NSObject {
    /// Negative → use the model default.
    @objc public var temperature: Double = -1
    /// Non-positive → use the model default.
    @objc public var maximumResponseTokens: Int = 0
    @objc public var samplingMode: AFMSamplingMode = .default
    /// Number of candidate tokens for `.topK`. Must be >= 1; an unset/invalid value
    /// (< 1) falls back to the model's default sampling rather than silently
    /// collapsing to greedy (top-1). The fallback is logged (see `resolved()`).
    @objc public var samplingTopK: Int = 0
    /// Probability mass for `.nucleus`, in (0, 1]. An unset/out-of-range value falls
    /// back to the model's default sampling. The fallback is logged.
    @objc public var samplingProbabilityThreshold: Double = 0
    /// Seed for reproducible sampling; negative → no fixed seed.
    @objc public var samplingSeed: Int64 = -1

    @objc public override init() {
        super.init()
    }

    // Primitive-overload form: the respond(to:temperature:maxTokens:) family builds an
    // options object so the sentinel-means-default convention lives in one place
    // (options(from:)). A negative temperature / non-positive maxTokens stays "unset".
    fileprivate convenience init(temperature: Double, maxTokens: Int32) {
        self.init()
        self.temperature = temperature
        self.maximumResponseTokens = Int(maxTokens)
    }

    // UInt64? form of samplingSeed for GenerationOptions.SamplingMode (negative → nil).
    private var seedValue: UInt64? {
        samplingSeed >= 0 ? UInt64(samplingSeed) : nil
    }

    // Diagnostics for caller-side option mistakes that are intentionally tolerated
    // (e.g. a sampling mode requested without its companion field). resolved() can't
    // throw across the synchronous @objc boundary, so a silently-ignored request is
    // logged instead of failing — otherwise it's an undebuggable "my top-k/seed had no
    // effect" downstream.
    private static let log = Logger(subsystem: "FoundationModelsObjC", category: "AFMGenerationOptions")

    // Translates this @objc options object into the framework type, applying the
    // sentinel-means-default convention (Kotlin cannot pass optional primitives across
    // the @objc boundary, so a negative temperature / non-positive maxTokens encodes
    // "unset" → use the Foundation Models default) and mapping the sampling enum to
    // SamplingMode. A mode whose required companion field is unset/out-of-range falls
    // back to the model's default sampling rather than passing an invalid value or
    // silently degenerating to greedy.
    func resolved() -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode?
        switch samplingMode {
        case .default:
            sampling = nil
        case .greedy:
            sampling = .greedy
        case .topK:
            if samplingTopK >= 1 {
                sampling = .random(top: samplingTopK, seed: seedValue)
            } else {
                Self.log.error("samplingMode .topK ignored: samplingTopK (\(self.samplingTopK)) must be >= 1; using model default sampling")
                sampling = nil
            }
        case .nucleus:
            if samplingProbabilityThreshold > 0 && samplingProbabilityThreshold <= 1 {
                sampling = .random(probabilityThreshold: samplingProbabilityThreshold, seed: seedValue)
            } else {
                Self.log.error("samplingMode .nucleus ignored: samplingProbabilityThreshold (\(self.samplingProbabilityThreshold)) must be in (0, 1]; using model default sampling")
                sampling = nil
            }
        }
        return GenerationOptions(
            sampling: sampling,
            temperature: temperature >= 0 ? temperature : nil,
            maximumResponseTokens: maximumResponseTokens > 0 ? maximumResponseTokens : nil
        )
    }
}

/// `@objc` mirror of `FoundationModels.SystemLanguageModel`.
///
/// Exposes the on-device model's availability and metadata to Objective-C / Kotlin Native
/// consumers that cannot read the Swift-only original. Everything here targets
/// `SystemLanguageModel.default`.
@objc public class AFMSystemLanguageModel: NSObject {
    /// Mirrors `SystemLanguageModel.default.isAvailable` — true only when generation can
    /// proceed right now. Use `availability()` for the reason when this is false.
    @objc public static func isAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Mirrors `SystemLanguageModel.default.availability`, flattened so the unavailable
    /// reason survives the `@objc` boundary.
    @objc public static func availability() -> AFMModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailableDeviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailableAppleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .unavailableModelNotReady
        @unknown default: return .unavailableUnknown
        }
    }

    /// Mirrors `SystemLanguageModel.default.supportedLanguages`, projected to BCP-47
    /// identifiers (`Locale.Language` does not cross the `@objc` boundary). Sorted for a
    /// stable order.
    @objc public static func supportedLanguageIdentifiers() -> [String] {
        SystemLanguageModel.default.supportedLanguages.map { $0.minimalIdentifier }.sorted()
    }

    /// Mirrors `SystemLanguageModel.default.supportsLocale(_:)`. [identifier] is a BCP-47
    /// locale identifier (e.g. "en-US").
    @objc public static func supportsLocale(_ identifier: String) -> Bool {
        SystemLanguageModel.default.supportsLocale(Locale(identifier: identifier))
    }
}

/// `@objc` mirror of `FoundationModels.LanguageModelSession`.
///
/// Translates the Swift-only session API (`async`/`await`, `Instructions`,
/// streaming `AsyncSequence`) into completion-handler methods any non-Swift
/// consumer can bind to. Method names follow the Swift original
/// (`respond`, `streamResponse`).
@objc public final class AFMLanguageModelSession: NSObject {
    /// Error domain for the `NSError`s delivered by `respond`/`streamResponse`. The
    /// `code` is an `AFMGenerationErrorCode` raw value.
    @objc public static let errorDomain = "AFMGenerationErrorDomain"

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
        session = Self.makeSession(model: .default, instructions: instructions)
        super.init()
    }

    /// Mirrors `LanguageModelSession(model:instructions:)` with a model built from a
    /// `SystemLanguageModel.UseCase` and guardrails. [permissiveGuardrails] selects
    /// `.permissiveContentTransformations` over the safe `.default`. A nil [instructions]
    /// starts the session without system `Instructions`.
    @objc public init(useCase: AFMUseCase, permissiveGuardrails: Bool, instructions: String?) {
        let modelUseCase: SystemLanguageModel.UseCase = useCase == .contentTagging ? .contentTagging : .general
        let guardrails: SystemLanguageModel.Guardrails = permissiveGuardrails ? .permissiveContentTransformations : .default
        let model = SystemLanguageModel(useCase: modelUseCase, guardrails: guardrails)
        session = Self.makeSession(model: model, instructions: instructions)
        super.init()
    }

    // Single construction path for both inits: only the model differs (the default model
    // vs. a UseCase/guardrails-specialized one), so the Instructions-or-not branch lives
    // in one place. `LanguageModelSession(model:)` with `.default` is equivalent to the
    // no-model initializer.
    private static func makeSession(model: SystemLanguageModel, instructions: String?) -> LanguageModelSession {
        if let instructions {
            return LanguageModelSession(model: model) {
                Instructions(instructions)
            }
        } else {
            return LanguageModelSession(model: model)
        }
    }

    /// Mirrors `LanguageModelSession.isResponding` — whether a generation is currently in
    /// flight. Read-only; safe to query from any thread.
    @objc public var isResponding: Bool {
        session.isResponding
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

    /// Mirrors `LanguageModelSession.prewarm(promptPrefix:)`. A nil [promptPrefix] behaves
    /// like `prewarm()`; otherwise the prefix is also cached so a follow-up generation
    /// that starts with it is faster.
    @objc public func prewarm(promptPrefix: String?) {
        if let promptPrefix {
            session.prewarm(promptPrefix: Prompt(promptPrefix))
        } else {
            session.prewarm()
        }
    }

    /// Mirrors `respond(to:options:)`. A negative [temperature] / non-positive
    /// [maxTokens] means "use the model default" (see [options]).
    @objc public func respond(
        to prompt: String,
        temperature: Double,
        maxTokens: Int32,
        completion: @escaping @Sendable (String?, Error?) -> Void
    ) {
        respond(to: prompt, options: AFMGenerationOptions(temperature: temperature, maxTokens: maxTokens), completion: completion)
    }

    /// Mirrors `respond(to:options:)` with the full `AFMGenerationOptions` (temperature,
    /// token cap, and sampling strategy).
    @objc public func respond(
        to prompt: String,
        options: AFMGenerationOptions,
        completion: @escaping @Sendable (String?, Error?) -> Void
    ) {
        respond(to: prompt, options: options.resolved(), completion: completion)
    }

    private func respond(
        to prompt: String,
        options: GenerationOptions,
        completion: @escaping @Sendable (String?, Error?) -> Void
    ) {
        let session = self.session
        start {
            do {
                let response = try await session.respond(to: prompt, options: options)
                completion(response.content, nil)
            } catch {
                completion(nil, Self.mapError(error))
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
        streamResponse(to: prompt, options: AFMGenerationOptions(temperature: temperature, maxTokens: maxTokens), onPartial: onPartial, completion: completion)
    }

    /// Mirrors `streamResponse(to:options:)` with the full `AFMGenerationOptions`.
    /// [onPartial] receives the framework's **cumulative** snapshots (callers diff for
    /// deltas).
    @objc public func streamResponse(
        to prompt: String,
        options: AFMGenerationOptions,
        onPartial: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        streamResponse(to: prompt, options: options.resolved(), onPartial: onPartial, completion: completion)
    }

    private func streamResponse(
        to prompt: String,
        options: GenerationOptions,
        onPartial: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let session = self.session
        start {
            do {
                let stream = session.streamResponse(to: prompt, options: options)
                for try await partial in stream {
                    onPartial(partial.content)
                }
                completion(nil)
            } catch {
                completion(Self.mapError(error))
            }
        }
    }

    /// Cancels the in-flight generation. Foundation Models stops at the next token
    /// boundary and the pending respond()/streamResponse() completes with an NSError in
    /// errorDomain whose code is AFMGenerationErrorCode.cancelled, which the caller
    /// discards on an already-cancelled call.
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

    // Maps framework errors to a stable NSError (AFMGenerationErrorCode) so Kotlin can
    // branch on the cause without reading Swift-only enum cases. The original error is
    // preserved under NSUnderlyingErrorKey and its message under NSLocalizedDescriptionKey.
    private static func mapError(_ error: Error) -> NSError {
        let code: AFMGenerationErrorCode
        if error is CancellationError {
            code = .cancelled
        } else if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize: code = .exceededContextWindowSize
            case .assetsUnavailable: code = .assetsUnavailable
            case .guardrailViolation: code = .guardrailViolation
            case .unsupportedGuide: code = .unsupportedGuide
            case .unsupportedLanguageOrLocale: code = .unsupportedLanguageOrLocale
            case .decodingFailure: code = .decodingFailure
            case .rateLimited: code = .rateLimited
            case .concurrentRequests: code = .concurrentRequests
            case .refusal: code = .refusal
            @unknown default: code = .unknown
            }
        } else {
            code = .unknown
        }
        return NSError(
            domain: errorDomain,
            code: code.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: (error as NSError).localizedDescription,
                NSUnderlyingErrorKey: error as NSError,
            ]
        )
    }
}
