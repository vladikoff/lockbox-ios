/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
// swiftlint:disable file_length

import Foundation
import WebKit
import RxSwift
import RxCocoa

enum DataStoreError: Error {
    case NoIDPassed, Locked, NotInitialized, UnexpectedType, UnexpectedJavaScriptMethod, Unknown
}

enum JSCallbackFunction: String {
    case OpenComplete, InitializeComplete, UnlockComplete, LockComplete, ListComplete, UpdateComplete

    static let allValues: [JSCallbackFunction] = [
        .OpenComplete,
        .InitializeComplete,
        .UnlockComplete,
        .LockComplete,
        .ListComplete,
        .UpdateComplete
    ]
}

enum DataStoreAction: Action {
    case list(list: [String: Item])
    case updated(item: Item)
    case locked(locked: Bool)
    case initialized(initialized: Bool)
    case opened(opened: Bool)
}

extension DataStoreAction: Equatable {
    static func ==(lhs: DataStoreAction, rhs: DataStoreAction) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list):
            return true
        case (.updated(let lhItem), .updated(let rhItem)):
            return lhItem == rhItem
        case (.locked(let lhLocked), .locked(let rhLocked)):
            return lhLocked == rhLocked
        case (.initialized(let lhInitialized), .initialized(let rhInitialized)):
            return lhInitialized == rhInitialized
        case (.opened(let lhOpened), .opened(let rhOpened)):
            return lhOpened == rhOpened
        default:
            return false
        }
    }
}

class DataStoreActionHandler: NSObject, ActionHandler {
    static let shared = DataStoreActionHandler()
    private var dispatcher: Dispatcher

    internal var webView: (WKWebView & TypedJavaScriptWebView)!
    private let dataStoreName: String
    private let parser: ItemParser
    private let disposeBag = DisposeBag()

    // Subject references for .js calls
    internal var loadedSubject = ReplaySubject<Void>.create(bufferSize: 1)
    private var openSubject = ReplaySubject<Void>.create(bufferSize: 1)
    private var initializeSubject = PublishSubject<Void>()
    private var unlockSubject = PublishSubject<Void>()
    private var lockSubject = PublishSubject<Void>()
    private var listSubject = PublishSubject<[String: Item]>()
    private var updateSubject = PublishSubject<Item>()

    internal var webViewConfiguration: WKWebViewConfiguration {
        let webConfig = WKWebViewConfiguration()

        for f in JSCallbackFunction.allValues {
            webConfig.userContentController.add(self, name: f.rawValue)
        }

        webConfig.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webConfig.preferences.javaScriptEnabled = true

        return webConfig
    }

    init(dataStoreName: String = "ds",
         parser: ItemParser = Parser(),
         dispatcher: Dispatcher = Dispatcher.shared) {
        self.dataStoreName = dataStoreName
        self.parser = parser
        self.dispatcher = dispatcher
        super.init()

        self.webView = WebView(frame: .zero, configuration: self.webViewConfiguration)
        self.webView.navigationDelegate = self

        guard let baseUrl = URL(string: "file://\(Bundle.main.bundlePath)/lockbox-datastore/"),
              let path = URL(string: "file://\(Bundle.main.bundlePath)/lockbox-datastore/index.html") else {
            self.dispatcher.dispatch(action: ErrorAction(error: DataStoreError.Unknown))
            return
        }

        self.dispatcher.dispatch(action: DataStoreAction.opened(opened: false))
        self.webView.loadFileURL(path, allowingReadAccessTo: baseUrl)
    }

    public func open(uid: String) {
        self.openSubject
                .take(1)
                .subscribe(onNext: { [weak self] _ in
                    self?.dispatcher.dispatch(action: DataStoreAction.opened(opened: true))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                    self?.openSubject = ReplaySubject<Void>.create(bufferSize: 1)
                })
                .disposed(by: self.disposeBag)

        self._open(uid: uid)
    }

    public func initialize(scopedKey: String) {
        self.initializeSubject
                .take(1)
                .subscribe(onNext: { [weak self] _ in
                    self?.dispatcher.dispatch(action: DataStoreAction.initialized(initialized: true))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                    self?.initializeSubject = PublishSubject<Void>()
                })
                .disposed(by: self.disposeBag)

        self._initialize(scopedKey: scopedKey)
    }

    public func updateInitialized() {
        self._initialized()
                .subscribe(onSuccess: { [weak self] initialized in
                    self?.dispatcher.dispatch(action: DataStoreAction.initialized(initialized: initialized))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                })
                .disposed(by: self.disposeBag)
    }

    public func unlock(scopedKey: String) {
        self.unlockSubject
                .take(1)
                .subscribe(onNext: { [weak self] _ in
                    self?.dispatcher.dispatch(action: DataStoreAction.locked(locked: false))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                    self?.unlockSubject = PublishSubject<Void>()
                })
                .disposed(by: self.disposeBag)

        self._unlock(scopedKey: scopedKey)
    }

    public func lock() {
        self.lockSubject
                .take(1)
                .subscribe(onNext: { [weak self] _ in
                    self?.dispatcher.dispatch(action: DataStoreAction.locked(locked: true))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                    self?.lockSubject = PublishSubject<Void>()
                })
                .disposed(by: self.disposeBag)

        self._lock()
    }

    public func updateLocked() {
        self._locked()
                .subscribe(onSuccess: { [weak self] locked in
                    self?.dispatcher.dispatch(action: DataStoreAction.locked(locked: locked))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                })
                .disposed(by: self.disposeBag)
    }

    public func list() {
        self.listSubject
                .take(1)
                .subscribe(onNext: { [weak self] itemList in
                    self?.dispatcher.dispatch(action: DataStoreAction.list(list: itemList))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                    self?.listSubject = PublishSubject<[String: Item]>()
                })
                .disposed(by: self.disposeBag)

        self._list()
    }

    public func touch(_ item: Item) {
        self.updateSubject
                .take(1)
                .subscribe(onNext: { [weak self] item in
                    self?.dispatcher.dispatch(action: DataStoreAction.updated(item: item))
                }, onError: { [weak self] error in
                    self?.dispatcher.dispatch(action: ErrorAction(error: error))
                    self?.updateSubject = PublishSubject<Item>()
                })
                .disposed(by: self.disposeBag)

        self._touch(item)
    }
}

// javascript interaction
extension DataStoreActionHandler {
    private func _open(uid: String) {
        self.loadedSubject
                .take(1)
                .flatMap {
                    self.webView.evaluateJavaScript("var \(self.dataStoreName);swiftOpen({\"salt\":\"\(uid)\"}).then(function (datastore) {\(self.dataStoreName) = datastore;});") // swiftlint:disable:this line_length
                }
                .subscribe(onError: { error in
                    self.openSubject.onError(error)
                })
                .disposed(by: self.disposeBag)
    }

    private func _initialized() -> Single<Bool> {
        return self.openSubject
                .take(1)
                .asSingle()
                .flatMap { _ in
                    self.webView.evaluateJavaScriptToBool("\(self.dataStoreName).initialized")
                }
    }

    private func _initialize(scopedKey: String) {
        self.openSubject
                .take(1)
                .flatMap { _ in
                    self.webView.evaluateJavaScript("\(self.dataStoreName).initialize({\"appKey\":\(scopedKey)})")
                }
                .subscribe(onError: { error in
                    self.initializeSubject.onError(error)
                })
                .disposed(by: self.disposeBag)
    }

    private func _locked() -> Single<Bool> {
        return self.openSubject
                .take(1)
                .asSingle()
                .flatMap { _ in
                    self.webView.evaluateJavaScriptToBool("\(self.dataStoreName).locked")
                }
    }

    private func _unlock(scopedKey: String) {
        self.openSubject
                .take(1)
                .flatMap { _ in
                    self.webView.evaluateJavaScript("\(self.dataStoreName).unlock(\(scopedKey))")
                }
                .subscribe(onError: { error in
                    self.unlockSubject.onError(error)
                })
                .disposed(by: self.disposeBag)
    }

    private func _lock() {
        self.openSubject
                .take(1)
                .flatMap { _ in
                    self.webView.evaluateJavaScript("\(self.dataStoreName).lock()")
                }
                .subscribe(onError: { error in
                    self.lockSubject.onError(error)
                })
                .disposed(by: self.disposeBag)
    }

    private func _list() {
        self.openSubject
                .take(1)
                .flatMap { _ in
                    self.checkState()
                }
                .flatMap { _ in
                    self.webView.evaluateJavaScript("\(self.dataStoreName).list()")
                }
                .subscribe(onError: { error in
                    self.listSubject.onError(error)
                })
                .disposed(by: self.disposeBag)
    }

    private func _touch(_ item: Item) {
        self.openSubject.take(1)
                .flatMap { _ in
                    self.checkState()
                }
                .flatMap { _ -> Single<Any> in
                    if item.id == nil {
                        throw DataStoreError.NoIDPassed
                    }

                    let jsonItem = try self.parser.jsonStringFromItem(item)

                    return self.webView.evaluateJavaScript("\(self.dataStoreName).touch(\(jsonItem))")
                }
                .subscribe(onError: { error in
                    self.updateSubject.onError(error)
                })
                .disposed(by: self.disposeBag)
    }

    private func checkState() -> Single<Bool> {
        return _initialized().asObservable()
                .flatMap { initialized -> Observable<Bool> in
                    if !initialized {
                        throw DataStoreError.NotInitialized
                    }

                    return self._locked().asObservable()
                }
                .map { locked -> Bool in
                    if locked {
                        throw DataStoreError.Locked
                    }

                    return locked
                }
                .asSingle()
    }

    private func completeSubjectWithBody(messageBody: Any, subject: PublishSubject<Item>) {
        guard let itemDictionary = messageBody as? [String: Any] else {
            subject.onError(DataStoreError.UnexpectedType)
            return
        }

        var item: Item
        do {
            item = try self.parser.itemFromDictionary(itemDictionary)
        } catch {
            subject.onError(error)
            return
        }

        subject.onNext(item)
    }
}

extension DataStoreActionHandler: WKScriptMessageHandler, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.loadedSubject.onNext(())
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let function = JSCallbackFunction.init(rawValue: message.name) else {
            self.dispatcher.dispatch(action: ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod))
            return
        }

        switch function {
        case .OpenComplete:
            self.openSubject.onNext(())
        case .InitializeComplete:
            self.initializeSubject.onNext(())
        case .UnlockComplete:
            self.unlockSubject.onNext(())
        case .LockComplete:
            self.lockSubject.onNext(())
        case .UpdateComplete:
            self.completeSubjectWithBody(messageBody: message.body, subject: self.updateSubject)
        case .ListComplete:
            guard let listBody = message.body as? [[Any]] else {
                self.dispatcher.dispatch(action: ErrorAction(error: DataStoreError.UnexpectedType))
                break
            }

            let itemDictionary = listBody.reduce([:]) { dict, anyList -> [String: Item] in
                guard let itemId = anyList[0] as? String,
                      let itemJSON = anyList[1] as? [String: Any],
                      let item = try? self.parser.itemFromDictionary(itemJSON) else {
                    return dict
                }

                var updatedDict = dict
                updatedDict[itemId] = item

                return updatedDict
            }

            self.listSubject.onNext(itemDictionary)
        }
    }
}

// swiftlint:disable function_body_length
// Test data generator
extension DataStoreActionHandler {
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

        let encoder = JSONEncoder()
        for item in items {
            guard let encodedItem = try? encoder.encode(item),
                  let jsonString = String(data: encodedItem, encoding: .utf8) else {
                continue
            }

            self.webView.evaluateJavaScript("\(self.dataStoreName).add(\(jsonString))")
                    .subscribe()
                    .disposed(by: self.disposeBag)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: {
            self.list()
        })
    }
}

// swiftlint:enable function_body_length
// swiftlint:enable file_length
