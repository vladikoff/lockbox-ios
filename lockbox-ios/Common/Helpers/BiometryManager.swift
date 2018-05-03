/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import LocalAuthentication
import RxSwift

enum LocalError: Error {
    case LAError
}

class BiometryManager {
    private let context: LAContext

    init(context: LAContext = LAContext()) {
        self.context = context
    }

    func authenticateWithMessage(_ message: String) -> Single<Void> {
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            return Single.create { [weak self] observer in
                self?.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: message) { success, error in
                    if success {
                        observer(.success(()))
                    } else if let err = error {
                        observer(.error(err))
                    }
                }

                return Disposables.create()
            }
        }

        return Single.error(LocalError.LAError)
    }
}
