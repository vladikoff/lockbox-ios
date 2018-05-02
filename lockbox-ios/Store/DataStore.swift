/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import FxAUtils
import RxSwift
import RxCocoa
import RxOptional
import Shared
import Storage
import SwiftyJSON
import SwiftKeychainWrapper

enum SyncError: Error {
    case CryptoInvalidKey
    case CryptoMissingKey
    case Crypto
    case Locked
    case Offline
    case Network
    case NeedAuth
    case Conflict
    case AccountDeleted
    case AccountReset
    case DeviceRevoked
}

enum SyncState: Equatable {
    case NotSyncable, ReadyToSync, Syncing, Synced, Error(error: SyncError)

    public static func ==(lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (NotSyncable, NotSyncable):
            return true
        case (ReadyToSync, ReadyToSync):
            return true
        case (Syncing, Syncing):
            return true
        case (Synced, Synced):
            return true
        case (Error, Error):
            return true
        default:
            return false
        }
    }
}

enum LoginStoreState: Equatable {
    case Unprepared, Locked, Unlocked, Errored(cause: LoginStoreError)

    public static func ==(lhs: LoginStoreState, rhs: LoginStoreState) -> Bool {
        switch (lhs, rhs) {
        case (Unprepared, Unprepared): return true
        case (Locked, Locked): return true
        case (Unlocked, Unlocked): return true
        case (Errored, Errored): return true
        default:
            return false
        }
    }
}

public enum LoginStoreError: Error {
    // applies to just about every function call
    case Unknown(cause: Error?)
    case NotInitialized
    case AlreadyInitialized
    case VersionMismatch
    case CryptoInvalidKey
    case CryptoMissingKey
    case Crypto
    case InvalidItem
    case Locked
}

typealias ProfileFactory = (_ reset: Bool) -> Profile

private let defaultProfileFactory: ProfileFactory = { reset in BrowserProfile(localName: "lockbox-profile", clear: reset) }
private let lockedKey = "application_locked_state"

class DataStore {
    public static let shared = DataStore()
    private let disposeBag = DisposeBag()
    private var listSubject = ReplaySubject<[Login]>.create(bufferSize: 1)
    private var syncSubject = ReplaySubject<SyncState>.create(bufferSize: 1)
    private var lockSubject = ReplaySubject<Bool>.create(bufferSize: 1)
    private var storageStateSubject = ReplaySubject<LoginStoreState>.create(bufferSize: 1)

    private let fxaLoginHelper: FxALoginHelper
    private let profileFactory: ProfileFactory
    private let keychainManager: KeychainManager
    private var profile: Profile

    public var list: Observable<[Login]> {
        return self.listSubject.asObservable()
    }

    public var syncState: Observable<SyncState> {
        return self.syncSubject.asObservable()
    }

    public var locked: Observable<Bool> {
        return self.lockSubject.asObservable()
    }

    public var storageState: Observable<LoginStoreState> {
        return self.storageStateSubject.asObservable()
    }

    init(dispatcher: Dispatcher = Dispatcher.shared,
         keychainManager: KeychainManager = KeychainManager(),
         profileFactory: @escaping ProfileFactory = defaultProfileFactory,
         fxaLoginHelper: FxALoginHelper = FxALoginHelper.sharedInstance) {
        self.profileFactory = profileFactory
        self.keychainManager = keychainManager
        self.fxaLoginHelper = fxaLoginHelper

        self.profile = profileFactory(false)
        self.initializeProfile()

        self.registerNotificationCenter()

        dispatcher.register
                .filterByType(class: DataStoreAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case let .initialize(blob: data):
                        self.login(data)
                    case .reset:
                        self.reset()
                    case .sync:
                        self.sync()
                    case let .touch(id: id):
                        self.touch(id: id)
                    case .lock:
                        self.lock()
                    case .unlock:
                        self.unlock()
                    }
                })
                .disposed(by: self.disposeBag)

        dispatcher.register
                .filterByType(class: LifecycleAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case .background:
                        self.profile.syncManager?.applicationDidEnterBackground()
                    case .foreground:
                        self.profile.syncManager?.applicationDidBecomeActive()
                    case .startup:
                        break
                    }
                })
                .disposed(by: disposeBag)

        self.syncState.subscribe(onNext: { state in
                if state == .Synced {
                    self.updateList()
                } else if state == .NotSyncable {
                    self.makeEmptyList()
                }
            })
            .disposed(by: self.disposeBag)

        self.storageState.subscribe(onNext: { state in
                if state == .Unlocked {
                    self.updateList()
                    self.lockSubject.onNext(false)
                } else if state == .Locked {
                    self.makeEmptyList()
                    self.lockSubject.onNext(true)
                }
            })
            .disposed(by: self.disposeBag)

        self.setInitialSyncState()
        self.initializeLockedState()
    }

    private func initializeProfile() {
        profile.syncManager?.applicationDidBecomeActive()

        fxaLoginHelper.application(UIApplication.shared, didLoadProfile: profile)
    }

    private func setInitialSyncState() {
        let state: SyncState
        if !profile.hasSyncableAccount() {
            state = .NotSyncable
        } else {
            state = .ReadyToSync
        }

        self.syncSubject.onNext(state)
        self.updateList()
    }

    private func initializeLockedState() {
        let lockedValue = KeychainWrapper.standard.bool(forKey: lockedKey)
        if let value = lockedValue {
            self.lockSubject.onNext(value)
        } else {
            KeychainWrapper.standard.set(false, forKey: lockedKey)
            self.lockSubject.onNext(false)
        }
    }

    public func get(_ id: String) -> Observable<Login?> {
        return self.listSubject
                .map { items -> Login? in
                    return items.filter { item in
                        return item.guid == id
                     }.first
                }.asObservable()
    }
}

extension DataStore {
    public func login(_ data: JSON) {
        fxaLoginHelper.application(UIApplication.shared, didReceiveAccountJSON: data)
    }
}

extension DataStore {
    public func touch(id: String) {
        profile.logins.addUseOfLoginByGUID(id)
    }
}

extension DataStore {
    public func reset() {
        func stopSyncing() -> Success {
            guard let syncManager = self.profile.syncManager else {
                return succeed()
            }
            syncManager.endTimedSyncs()
            if !syncManager.isSyncing {
                return succeed()
            }

            return syncManager.syncEverything(why: .backgrounded)
        }

        func disconnect() -> Success {
            return self.fxaLoginHelper.applicationDidDisconnect(UIApplication.shared)
        }

        func deleteAll() -> Success {
            return profile.logins.removeAll()
        }

        func resetProfile() {
            profile = profileFactory(true)
            initializeProfile()
            syncSubject.onNext(.NotSyncable)
        }

        stopSyncing() >>== disconnect >>== deleteAll >>== resetProfile
    }
}

extension DataStore {
    func lock() {
        guard !profile.isShutdown else {
            return
        }

        guard profile.hasSyncableAccount() else {
            return
        }

        profile.syncManager?.endTimedSyncs()

        func finalShutdown() {
            profile.shutdown()
            storageStateSubject.onNext(.Locked)
            KeychainWrapper.standard.set(true, forKey: lockedKey)
            self.lockSubject.onNext(true)
        }

        if profile.syncManager.isSyncing {
            profile.syncManager.syncEverything(why: .backgrounded) >>== finalShutdown
        } else {
            finalShutdown()
        }
    }

    public func unlock() {
        profile.reopen()

        profile.syncManager?.beginTimedSyncs()

        profile.syncManager.syncEverything(why: .startup)

        storageStateSubject.onNext(.Unlocked)
        KeychainWrapper.standard.set(true, forKey: lockedKey)
        self.lockSubject.onNext(false)
    }
}

extension DataStore {
    public func sync() {
        profile.syncManager.syncEverything(why: .syncNow)
    }

    private func registerNotificationCenter() {
        let names = [NotificationNames.FirefoxAccountVerified,
                      NotificationNames.ProfileDidStartSyncing,
                      NotificationNames.ProfileDidFinishSyncing
        ]
        names.forEach { name in
            NotificationCenter.default.rx
                    .notification(name)
                    .subscribe(onNext: { self.updateSyncState(from: $0) })
                    .disposed(by: self.disposeBag)
        }
    }

    private func updateSyncState(from notification: Notification) {
        let state: SyncState
        switch notification.name {
        case NotificationNames.FirefoxAccountVerified:
            state = .ReadyToSync
        case NotificationNames.ProfileDidStartSyncing:
            state = .Syncing
        case NotificationNames.ProfileDidFinishSyncing:
            state = .Synced
        default:
            return
        }
        syncSubject.onNext(state)
    }

    private func updateList() {
        let logins = profile.logins
        logins.getAllLogins() >>== { (cursor: Cursor<Login>) in
            self.listSubject.onNext(cursor.asArray())
        }
    }

    private func makeEmptyList() {
        self.listSubject.onNext([])
    }
}
