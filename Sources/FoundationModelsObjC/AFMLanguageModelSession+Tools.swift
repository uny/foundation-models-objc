import Foundation
import FoundationModels
import os

/// A tool the model can call during generation, implemented by a non-Swift consumer.
///
/// The model decides when to call the tool; the framework then invokes
/// `call(argumentsJSON:completion:)` off the calling thread. The handler must call
/// [completion] exactly once — with the tool's result as a string (fed back to the model)
/// or an error. Because the call can arrive on any thread, implementations must be safe to
/// invoke off the main actor.
///
/// A handler that never calls [completion] would otherwise stall the generation
/// indefinitely; the bridge breaks that wait when the session is cancelled (see
/// `AFMBridgedTool.call`), but the handler is still expected to fulfil the contract.
@objc public protocol AFMToolHandler {
    func call(argumentsJSON: String, completion: @escaping (String?, Error?) -> Void)
}

/// Declares a tool to `AFMLanguageModelSession(tools:instructions:)`.
///
/// [parametersJSONSchema] is a JSON Schema (see `AFMSchemaBuilder`) describing the
/// arguments the model should produce; the bridge passes the model's filled-in arguments
/// to the handler as a JSON string.
@objc public final class AFMTool: NSObject {
    @objc public let name: String
    @objc public let toolDescription: String
    @objc public let parametersJSONSchema: String
    /// Whether the framework injects this tool's parameter schema into the model's
    /// instructions. Set false when the schema is already described there (the tool-side
    /// analogue of structured output's `includeSchemaInPrompt`), to avoid duplicating it
    /// and spending context tokens.
    @objc public let includesSchemaInInstructions: Bool
    @objc public let handler: AFMToolHandler

    @objc public init(
        name: String,
        description: String,
        parametersJSONSchema: String,
        includesSchemaInInstructions: Bool,
        handler: AFMToolHandler
    ) {
        self.name = name
        self.toolDescription = description
        self.parametersJSONSchema = parametersJSONSchema
        self.includesSchemaInInstructions = includesSchemaInInstructions
        self.handler = handler
        super.init()
    }
}

/// Swift `Tool` that forwards calls to an `AFMToolHandler`.
///
/// `Arguments` is `GeneratedContent` (so any schema works without a `@Generable` type) and
/// `Output` is `String`. The async `call` bridges to the handler's completion via a checked
/// continuation.
///
/// `@unchecked Sendable`: the only non-`Sendable` stored value is the external `handler`.
/// The bridge holds no mutable state and merely forwards each call, so correctness reduces
/// to the handler being callable off the main actor — which the protocol documents as a
/// requirement. This is the deliberate exception to the package's otherwise
/// `@unchecked`-free concurrency model, because an `@objc` protocol cannot conform to
/// `Sendable`.
struct AFMBridgedTool: Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let includesSchemaInInstructions: Bool
    let handler: AFMToolHandler

    func call(arguments: GeneratedContent) async throws -> String {
        let argumentsJSON = arguments.jsonString
        let handler = self.handler
        // The handler's completion and task cancellation race for the continuation, and a
        // checked continuation traps on a second resume — so the continuation lives in a
        // locked slot and whoever arrives first takes it (clearing the slot) while the
        // other becomes a no-op. Honoring cancellation also bounds the wait: a handler that
        // never calls completion would otherwise hang the generation forever, but cancelling
        // the session (cancel()/close()) now unsticks it. The lock holds a non-Sendable
        // continuation, hence `uncheckedState`.
        let slot = OSAllocatedUnfairLock<CheckedContinuation<String, Error>?>(uncheckedState: nil)
        // Atomically take the continuation out of the slot (clearing it), so the handler's
        // completion and onCancel race for it and only the first taker gets a non-nil value.
        @Sendable func takeContinuation() -> CheckedContinuation<String, Error>? {
            slot.withLock { stored in
                defer { stored = nil }
                return stored
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let cancelledBeforeStore = slot.withLock { stored -> Bool in
                    // onCancel may have already fired (and found an empty slot) before we
                    // stored; Task.isCancelled catches that so we don't park forever.
                    if Task.isCancelled { return true }
                    stored = continuation
                    return false
                }
                if cancelledBeforeStore {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                handler.call(argumentsJSON: argumentsJSON) { result, error in
                    guard let continuation = takeContinuation() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result ?? "")
                    }
                }
            }
        } onCancel: {
            takeContinuation()?.resume(throwing: CancellationError())
        }
    }
}

extension AFMLanguageModelSession {
    /// Starts a session whose model can call the given [tools]. A nil [instructions] starts
    /// the session without system `Instructions`. Throws an `NSError` in `AFMSchemaErrorDomain`
    /// if any tool's `parametersJSONSchema` is malformed.
    @objc public convenience init(tools: [AFMTool], instructions: String?) throws {
        let bridged: [any Tool] = try tools.map { tool in
            let schema = try AFMSchemaBuilder.generationSchema(
                fromJSONSchema: tool.parametersJSONSchema,
                rootName: tool.name
            )
            return AFMBridgedTool(
                name: tool.name,
                description: tool.toolDescription,
                parameters: schema,
                includesSchemaInInstructions: tool.includesSchemaInInstructions,
                handler: tool.handler
            )
        }
        let session: LanguageModelSession
        if let instructions {
            session = LanguageModelSession(tools: bridged) {
                Instructions(instructions)
            }
        } else {
            session = LanguageModelSession(tools: bridged)
        }
        self.init(session: session)
    }
}
