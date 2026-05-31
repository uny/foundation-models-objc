# foundation-models-objc

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Thin `@objc` Swift wrapper exposing Apple's [FoundationModels](https://developer.apple.com/documentation/FoundationModels) framework to Objective-C and Kotlin/Native (cinterop) consumers.

## Why this exists

`FoundationModels` (Apple's on-device LLM, iOS 26+) is **Swift-only** — it ships no Objective-C headers. Kotlin/Native cinterop can only consume Objective-C / C interfaces, so it cannot call the framework directly. This package is a minimal `@objc` surface that translates the Swift-only API (`async`/`await`, `Instructions`, `GenerationOptions`, streaming `AsyncSequence`) into completion-handler-based `@objc` methods that any non-Swift consumer can bind to.

It is consumed by [`ondevice-llm`](https://github.com/uny/ondevice-llm) (a Kotlin Multiplatform on-device LLM library) via Kotlin's `swiftPMDependencies`, but it has no dependency on Kotlin or `ondevice-llm` — it is a standalone SwiftPM package.

## Requirements

| | |
|:--|:--|
| Platform | iOS 26.0+ |
| Toolchain | Swift 6.2 / Xcode 26 |
| Framework | `FoundationModels` (linked automatically) |
| Hardware | Apple Intelligence-capable device (iPhone 15 Pro+ / M1+) |

## Usage (SwiftPM)

```swift
.package(url: "https://github.com/uny/foundation-models-objc.git", from: "1.0.0")
```

From Kotlin Multiplatform (`build.gradle.kts`):

```kotlin
kotlin {
    swiftPMDependencies {
        iosMinimumDeploymentTarget.set("26.0")
        swiftPackage(
            url = url("https://github.com/uny/foundation-models-objc.git"),
            version = exact("1.0.0"),
            products = listOf(product("FoundationModelsObjC")),
        )
    }
}
```

## API surface

Types mirror the Swift-only originals with an `AFM` (**A**pple **F**oundation **M**odels) prefix, so the `@objc` surface reads like the standard API.

### `AFMSystemLanguageModel`

| Member | Mirrors | Purpose |
|:--|:--|:--|
| `static isAvailable() -> Bool` | `SystemLanguageModel.default.isAvailable` | Whether the on-device model is ready on this device. |
| `static availability() -> AFMModelAvailability` | `SystemLanguageModel.default.availability` | Availability with the **reason** when unavailable (`deviceNotEligible` / `appleIntelligenceNotEnabled` / `modelNotReady`). |
| `static supportedLanguageIdentifiers() -> [String]` | `supportedLanguages` | BCP-47 identifiers of the languages the model supports. |
| `static supportsLocale(_:) -> Bool` | `supportsLocale(_:)` | Whether a given BCP-47 locale identifier (e.g. `"en-US"`) is supported. |

### `AFMLanguageModelSession`

| Member | Mirrors | Purpose |
|:--|:--|:--|
| `init(instructions: String?)` | `LanguageModelSession(instructions:)` | Start a session, optionally with system `Instructions`. |
| `init(useCase:permissiveGuardrails:instructions:)` | `LanguageModelSession(model:instructions:)` | Start a session on a model specialized for a `UseCase` (`.general` / `.contentTagging`), optionally with permissive guardrails. |
| `init(tools:instructions:)` *(throws)* | `LanguageModelSession(tools:instructions:)` | Start a session whose model can call the given `AFMTool`s. See [Tool calling](#tool-calling). |
| `init(transcriptJSON:)` *(throws)* | `LanguageModelSession(transcript:)` | Restore a session from a transcript produced by `transcriptJSON()`. See [Transcript](#transcript-history). |
| `var isResponding: Bool` | `LanguageModelSession.isResponding` | Whether a generation is currently in flight. |
| `prewarm()` | `LanguageModelSession.prewarm()` | Preload the model to avoid first-generation cold-start latency. Best-effort, safe to call repeatedly. |
| `prewarm(promptPrefix:)` | `LanguageModelSession.prewarm(promptPrefix:)` | Preload and also cache a prompt prefix so a follow-up generation starting with it is faster. |
| `respond(to:temperature:maxTokens:completion:)` | `respond(to:options:)` | Single-shot generation. A negative temperature / non-positive maxTokens means "use the model default". |
| `respond(to:options:completion:)` | `respond(to:options:)` | Single-shot generation with full `AFMGenerationOptions` (temperature, token cap, sampling). |
| `respond(to:jsonSchema:includeSchemaInPrompt:options:completion:)` | `respond(to:schema:)` | Structured generation constrained to a JSON Schema; returns a JSON string. See [Structured output](#structured-output). |
| `streamResponse(to:temperature:maxTokens:onPartial:completion:)` | `streamResponse(to:options:)` | Streaming generation. `onPartial` receives **cumulative** snapshots (callers diff for deltas). |
| `streamResponse(to:options:onPartial:completion:)` | `streamResponse(to:options:)` | Streaming generation with full `AFMGenerationOptions`. |
| `streamResponse(to:jsonSchema:includeSchemaInPrompt:options:onPartial:completion:)` | `streamResponse(to:schema:)` | Streaming structured generation; `onPartial` receives cumulative JSON snapshots. |
| `transcriptJSON()` *(throws)* | `LanguageModelSession.transcript` | The conversation history as a JSON string. See [Transcript](#transcript-history). |
| `cancel()` | — | Cancel the in-flight generation (Foundation Models stops at the next token boundary). |
| `close()` | — | Cancel and release the session's retained task. |

### `AFMGenerationOptions`

Mirror of `GenerationOptions`, passed to the `respond(to:options:)` / `streamResponse(to:options:)` overloads. Sentinel defaults mean "use the model default" the same way the primitive overloads do.

| Property | Mirrors | Notes |
|:--|:--|:--|
| `temperature: Double` | `temperature` | Negative → model default. |
| `maximumResponseTokens: Int` | `maximumResponseTokens` | Non-positive → model default. |
| `samplingMode: AFMSamplingMode` | `sampling` | `.default` (unset) / `.greedy` / `.topK` / `.nucleus`. |
| `samplingTopK: Int` | `.random(top:seed:)` | Candidate count for `.topK`. Must be ≥ 1; unset/invalid → model default sampling. |
| `samplingProbabilityThreshold: Double` | `.random(probabilityThreshold:seed:)` | Probability mass for `.nucleus`, in (0, 1]; unset/out-of-range → model default sampling. |
| `samplingSeed: Int64` | `seed:` | Reproducible sampling; negative → no fixed seed. |

### Errors

`respond` / `streamResponse` deliver failures as `NSError` in the `AFMLanguageModelSession.errorDomain` domain. The `code` is an `AFMGenerationErrorCode` (e.g. `exceededContextWindowSize`, `guardrailViolation`, `rateLimited`, `cancelled`) mapped from `LanguageModelSession.GenerationError`, so non-Swift consumers can branch on the cause. The original framework error is preserved under `NSUnderlyingErrorKey`.

Generation runs on a `Task` the session owns, so it can be cancelled from another thread; access to that task is guarded by an `OSAllocatedUnfairLock` for cross-thread safety.

A session holds **one in-flight generation at a time**: starting a new `respond`/`streamResponse` cancels any previous one, which then completes with an error whose code is `AFMGenerationErrorCode.cancelled` (the underlying `CancellationError` is preserved under `NSUnderlyingErrorKey`). A completion handler may therefore still fire after `cancel()`/`close()` (delivering that `cancelled` error), so callers should be prepared to ignore a completion on an already-cancelled call.

## Structured output

The Swift-only `@Generable` macro can't cross the `@objc` boundary, so structured (guided) generation is driven by a **JSON Schema** string and returns the model's output as a **JSON string** (`GeneratedContent.jsonString`):

```
respond(to: "Extract the contact", jsonSchema: schema, includeSchemaInPrompt: true, options: opts) { json, error in ... }
```

The supported JSON Schema subset (built by `AFMSchemaBuilder`): `object` (`properties`, `required`), `array` (`items`, `minItems`/`maxItems`), `string` (with optional `enum`), `integer`, `number`, `boolean`, and `description` on any node. Nested schemas are inlined (no `$ref`). A malformed schema fails with an `NSError` in `AFMSchemaErrorDomain`, distinct from generation failures.

## Tool calling

Give the model tools it can call mid-generation. Implement `AFMToolHandler` (one `call(argumentsJSON:completion:)` method), describe each tool with an `AFMTool` (name, description, and a JSON Schema for its arguments), and start the session with `init(tools:instructions:)`:

| Type | Purpose |
|:--|:--|
| `AFMToolHandler` (protocol) | Your implementation. The framework calls `call(argumentsJSON:completion:)` off the main actor when the model invokes the tool; call `completion` exactly once with the result string (fed back to the model) or an error. |
| `AFMTool` | Declares one tool: `name`, `description`, `parametersJSONSchema`, `handler`. |
| `init(tools:instructions:)` | Starts a session whose model can call the tools. Throws if a tool's schema is malformed. |

The bridge maps each tool's arguments to a JSON string and the handler's return value back to the model, so no `@Generable` argument type is needed.

## Transcript (history)

`transcriptJSON()` returns the full conversation history (instructions, prompts, responses, tool calls/outputs) as JSON, and `init(transcriptJSON:)` restores a session from it — so a multi-turn conversation can be persisted and resumed. The transcript already carries its own `Instructions`, so the restoring initializer takes no separate instructions argument.

## License

Apache License 2.0. See [LICENSE](LICENSE).
