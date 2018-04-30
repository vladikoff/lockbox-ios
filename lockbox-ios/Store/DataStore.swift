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

    public static func == (lhs: SyncState, rhs: SyncState) -> Bool {
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

class DataStore {
    public static let shared = DataStore()
    fileprivate let disposeBag = DisposeBag()
    private var listSubject = ReplaySubject<[Login]>.create(bufferSize: 1)
    private var syncSubject = ReplaySubject<SyncState>.create(bufferSize: 1)

    private var profile: Profile
    private var notificationObservers: [NSObjectProtocol]?

    public var list: Observable<[Login]> {
        return self.listSubject.asObservable()
    }

    public var syncState: Observable<SyncState> {
        return self.syncSubject.asObservable()
    }

    init(dispatcher: Dispatcher = Dispatcher.shared) {
        profile = BrowserProfile(localName: "lockbox-profile")
        FxALoginHelper.sharedInstance.application(UIApplication.shared, didLoadProfile: profile)

        registerNotificationCenter()

        dispatcher.register
                .filterByType(class: DataStoreAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case let .initialize(blob: data):
                        self.onLogin(data)
                    case .reset:
                        self.reset()
                    case .sync:
                        self.onSync()
                    case let .touch(id: id):
                        self.onLoginUsage(id: id)
                    default: break
                    }
                })
                .disposed(by: self.disposeBag)

        self.syncState.subscribe(onNext: { state in
            if state == SyncState.Synced {
                self.updateList()
            }
        })
        .disposed(by: self.disposeBag)

        setInitialSyncState()
    }

    deinit {
        unregisterNotificationObservers()
    }

    private func setInitialSyncState() {
        let state: SyncState
        if !profile.hasSyncableAccount() {
            state = .NotSyncable
        } else {
            state = .ReadyToSync
        }

        syncSubject.onNext(state)
        updateList()
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
    public func onLogin(_ data: JSON) {
        let helper = FxALoginHelper.sharedInstance
        helper.application(UIApplication.shared, didReceiveAccountJSON: data)
    }
}

extension DataStore {
    public func onLoginUsage(id: String) {
        profile.logins.addUseOfLoginByGUID(id)
    }
}

extension DataStore {
    public func reset() {
        FxALoginHelper.sharedInstance.applicationDidDisconnect(UIApplication.shared)
        self.syncSubject.onNext(.NotSyncable)
    }
}

extension DataStore {
    public func onSync() {
        profile.syncManager.syncEverything(why: .syncNow)
    }

    private func registerNotificationCenter() {
        guard notificationObservers == nil else {
            return
        }
        let names: [Notification.Name] = [NotificationNames.FirefoxAccountVerified,
                                          NotificationNames.ProfileDidStartSyncing,
                                          NotificationNames.ProfileDidFinishSyncing
        ]
        notificationObservers = names.map { name in
            return NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: updateSyncState(from:))
        }
    }

    private func unregisterNotificationObservers() {
        notificationObservers?.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = nil
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
}
