/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import FxAUtils
import RxSwift
import RxCocoa
import SwiftyJSON

protocol FxAViewProtocol: class, ErrorView {
    func loadRequest(_ urlRequest: URLRequest)
}

struct LockedSyncState {
    let locked: Bool
    let state: SyncState
}

class FxAPresenter {
    private weak var view: FxAViewProtocol?
    fileprivate let fxAActionHandler: FxAActionHandler
    fileprivate let settingActionHandler: SettingActionHandler
    fileprivate let routeActionHandler: RouteActionHandler
    fileprivate let dataStoreActionHandler: DataStoreActionHandler
    fileprivate let fxaStore: FxAStore
    fileprivate let dataStore: DataStore
    fileprivate let userDefaults: UserDefaults

    private var disposeBag = DisposeBag()

    public var onCancel: AnyObserver<Void> {
        return Binder(self) { target, _ in
            target.routeActionHandler.invoke(LoginRouteAction.welcome)
        }.asObserver()
    }

    init(view: FxAViewProtocol,
         fxAActionHandler: FxAActionHandler = FxAActionHandler.shared,
         settingActionHandler: SettingActionHandler = SettingActionHandler.shared,
         routeActionHandler: RouteActionHandler = RouteActionHandler.shared,
         dataStoreActionHandler: DataStoreActionHandler = DataStoreActionHandler.shared,
         fxaStore: FxAStore = FxAStore.shared,
         dataStore: DataStore = DataStore.shared,
         userDefaults: UserDefaults = UserDefaults.standard
    ) {
        self.view = view
        self.fxAActionHandler = fxAActionHandler
        self.settingActionHandler = settingActionHandler
        self.routeActionHandler = routeActionHandler
        self.dataStoreActionHandler = dataStoreActionHandler
        self.fxaStore = fxaStore
        self.dataStore = dataStore
        self.userDefaults = userDefaults
    }

    func onViewReady() {
        self.fxaStore.fxADisplay
                .drive(onNext: { action in
                    switch action {
                    case .loadInitialURL(let url):
                        self.view?.loadRequest(URLRequest(url: url))
                    case .finishedFetchingUserInformation:
                        self.settingActionHandler.invoke(SettingAction.visualLock(locked: false))
                        self.routeActionHandler.invoke(MainRouteAction.list)
                    default:
                        break
                    }
                })
                .disposed(by: self.disposeBag)

        self.fxAActionHandler.initiateFxAAuthentication()
    }

    func webViewRequest(decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let navigationURL = navigationAction.request.url {
            if "\(navigationURL.scheme!)://\(navigationURL.host!)\(navigationURL.path)" == Constant.app.redirectURI,
               let components = URLComponents(url: navigationURL, resolvingAgainstBaseURL: true) {
                self.fxAActionHandler.matchingRedirectURLReceived(components: components)
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }
}

// Extensions and enums to support logging in via remote commmand.
extension FxAPresenter {
    // The user has signed in to a Firefox Account.  We're done!
    func onLogin(_ data: JSON) {
        Observable.combineLatest(self.userDefaults.onLock, self.dataStore.syncState)
                .map { LockedSyncState(locked: $0.0, state: $0.1) }
                .subscribe(onNext: { latest in
                    if latest.locked {
                        self.settingActionHandler.invoke(.visualLock(locked: false))
                        self.routeActionHandler.invoke(MainRouteAction.list)
                    } else if latest.state == SyncState.Syncing {
                        self.dataStoreActionHandler.invoke(.initialize(blob: data))
                    }
                })
                .disposed(by: self.disposeBag)
    }
}
