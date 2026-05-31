import Foundation
import FoundationModels

/// A tool the model can call during generation, implemented by a non-Swift consumer.
///
/// The model decides when to call the tool; the framework then invokes
/// `call(argumentsJSON:completion:)` off the calling thread. The handler must call
/// [completion] exactly once — with the tool's result as a string (fed back to the model)
/// or an error. Because the call can arrive on any thread, implementations must be safe to
/// invoke off the main actor.
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
    @objc public let handler: AFMToolHandler

    @objc public init(name: String, description: String, parametersJSONSchema: String, handler: AFMToolHandler) {
        self.name = name
        self.toolDescription = description
        self.parametersJSONSchema = parametersJSONSchema
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
    let handler: AFMToolHandler

    var includesSchemaInInstructions: Bool { true }

    func call(arguments: GeneratedContent) async throws -> String {
        let argumentsJSON = arguments.jsonString
        return try await withCheckedThrowingContinuation { continuation in
            handler.call(argumentsJSON: argumentsJSON) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result ?? "")
                }
            }
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
