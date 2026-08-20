import Foundation
import LocalAuthentication

enum AuthenticationService {
    static func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            context.localizedCancelTitle = "Отмена"
            var error: NSError?
            let policy: LAPolicy
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                policy = .deviceOwnerAuthenticationWithBiometrics
            } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                policy = .deviceOwnerAuthentication
            } else {
                continuation.resume(returning: false)
                return
            }

            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
