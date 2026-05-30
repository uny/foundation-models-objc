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
| Toolchain | Swift 6.2 / Xcode 16.x |
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
            products = listOf(product("OnDeviceLlmBridge")),
        )
    }
}
```

## API surface

`OnDeviceLlmBridge` is an `@objc` class backing a single `LanguageModelSession`:

| Method | Purpose |
|:--|:--|
| `static isAvailable() -> Bool` | Whether the on-device model is ready on this device. |
| `createSession(_ instructions: String?)` | Start a session, optionally with system `Instructions`. |
| `generate(_:temperature:maxTokens:completion:)` | Single-shot generation. A negative temperature / non-positive maxTokens means "use the model default". |
| `streamGenerate(_:temperature:maxTokens:onPartial:completion:)` | Streaming generation. `onPartial` receives **cumulative** snapshots (callers diff for deltas). |
| `cancel()` | Cancel the in-flight generation (Foundation Models stops at the next token boundary). |
| `close()` | Cancel and release the session. |

Generation runs on a `Task` the bridge owns, so it can be cancelled from another thread; all session/task access is guarded by an `NSLock` for cross-thread safety.

## License

Apache License 2.0. See [LICENSE](LICENSE).
