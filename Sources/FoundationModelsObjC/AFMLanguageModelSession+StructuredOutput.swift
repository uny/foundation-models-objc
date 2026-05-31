import Foundation
import FoundationModels

/// Structured (guided) generation: the model is constrained to a schema and returns JSON.
///
/// Mirrors `respond(to:schema:)` / `streamResponse(to:schema:)`. The Swift-only `@Generable`
/// macro can't cross the `@objc` boundary, so callers pass a **JSON Schema** describing the
/// desired shape (see `AFMSchemaBuilder` for the supported subset) and receive the model's
/// output as a **JSON string** (`GeneratedContent.jsonString`).
extension AFMLanguageModelSession {
    /// Single-shot structured generation. [jsonSchema] is the desired output shape;
    /// [includeSchemaInPrompt] mirrors the framework flag (set false when the schema is
    /// already described in the instructions). The completion delivers a JSON string on
    /// success, or an `NSError` — in `AFMSchemaErrorDomain` for a malformed schema, or in
    /// `AFMLanguageModelSession.errorDomain` for a generation failure.
    @objc public func respond(
        to prompt: String,
        jsonSchema: String,
        includeSchemaInPrompt: Bool,
        options: AFMGenerationOptions,
        completion: @escaping @Sendable (String?, Error?) -> Void
    ) {
        let schema: GenerationSchema
        do {
            schema = try AFMSchemaBuilder.generationSchema(fromJSONSchema: jsonSchema, rootName: "Output")
        } catch {
            completion(nil, error as NSError)
            return
        }
        let session = self.session
        let resolved = options.resolved()
        start {
            do {
                let response = try await session.respond(
                    to: prompt,
                    schema: schema,
                    includeSchemaInPrompt: includeSchemaInPrompt,
                    options: resolved
                )
                completion(response.content.jsonString, nil)
            } catch {
                completion(nil, Self.mapError(error))
            }
        }
    }

    /// Streaming structured generation. [onPartial] receives the framework's **cumulative**
    /// snapshots as JSON strings (each a partially-filled object, so it may not be valid
    /// until the final one); callers diff for deltas. Errors are delivered as in
    /// `respond(to:jsonSchema:includeSchemaInPrompt:options:completion:)`.
    @objc public func streamResponse(
        to prompt: String,
        jsonSchema: String,
        includeSchemaInPrompt: Bool,
        options: AFMGenerationOptions,
        onPartial: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let schema: GenerationSchema
        do {
            schema = try AFMSchemaBuilder.generationSchema(fromJSONSchema: jsonSchema, rootName: "Output")
        } catch {
            completion(error as NSError)
            return
        }
        let session = self.session
        let resolved = options.resolved()
        start {
            do {
                let stream = session.streamResponse(
                    to: prompt,
                    schema: schema,
                    includeSchemaInPrompt: includeSchemaInPrompt,
                    options: resolved
                )
                for try await partial in stream {
                    onPartial(partial.content.jsonString)
                }
                completion(nil)
            } catch {
                completion(Self.mapError(error))
            }
        }
    }
}
