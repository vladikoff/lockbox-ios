/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import RxSwift
import RxCocoa

class UserInfoStore {
    static let shared = UserInfoStore()

    private var dispatcher: Dispatcher
    private var keychainManager: KeychainManager
    private let disposeBag = DisposeBag()

    private var _profileInfo = ReplaySubject<ProfileInfo?>.create(bufferSize: 1)

    public var profileInfo: Observable<ProfileInfo?> {
        return _profileInfo.asObservable()
    }

    init(dispatcher: Dispatcher = Dispatcher.shared,
         keychainManager: KeychainManager = KeychainManager()) {
        self.dispatcher = dispatcher
        self.keychainManager = keychainManager

        self.dispatcher.register
                .filterByType(class: UserInfoAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case .profileInfo(let info):
                        if self.saveProfileInfo(info) {
                            self._profileInfo.onNext(info)
                        }
                    case .load:
                        self.populateInitialValues()
                    case .clear:
                        self.clear()
                    }
                })
                .disposed(by: self.disposeBag)

    }
}

extension UserInfoStore {
    private func populateInitialValues() {
        if let email = self.keychainManager.retrieve(.email) {
            var avatarURL: URL?
            if let avatarString = self.keychainManager.retrieve(.avatarURL) {
                avatarURL = URL(string: avatarString)
            }

            let displayName = self.keychainManager.retrieve(.displayName)

            self._profileInfo.onNext(
                    ProfileInfo.Builder()
                            .email(email)
                            .avatar(avatarURL)
                            .displayName(displayName)
                            .build()
            )
        } else {
            self._profileInfo.onNext(nil)
        }
    }

    private func clear() {
        for identifier in KeychainManagerIdentifier.allValues {
            _ = self.keychainManager.delete(identifier)
        }

        self._profileInfo.onNext(nil)
    }

    private func saveProfileInfo(_ info: ProfileInfo) -> Bool {
        var success = self.keychainManager.save(info.email, identifier: .email)

        if let displayName = info.displayName {
            success = success && self.keychainManager.save(displayName, identifier: .displayName)
        }

        if let avatar = info.avatar {
            let avatarString = avatar.absoluteString
            success = success && self.keychainManager.save(avatarString, identifier: .avatarURL)
        }

        return success
    }
}

enum AutoLockSetting: String {
    case OnAppExit
    case OneMinute
    case FiveMinutes
    case OneHour
    case TwelveHours
    case TwentyFourHours
    case Never

    func toString() -> String {
        switch self {
        case .OnAppExit:
            return Constant.string.autoLockOnAppExit
        case .FiveMinutes:
            return Constant.string.autoLockFiveMinutes
        case .Never:
            return Constant.string.autoLockNever
        case .OneHour:
            return Constant.string.autoLockOneHour
        case .OneMinute:
            return Constant.string.autoLockOneMinute
        case .TwelveHours:
            return Constant.string.autoLockTwelveHours
        case .TwentyFourHours:
            return Constant.string.autoLockTwentyFourHours
        }
    }
}
