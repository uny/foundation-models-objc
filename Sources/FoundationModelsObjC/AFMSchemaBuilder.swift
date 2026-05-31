import Foundation
import FoundationModels

/// Errors from translating a JSON Schema string into a `GenerationSchema`.
///
/// Surfaced as `NSError` in `AFMSchemaErrorDomain` so a malformed schema is
/// distinguishable from a generation failure (`AFMLanguageModelSession.errorDomain`).
enum AFMSchemaError: Error, CustomNSError {
    case invalidJSON
    case notAnObject
    case unsupportedType(type: String, at: String)
    case arrayMissingItems(at: String)

    static var errorDomain: String { "AFMSchemaErrorDomain" }

    var errorCode: Int {
        switch self {
        case .invalidJSON: return 1
        case .notAnObject: return 2
        case .unsupportedType: return 3
        case .arrayMissingItems: return 4
        }
    }

    var errorUserInfo: [String: Any] {
        let message: String
        switch self {
        case .invalidJSON:
            message = "The schema is not valid JSON."
        case .notAnObject:
            message = "The schema's root must be a JSON object."
        case .unsupportedType(let type, let path):
            message = "Unsupported schema type '\(type)' at '\(path)'."
        case .arrayMissingItems(let path):
            message = "Array schema at '\(path)' is missing an 'items' definition."
        }
        return [NSLocalizedDescriptionKey: message]
    }
}

/// Builds a `FoundationModels.GenerationSchema` from a JSON Schema string so non-Swift
/// consumers can drive structured output (and tool parameters) without the Swift-only
/// `@Generable` macro.
///
/// Supported subset (the common JSON Schema core):
/// - `object` with `properties` and `required`
/// - `array` with `items`, optional `minItems` / `maxItems`
/// - `string` (with optional `enum` of strings), `integer`, `number`, `boolean`
/// - `description` on any node
///
/// Nested object/array schemas are inlined, so no `$ref` / `dependencies` handling is
/// needed. Unsupported constructs throw `AFMSchemaError` rather than being silently dropped.
enum AFMSchemaBuilder {
    static func generationSchema(fromJSONSchema json: String, rootName: String) throws -> GenerationSchema {
        guard let data = json.data(using: .utf8) else {
            throw AFMSchemaError.invalidJSON
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AFMSchemaError.invalidJSON
        }
        guard let object = parsed as? [String: Any] else {
            throw AFMSchemaError.notAnObject
        }
        let root = try dynamicSchema(from: object, name: rootName)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(from node: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let description = node["description"] as? String
        let type = node["type"] as? String

        switch type {
        case "object":
            let rawProperties = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            // Sort keys so the generated schema is stable across runs (JSONSerialization
            // does not preserve object key order).
            let properties: [DynamicGenerationSchema.Property] = try rawProperties.keys.sorted().compactMap { key in
                guard let child = rawProperties[key] as? [String: Any] else { return nil }
                let childSchema = try dynamicSchema(from: child, name: "\(name).\(key)")
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: child["description"] as? String,
                    schema: childSchema,
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)

        case "array":
            guard let items = node["items"] as? [String: Any] else {
                throw AFMSchemaError.arrayMissingItems(at: name)
            }
            let itemSchema = try dynamicSchema(from: items, name: "\(name).item")
            return DynamicGenerationSchema(
                arrayOf: itemSchema,
                minimumElements: node["minItems"] as? Int,
                maximumElements: node["maxItems"] as? Int
            )

        case "string":
            if let cases = node["enum"] as? [String] {
                return DynamicGenerationSchema(name: name, description: description, anyOf: cases)
            }
            return DynamicGenerationSchema(type: String.self)

        case "integer":
            return DynamicGenerationSchema(type: Int.self)

        case "number":
            return DynamicGenerationSchema(type: Double.self)

        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)

        default:
            throw AFMSchemaError.unsupportedType(type: type ?? "<missing>", at: name)
        }
    }
}
