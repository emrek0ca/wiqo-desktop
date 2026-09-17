import Speech

/// TCC may complete speech authorization on any queue. Keeping the continuation in an explicitly
/// nonisolated type prevents Swift 6 from attaching a MainActor precondition to that callback.
nonisolated enum WiqoSpeechPermissionBridge {
    static func requestSpeechRecognition() async -> SFSpeechRecognizerAuthorizationStatus {
        await resolve { completion in
            SFSpeechRecognizer.requestAuthorization(completion)
        }
    }

    /// Internal seam used by the regression test to deliver the completion from a worker queue,
    /// matching TCC's documented behavior without opening a real system permission dialog.
    static func resolve<Value: Sendable>(
        _ register: @escaping @Sendable (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            register { value in
                continuation.resume(returning: value)
            }
        }
    }
}
