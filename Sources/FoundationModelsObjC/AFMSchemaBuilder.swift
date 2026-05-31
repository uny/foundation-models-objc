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
    case invalidEnum(at: String)
    case invalidProperty(key: String, at: String)
    case invalidArrayBounds(at: String)

    static var errorDomain: String { "AFMSchemaErrorDomain" }

    var errorCode: Int {
        switch self {
        case .invalidJSON: return 1
        case .notAnObject: return 2
        case .unsupportedType: return 3
        case .arrayMissingItems: return 4
        case .invalidEnum: return 5
        case .invalidProperty: return 6
        case .invalidArrayBounds: return 7
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
        case .invalidEnum(let path):
            message = "The 'enum' at '\(path)' must be a non-empty array of strings."
        case .invalidProperty(let key, let path):
            message = "Property '\(key)' at '\(path)' must be a JSON object describing its schema."
        case .invalidArrayBounds(let path):
            message = "Array schema at '\(path)' has invalid 'minItems'/'maxItems' (each must be a non-negative integer with minItems <= maxItems)."
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
        // `description` is read for every node, but the framework only lets us attach one to
        // objects (`init(name:description:properties:)`) and enums (`init(name:description:anyOf:)`).
        // The primitive (`init(type:)`) and array (`init(arrayOf:…)`) initializers take no
        // description, so a `description` placed directly on a bare scalar or array node is
        // dropped here. It still survives whenever such a node is an *object property*, because
        // `DynamicGenerationSchema.Property` carries the description independently (see the
        // `object` case below) — and real schemas are almost always a root object of properties.
        // Wrapping a scalar in a single-element `anyOf` just to carry a description is avoided
        // deliberately: it would change the schema's meaning from "a string" to "a union of one
        // string". This is a FoundationModels limitation, not an oversight.
        let description = node["description"] as? String
        let type = node["type"] as? String

        switch type {
        case "object":
            let rawProperties = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            // Sort keys so the generated schema is stable across runs (JSONSerialization
            // does not preserve object key order).
            let properties: [DynamicGenerationSchema.Property] = try rawProperties.keys.sorted().map { key in
                // A property whose value isn't a schema object can't be represented. Fail
                // loudly instead of dropping it — silently omitting a `required` key would
                // hand the model a schema missing a field the caller demanded.
                guard let child = rawProperties[key] as? [String: Any] else {
                    throw AFMSchemaError.invalidProperty(key: key, at: name)
                }
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
            let minItems = try intBound(node, "minItems", at: name)
            let maxItems = try intBound(node, "maxItems", at: name)
            if let minItems, let maxItems, minItems > maxItems {
                throw AFMSchemaError.invalidArrayBounds(at: name)
            }
            let itemSchema = try dynamicSchema(from: items, name: "\(name).item")
            return DynamicGenerationSchema(
                arrayOf: itemSchema,
                minimumElements: minItems,
                maximumElements: maxItems
            )

        case "string":
            if let rawEnum = node["enum"] {
                // The subset supports `enum` only as a non-empty list of strings. Anything
                // else (mixed types, or an empty list that yields an unsatisfiable `anyOf`)
                // can't be turned into a valid choice set, so reject it rather than silently
                // degrading to an unconstrained string.
                guard let cases = rawEnum as? [String], !cases.isEmpty else {
                    throw AFMSchemaError.invalidEnum(at: name)
                }
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

    /// Reads a non-negative integer array bound (`minItems` / `maxItems`). Absent → nil;
    /// present but not a non-negative integer (e.g. a float or a negative value) → throws,
    /// so a malformed bound is rejected up front instead of being silently ignored.
    private static func intBound(_ node: [String: Any], _ key: String, at name: String) throws -> Int? {
        guard let raw = node[key] else { return nil }
        guard let value = raw as? Int, value >= 0 else {
            throw AFMSchemaError.invalidArrayBounds(at: name)
        }
        return value
    }
}
