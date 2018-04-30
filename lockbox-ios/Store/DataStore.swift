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

enum SyncState {
    case NotSyncable, ReadyToSync, Syncing, Synced, Error(error: SyncError)

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

        let state: SyncState
        if !profile.hasSyncableAccount() {
            state = .NotSyncable
        } else {
            state = .ReadyToSync
        }

        syncSubject.onNext(state)
        registerNotificationCenter()

        dispatcher.register
                .filterByType(class: DataStoreAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case let .initialize(blob: data):
                        self.onLogin(data)
                    case .sync:
                        self.onSync()
                    default: break
                    }
                })
                .disposed(by: self.disposeBag)

        self.populateTestData()
        self.registerNotificationCenter()
    }

    deinit {
        unregisterNotificationObservers()
    }

    public func get(_ id: String) -> Observable<Item?> {
        return self.listSubject
                .map { items -> Item? in
                    return items.filter { item in
                        return item.id == id
                     }.first
                }.asObservable()
    }
}

extension DataStore {
    public func populateTestData() {
        let items = [
            Item.Builder()
                    .title("Amazon")
                    .origins(["https://amazon.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobson@example.com")
                            .password("iLUVdawgz")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Facebook")
                    .origins(["https://www.facebook.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tanya.jacobson")
                            .password("iLUVdawgz")
                            .notes("I just have so much anxiety about using this website that I'm going to write about it in the notes section of my password manager wow") // swiftlint:disable:this line_length
                            .build())
                    .build(),
            Item.Builder()
                    .title("Reddit")
                    .origins(["https://reddit.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobson@example.com")
                            .password("iLUVdawgz")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Twitter")
                    .origins(["http://www.twitter.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobson@example.com")
                            .password("iLUVdawgz")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Blogspot")
                    .origins(["https://accounts.google.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobson@example.com")
                            .password("iLUVdawgz")
                            .notes("Meditation cloud bread cray, locavore actually chia everyday carry biodiesel venmo. Fashion axe polaroid seitan, put a bird on it stumptown selvage fam mustache thundercats viral. Squid tbh lo-fi celiac ennui occupy offal fam +1 disrupt ethical bushwick. Narwhal freegan man bun yr cray, heirloom try-hard mustache biodiesel. Direct trade tacos next level flexitarian tumeric cronut cornhole, brunch deep v tote bag brooklyn beard whatever gluten-free humblebrag. Cloud bread kale chips beard man braid, thundercats lo-fi forage chicharrones venmo four dollar toast lyft butcher echo park lumbersexual photo booth.") // swiftlint:disable:this line_length
                            .build())
                    .build(),
            Item.Builder()
                    .title("Chase")
                    .origins(["https://www.chase.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("jacobsonfamily444")
                            .password("iLUVdawgz")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Linkedin")
                    .origins(["https://www.linkedin.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tanyamjackson@example.com")
                            .password("iAmAprofessional345!")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Bank of America")
                    .origins(["http://www.bankofamerica.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobson735")
                            .password("iLUVdawgz")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Comcast")
                    .origins(["http://www.comcast.net"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobsonlongfamilyusername@example.com")
                            .password("iLUVdawgz")
                            .build())
                    .build(),
            Item.Builder()
                    .title("Zee Longest Title of a website you've ever seen")
                    .origins(["www.verylongdomainthatmayormaynotexistintherealworld.com"])
                    .entry(ItemEntry.Builder()
                            .kind("login")
                            .username("tjacobson")
                            .password("veryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryverylongpassword") // swiftlint:disable:this line_length
                            .build())
                    .build()
        ]

        self.listSubject.onNext(items)
    }
}

extension DataStore {
    public func onLogin(_ data: JSON) {
        let helper = FxALoginHelper.sharedInstance
        helper.application(UIApplication.shared, didReceiveAccountJSON: data)
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
