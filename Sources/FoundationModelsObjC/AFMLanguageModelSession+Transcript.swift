import Foundation
import FoundationModels

/// Errors from serializing / restoring a transcript.
enum AFMTranscriptError: Error, CustomNSError {
    case encodingFailed(underlying: Error?)
    case invalidJSON(underlying: Error?)

    static var errorDomain: String { "AFMTranscriptErrorDomain" }

    var errorCode: Int {
        switch self {
        case .encodingFailed: return 1
        case .invalidJSON: return 2
        }
    }

    var errorUserInfo: [String: Any] {
        let message: String
        let underlying: Error?
        switch self {
        case .encodingFailed(let error):
            message = "The transcript could not be encoded to JSON."
            underlying = error
        case .invalidJSON(let error):
            message = "The transcript JSON is not valid."
            underlying = error
        }
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        // Preserve the originating Codable error (as the package does elsewhere via
        // NSUnderlyingErrorKey) so callers can inspect the real cause.
        if let underlying {
            info[NSUnderlyingErrorKey] = underlying as NSError
        }
        return info
    }
}

/// Conversation history — read it out as JSON and restore a session from it.
///
/// `Transcript` is `Codable`, so the whole interaction history (instructions, prompts,
/// responses, tool calls/outputs) round-trips through JSON. Use this to persist a
/// multi-turn conversation and resume it later.
extension AFMLanguageModelSession {
    /// Mirrors `LanguageModelSession.transcript`, encoded as a JSON string. Throws an
    /// `NSError` in `AFMTranscriptErrorDomain` if encoding fails.
    @objc public func transcriptJSON() throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(session.transcript)
        } catch {
            // Surface the real `encode` failure in AFMTranscriptErrorDomain (as documented)
            // rather than letting the raw EncodingError (NSCocoaErrorDomain) escape.
            throw AFMTranscriptError.encodingFailed(underlying: error)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw AFMTranscriptError.encodingFailed(underlying: nil)
        }
        return string
    }

    /// Restores a session from a transcript previously produced by `transcriptJSON()`
    /// (mirrors `LanguageModelSession(transcript:)`). The transcript already carries its
    /// own `Instructions`, so there is no separate instructions parameter. Throws an
    /// `NSError` in `AFMTranscriptErrorDomain` if [transcriptJSON] is not valid transcript
    /// JSON.
    @objc public convenience init(transcriptJSON: String) throws {
        guard let data = transcriptJSON.data(using: .utf8) else {
            throw AFMTranscriptError.invalidJSON(underlying: nil)
        }
        let transcript: Transcript
        do {
            transcript = try JSONDecoder().decode(Transcript.self, from: data)
        } catch {
            throw AFMTranscriptError.invalidJSON(underlying: error)
        }
        self.init(session: LanguageModelSession(transcript: transcript))
    }
}
