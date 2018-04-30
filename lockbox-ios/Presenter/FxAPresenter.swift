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

class FxAPresenter {
    private weak var view: FxAViewProtocol?
    fileprivate let fxAActionHandler: FxAActionHandler
    fileprivate let settingActionHandler: SettingActionHandler
    fileprivate let routeActionHandler: RouteActionHandler
    fileprivate let dataStoreActionHandler: DataStoreActionHandler
    fileprivate let fxaStore: FxAStore
    fileprivate let dataStore: DataStore

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
         dataStore: DataStore = DataStore.shared) {
        self.view = view
        self.fxAActionHandler = fxAActionHandler
        self.settingActionHandler = settingActionHandler
        self.routeActionHandler = routeActionHandler
        self.dataStoreActionHandler = dataStoreActionHandler
        self.fxaStore = fxaStore
        self.dataStore = dataStore
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
        dataStoreActionHandler.invoke(.initialize(blob: data))

        dataStore.syncState.subscribe(onNext: { state in
            if state == SyncState.Syncing {
                self.routeActionHandler.invoke(MainRouteAction.list)
            }
        }).disposed(by: disposeBag)
    }
}
