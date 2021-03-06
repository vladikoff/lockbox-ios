/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
// swiftlint:disable line_length
// swiftlint:disable force_cast

import Quick
import Nimble
import WebKit
import RxTest
import RxSwift

@testable import Lockbox

class DataStoreActionSpec: QuickSpec {
    class FakeWebView: WKWebView, TypedJavaScriptWebView {
        var evaluateJSArgument: String?
        var evaluateJStoBoolArgument: String?

        var loadFileUrlArgument = URL(string: "")
        var loadFileBaseUrlArgument = URL(string: "")

        var firstBoolSingle: Single<Bool>?
        var secondBoolSingle: Single<Bool>?
        var anySingle: Single<Any> = Single.just(false)

        private var boolCallCount = 0

        func evaluateJavaScriptToBool(_ javaScriptString: String) -> Single<Bool> {
            evaluateJStoBoolArgument = javaScriptString

            boolCallCount += 1
            return boolCallCount == 1 ? firstBoolSingle! : secondBoolSingle!
        }

        func evaluateJavaScript(_ javaScriptString: String) -> Single<Any> {
            evaluateJSArgument = javaScriptString

            return anySingle
        }

        override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
            loadFileUrlArgument = URL
            loadFileBaseUrlArgument = readAccessURL

            return nil
        }
    }

    class FakeWKNavigation: WKNavigation {
        private var somethingToHoldOnTo: Bool

        override init() {
            somethingToHoldOnTo = true
        }
    }

    class FakeParser: ItemParser {
        var itemFromDictionaryShouldThrow = false
        var jsonStringFromItemShouldThrow = false
        var item: Item!
        var jsonString: String!

        func itemFromDictionary(_ dictionary: [String: Any]) throws -> Item {
            if itemFromDictionaryShouldThrow {
                throw ParserError.InvalidDictionary
            } else {
                return item
            }
        }

        func jsonStringFromItem(_ item: Item) throws -> String {
            if jsonStringFromItemShouldThrow {
                throw ParserError.InvalidItem
            } else {
                return jsonString
            }
        }
    }

    class FakeWKScriptMessage: WKScriptMessage {
        private var providedBody: Any
        private var providedName: String
        override var name: String {
            return providedName
        }

        override var body: Any {
            return providedBody
        }

        init(name: String, body: Any) {
            self.providedName = name
            self.providedBody = body
        }
    }

    class FakeDispatcher: Dispatcher {
        var actionTypeArguments: [Action] = []

        override func dispatch(action: Action) {
            self.actionTypeArguments.append(action)
        }
    }

    class StubbedLoadDataStoreActionHandler: DataStoreActionHandler {
        var loadedStub = ReplaySubject<Void>.create(bufferSize: 1)

        override var loadedSubject: ReplaySubject<Void> {
            get {
                return loadedStub
            }
            set {
                super.loadedSubject = newValue
            }
        }
    }

    var subject: StubbedLoadDataStoreActionHandler!
    var webView: FakeWebView!
    var parser: FakeParser!
    var dispatcher: FakeDispatcher!
    private let dataStoreName: String = "dstore"
    private let scheduler = TestScheduler(initialClock: 0)
    private let disposeBag = DisposeBag()

    override func spec() {
        describe("DataStoreActionHandler") {
            beforeEach {
                self.webView = FakeWebView()
                self.parser = FakeParser()
                self.dispatcher = FakeDispatcher()
                self.subject = StubbedLoadDataStoreActionHandler(dataStoreName: self.dataStoreName, parser: self.parser, dispatcher: self.dispatcher)

                self.subject.webView = self.webView
            }

            it("dispatches opened status to start") {
                let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                expect(arguments).to(contain(DataStoreAction.opened(opened: false)))
            }

            describe(".open(uid:)") {
                describe("when the datastore code has not been loaded yet") {
                    it("does nothing") {
                        self.subject.open(uid: "dfsfdssdf")
                        expect(self.webView.evaluateJSArgument).to(beNil())
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                    }
                }

                describe("when the datastore has been loaded") {
                    let uid = "fsdsdfsdfsdfsdf"
                    beforeEach {
                        self.subject.loadedStub.onNext(())
                    }

                    describe("when the javascript call results in an error") {
                        let err = NSError(domain: "badness", code: -1)

                        beforeEach {
                            self.webView.anySingle = self.scheduler.createColdObservable([error(100, err)])
                                    .take(1)
                                    .asSingle()
                            self.subject.open(uid: uid)
                            self.scheduler.start()
                        }

                        it("evaluates javascript to open the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("var \(self.dataStoreName);swiftOpen({\"salt\":\"\(uid)\"}).then(function (datastore) {\(self.dataStoreName) = datastore;});"))
                        }

                        it("dispatches the error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                        }
                    }

                    describe("when the javascript call proceeds normally") {
                        beforeEach {
                            self.webView.anySingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.open(uid: uid)
                            self.scheduler.start()
                        }

                        it("evaluates javascript to initialize the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("var \(self.dataStoreName);swiftOpen({\"salt\":\"\(uid)\"}).then(function (datastore) {\(self.dataStoreName) = datastore;});"))
                        }

                        describe("getting an opencomplete callback from javascript") {
                            beforeEach {
                                let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "open")
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the opened result to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                expect(arguments).to(contain(DataStoreAction.opened(opened: true)))
                            }
                        }

                        describe("getting an unknown callback from javascript") {
                            beforeEach {
                                let message = FakeWKScriptMessage(name: "gibberish", body: "something")
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the UnexpectedJavaScriptMethod to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod)))
                            }
                        }
                    }
                }
            }

            describe(".updateInitialized()") {
                describe("when the datastore has not been opened yet") {
                    it("does nothing") {
                        self.subject.updateInitialized()
                        expect(self.webView.evaluateJStoBoolArgument).to(beNil())
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                    }
                }

                describe("when the datastore has been opened") {
                    describe("when the bool is evaluated successfully") {
                        beforeEach {
                            let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                            self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(10, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.updateInitialized()
                            self.scheduler.start()
                        }

                        it("evaluates a bool from .initialized on the webview") {
                            expect(self.webView.evaluateJStoBoolArgument).notTo(beNil())
                            expect(self.webView.evaluateJStoBoolArgument).to(equal("\(self.dataStoreName).initialized"))
                        }

                        it("pushes the value from the webview to the returned single") {
                            expect(self.dispatcher.actionTypeArguments).toNot(beNil())
                            let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                            expect(arguments).to(contain(DataStoreAction.initialized(initialized: true)))
                        }
                    }

                    describe("when there is a javascript or other webview error") {
                        let err = NSError(domain: "badness", code: -1)

                        beforeEach {
                            let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                            self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([error(10, err)])
                                    .take(1)
                                    .asSingle()
                            self.subject.updateInitialized()
                            self.scheduler.start()
                        }

                        it("evaluates a bool from .initialized on the webview") {
                            expect(self.webView.evaluateJStoBoolArgument).notTo(beNil())
                            expect(self.webView.evaluateJStoBoolArgument).to(equal("\(self.dataStoreName).initialized"))
                        }

                        it("pushes the error from the webview to the dispatcher") {
                            expect(self.dispatcher.actionTypeArguments).toEventuallyNot(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                        }
                    }
                }
            }

            describe(".initialize(scopedKey:)") {
                let scopedKey = "someLongJWKStringWithQuote"

                describe("when the datastore has not been opened yet") {
                    beforeEach {
                        self.subject.initialize(scopedKey: scopedKey)
                    }

                    it("does nothing") {
                        expect(self.webView.evaluateJSArgument).to(beNil())
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                    }
                }

                describe("when the datastore has been opened") {
                    beforeEach {
                        let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                    }

                    describe("when the javascript call results in an error") {
                        let err = NSError(domain: "badness", code: -1)

                        beforeEach {
                            self.webView.anySingle = self.scheduler.createColdObservable([error(100, err)])
                                    .take(1)
                                    .asSingle()
                            self.subject.initialize(scopedKey: scopedKey)
                            self.scheduler.start()
                        }

                        it("evaluates javascript to initialize the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).initialize({\"appKey\":\(scopedKey)})"))
                        }

                        it("dispatches the error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                        }
                    }

                    describe("when the javascript call proceeds normally") {
                        beforeEach {
                            self.webView.anySingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.initialize(scopedKey: scopedKey)
                            self.scheduler.start()
                        }

                        it("evaluates javascript to initialize the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).initialize({\"appKey\":\(scopedKey)})"))
                        }

                        describe("getting an initializecomplete callback from javascript") {
                            beforeEach {
                                let message = FakeWKScriptMessage(name: JSCallbackFunction.InitializeComplete.rawValue, body: "initialized")
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the initialized result to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                expect(arguments).to(contain(DataStoreAction.initialized(initialized: true)))
                            }
                        }

                        describe("getting an unknown callback from javascript") {
                            beforeEach {
                                let message = FakeWKScriptMessage(name: "gibberish", body: "something")
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the UnexpectedJavaScriptMethod to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beEmpty())
                                let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod)))
                            }
                        }
                    }
                }
            }

            describe(".updateLocked()") {
                describe("when the datastore has not been opened yet") {
                    it("does nothing") {
                        self.subject.updateLocked()
                        expect(self.webView.evaluateJStoBoolArgument).to(beNil())
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                    }
                }

                describe("when the datastore has been opened") {
                    describe("when the bool is evaluated successfully") {
                        beforeEach {
                            let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                            self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.updateLocked()
                            self.scheduler.start()
                        }

                        it("evaluates a bool from .locked on the webview") {
                            expect(self.webView.evaluateJStoBoolArgument).notTo(beNil())
                            expect(self.webView.evaluateJStoBoolArgument).to(equal("\(self.dataStoreName).locked"))
                        }

                        it("pushes the value from the webview to the returned single") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                            expect(arguments).to(contain(DataStoreAction.locked(locked: true)))
                        }
                    }

                    describe("when there is a javascript or other webview error") {
                        let err = NSError(domain: "badness", code: -1)
                        beforeEach {
                            let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                            self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)

                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([error(100, err)])
                                    .take(1)
                                    .asSingle()
                            self.subject.updateLocked()
                            self.scheduler.start()
                        }

                        it("evaluates a bool from .initialized on the webview") {
                            expect(self.webView.evaluateJStoBoolArgument).notTo(beNil())
                            expect(self.webView.evaluateJStoBoolArgument).to(equal("\(self.dataStoreName).locked"))
                        }

                        it("pushes the error from the webview to the dispatcher") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                        }
                    }
                }
            }

            describe(".unlock(scopedKey:)") {
                let scopedKey = "{\"kty\":\"oct\",\"kid\":\"L9-eBkDrYHdPdXV_ymuzy_u9n3drkQcSw5pskrNl4pg\",\"k\":\"WsTdZ2tjji2W36JN9vk9s2AYsvp8eYy1pBbKPgcSLL4\"}"
                describe("when the datastore has not been opened yet") {
                    it("does nothing") {
                        self.subject.unlock(scopedKey: scopedKey)
                        expect(self.webView.evaluateJSArgument).to(beNil())
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                    }
                }

                describe("when the datastore has been opened") {
                    beforeEach {
                        self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                .take(1)
                                .asSingle()
                        self.webView.secondBoolSingle = self.scheduler.createColdObservable([next(100, false)])
                                .take(1)
                                .asSingle()
                        let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                    }

                    describe("when the javascript call results in an error") {
                        let err = NSError(domain: "badness", code: -1)

                        beforeEach {
                            self.webView.anySingle = self.scheduler.createHotObservable([error(100, err)])
                                    .take(1)
                                    .asSingle()
                            self.subject.unlock(scopedKey: scopedKey)
                            self.scheduler.start()
                        }

                        it("evaluates .unlock on the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).unlock(\(scopedKey))"))
                        }

                        it("dispatches the error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                        }
                    }

                    describe("when the javascript call proceeds normally") {
                        beforeEach {
                            self.webView.anySingle = self.scheduler.createHotObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.unlock(scopedKey: scopedKey)
                            self.scheduler.start()
                        }

                        it("evaluates .unlock on the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).unlock(\(scopedKey))"))
                        }

                        describe("getting an unlockcomplete callback from javascript") {
                            let body = "done"

                            beforeEach {
                                let message = FakeWKScriptMessage(name: JSCallbackFunction.UnlockComplete.rawValue, body: body)
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the value to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                expect(arguments).to(contain(DataStoreAction.locked(locked: false)))
                            }
                        }

                        describe("getting an unknown callback from javascript") {
                            beforeEach {
                                let message = FakeWKScriptMessage(name: "gibberish", body: "something")
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the UnexpectedJavaScriptMethod to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod)))
                            }
                        }
                    }
                }
            }

            describe(".lock()") {
                describe("when the datastore has not been opened yet") {
                    it("does nothing") {
                        expect(self.webView.evaluateJSArgument).to(beNil())
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                    }
                }

                describe("when the datastore has been opened") {
                    beforeEach {
                        let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                    }

                    describe("when the javascript call results in an error") {
                        let err = NSError(domain: "badness", code: -1)

                        beforeEach {
                            self.webView.anySingle = self.scheduler.createColdObservable([error(100, err)])
                                    .take(1)
                                    .asSingle()
                            self.subject.lock()
                            self.scheduler.start()
                        }

                        it("evaluates .lock on the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).lock()"))
                        }

                        it("dispatches the error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                        }
                    }

                    describe("when the javascript call proceeds normally") {
                        beforeEach {
                            self.webView.anySingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.lock()
                            self.scheduler.start()
                        }

                        it("evaluates .lock on the webview datastore") {
                            expect(self.webView.evaluateJSArgument).notTo(beNil())
                            expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).lock()"))
                        }

                        describe("getting a lockcomplete callback from javascript") {
                            let body = "done"

                            beforeEach {
                                let message = FakeWKScriptMessage(name: JSCallbackFunction.LockComplete.rawValue, body: body)
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the updated lock value to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                expect(arguments).to(contain(DataStoreAction.locked(locked: true)))
                            }
                        }

                        describe("getting an unknown callback from javascript") {
                            beforeEach {
                                let message = FakeWKScriptMessage(name: "gibberish", body: "something")
                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                            }

                            it("pushes the UnexpectedJavaScriptMethod to the dispatcher") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod)))
                            }
                        }
                    }
                }
            }

            describe(".list()") {
                describe("when the datastore is not open") {
                    it("does nothing") {
                        self.subject.list()
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                        expect(self.webView.evaluateJSArgument).to(beNil())
                    }
                }

                describe("when the datastore is open") {
                    beforeEach {
                        let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                    }

                    describe("when the datastore is not initialized") {
                        beforeEach {
                            self.webView.firstBoolSingle = self.scheduler.createHotObservable([next(100, false)])
                                    .take(1)
                                    .asSingle()
                            self.subject.list()
                            self.scheduler.start()
                        }

                        it("pushes the DataStoreNotInitialized error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.NotInitialized)))
                        }
                    }

                    describe("when the datastore is initialized but locked") {
                        beforeEach {
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.webView.secondBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.list()
                            self.scheduler.start()
                        }

                        it("pushes the DataStoreLocked error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.Locked)))
                        }
                    }

                    describe("when the datastore is initialized & unlocked") {
                        beforeEach {
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.webView.secondBoolSingle = self.scheduler.createColdObservable([next(100, false)])
                                    .take(1)
                                    .asSingle()
                        }

                        describe("when the javascript call results in an error") {
                            let err = NSError(domain: "badness", code: -1)

                            beforeEach {
                                self.webView.anySingle = self.scheduler.createColdObservable([error(100, err)])
                                        .take(1)
                                        .asSingle()

                                self.subject.list()
                                self.scheduler.start()
                            }

                            it("evaluates .list() on the webview datastore") {
                                expect(self.webView.evaluateJSArgument).notTo(beNil())
                                expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).list()"))
                            }

                            it("dispatches the error") {
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                            }
                        }
                        describe("when the javascript call proceeds normally") {
                            beforeEach {
                                self.webView.anySingle = self.scheduler.createColdObservable([next(200, "initial success")])
                                        .take(1)
                                        .asSingle()

                                self.subject.list()
                                self.scheduler.start()
                            }

                            it("evaluates .list() on the webview datastore") {
                                expect(self.webView.evaluateJSArgument).notTo(beNil())
                                expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).list()"))
                            }

                            describe("getting an unknown callback from javascript") {
                                beforeEach {
                                    let message = FakeWKScriptMessage(name: "gibberish", body: "something")
                                    self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                }

                                it("pushes the UnexpectedJavaScriptMethod to the dispatcher") {
                                    expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                    let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                    expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod)))
                                }
                            }

                            describe("when the webview calls back with a list that does not contain lists") {
                                beforeEach {
                                    let message = FakeWKScriptMessage(name: JSCallbackFunction.ListComplete.rawValue, body: [1, 2, 3])
                                    self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                }

                                it("pushes the UnexpectedType error") {
                                    expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                    let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                    expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedType)))
                                }
                            }

                            describe("when the webview calls back with a list of lists without the dictionary as the second value") {
                                beforeEach {
                                    let message = FakeWKScriptMessage(name: JSCallbackFunction.ListComplete.rawValue, body: [[1, 2, 3]])
                                    self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                }

                                it("pushes an empty list") {
                                    expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                    let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                    expect(arguments).to(contain(DataStoreAction.list(list: [:])))
                                }
                            }

                            describe("when the webview calls back with a list that contains only dictionaries") {
                                describe("when the parser is unable to parse an item from the dictionary") {
                                    beforeEach {
                                        self.parser.itemFromDictionaryShouldThrow = true
                                        let message = FakeWKScriptMessage(name: JSCallbackFunction.ListComplete.rawValue, body: [["idvalue", ["foo": 5, "bar": 1]], ["idvalue1", ["foo": 3, "bar": 7]]])

                                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                    }

                                    it("pushes a list with the valid items") {
                                        expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                        let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                        expect(arguments).to(contain(DataStoreAction.list(list: [:])))
                                    }
                                }

                                describe("when the parser is able to parse items from the dictionary") {
                                    beforeEach {
                                        self.parser.itemFromDictionaryShouldThrow = false
                                        self.parser.item = Item.Builder()
                                                .origins(["www.blah.com"])
                                                .id("kdkjdsfsdf")
                                                .entry(ItemEntry.Builder().kind("login").build())
                                                .build()

                                        let message = FakeWKScriptMessage(name: JSCallbackFunction.ListComplete.rawValue, body: [["idvalue1", ["foo": 3, "bar": 7]]])
                                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                    }

                                    it("pushes the items") {
                                        expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                        let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                        expect(arguments).to(contain(DataStoreAction.list(list: [self.parser.item.id!: self.parser.item])))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            describe(".touch()") {
                let item = Item.Builder().id("jlkfsdlkjsfd").build()
                let encodedItem = try! JSONEncoder().encode(item)
                let itemJSONString = String(data: encodedItem, encoding: .utf8)

                describe("when the datastore is not open") {
                    it("does nothing") {
                        self.subject.touch(item)
                        expect(self.dispatcher.actionTypeArguments.count).to(beLessThanOrEqualTo(2))
                        expect(self.webView.evaluateJSArgument).to(beNil())
                    }
                }

                describe("when the datastore is open") {
                    beforeEach {
                        let message = FakeWKScriptMessage(name: JSCallbackFunction.OpenComplete.rawValue, body: "opened")
                        self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                    }

                    describe("when the datastore is not initialized") {
                        beforeEach {
                            self.webView.firstBoolSingle = self.scheduler.createHotObservable([next(100, false)])
                                    .take(1)
                                    .asSingle()
                            self.subject.touch(item)
                            self.scheduler.start()
                        }

                        it("pushes the DataStoreNotInitialized error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.NotInitialized)))
                        }
                    }

                    describe("when the datastore is initialized but locked") {
                        beforeEach {
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.webView.secondBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.subject.touch(item)
                            self.scheduler.start()
                        }

                        it("pushes the DataStoreLocked error") {
                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                            expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.Locked)))
                        }
                    }

                    describe("when the datastore is initialized & unlocked") {
                        beforeEach {
                            self.webView.firstBoolSingle = self.scheduler.createColdObservable([next(100, true)])
                                    .take(1)
                                    .asSingle()
                            self.webView.secondBoolSingle = self.scheduler.createColdObservable([next(100, false)])
                                    .take(1)
                                    .asSingle()
                        }

                        describe("when the item does not have an ID") {
                            beforeEach {
                                self.subject.touch(Item.Builder().build())
                                self.scheduler.start()
                            }

                            it("dispatches the NoIDPassed error") {
                                expect(self.webView.evaluateJSArgument).to(beNil())
                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.NoIDPassed)))
                            }
                        }

                        describe("when the item has an ID") {
                            describe("when the parser cannot parse a json string from the item") {
                                beforeEach {
                                    self.parser.jsonStringFromItemShouldThrow = true
                                    self.subject.touch(item)
                                    self.scheduler.start()
                                }

                                it("passes up the InvalidItem error") {
                                    expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                    let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                    expect(argument).to(matchErrorAction(ErrorAction(error: ParserError.InvalidItem)))
                                }
                            }

                            describe("when the parser can parse a json string from the item") {
                                beforeEach {
                                    self.parser.jsonString = itemJSONString
                                }

                                describe("when the javascript call results in an error") {
                                    let err = NSError(domain: "badness", code: -1)

                                    beforeEach {
                                        self.webView.anySingle = self.scheduler.createColdObservable([error(100, err)])
                                                .take(1)
                                                .asSingle()

                                        self.subject.touch(item)
                                        self.scheduler.start()
                                    }

                                    it("evaluates .touch() on the webview datastore") {
                                        expect(self.webView.evaluateJSArgument).notTo(beNil())
                                        expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).touch(\(itemJSONString!))"))
                                    }

                                    it("dispatches the error") {
                                        expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                        let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                        expect(argument).to(matchErrorAction(ErrorAction(error: err)))
                                    }
                                }

                                describe("when the javascript call proceeds normally") {
                                    beforeEach {
                                        self.webView.anySingle = self.scheduler.createColdObservable([next(200, "initial success")])
                                                .take(1)
                                                .asSingle()

                                        self.subject.touch(item)
                                        self.scheduler.start()
                                    }

                                    it("evaluates .touch() on the webview datastore") {
                                        expect(self.webView.evaluateJSArgument).notTo(beNil())
                                        expect(self.webView.evaluateJSArgument).to(equal("\(self.dataStoreName).touch(\(itemJSONString!))"))
                                    }

                                    describe("getting an unknown callback from javascript") {
                                        beforeEach {
                                            let message = FakeWKScriptMessage(name: "gibberish", body: "something")
                                            self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                        }

                                        it("pushes the UnexpectedJavaScriptMethod to the dispatcher") {
                                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                            expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedJavaScriptMethod)))
                                        }
                                    }

                                    describe("when the webview does not call back with a dictionary") {
                                        beforeEach {
                                            let message = FakeWKScriptMessage(name: JSCallbackFunction.UpdateComplete.rawValue, body: [1, 2, 3])
                                            self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                        }

                                        it("pushes the UnexpectedType error") {
                                            expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                            let argument = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                            expect(argument).to(matchErrorAction(ErrorAction(error: DataStoreError.UnexpectedType)))
                                        }
                                    }

                                    describe("when the webview calls back with a dictionary") {
                                        describe("when the parser is unable to parse an item from the dictionary") {
                                            beforeEach {
                                                self.parser.itemFromDictionaryShouldThrow = true
                                                let message = FakeWKScriptMessage(name: JSCallbackFunction.UpdateComplete.rawValue, body: ["foo": 5, "bar": 1])

                                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                            }

                                            it("pushes a the error") {
                                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                                let arguments = self.dispatcher.actionTypeArguments.last as! ErrorAction
                                                expect(arguments).to(matchErrorAction(ErrorAction(error: ParserError.InvalidDictionary)))
                                            }
                                        }

                                        describe("when the parser is able to parse an item from the dictionary") {
                                            beforeEach {
                                                self.parser.itemFromDictionaryShouldThrow = false
                                                self.parser.item = Item.Builder()
                                                        .origins(["www.blah.com"])
                                                        .id("kdkjdsfsdf")
                                                        .entry(ItemEntry.Builder().kind("login").build())
                                                        .build()

                                                let message = FakeWKScriptMessage(name: JSCallbackFunction.UpdateComplete.rawValue, body: ["foo": 5, "bar": 1])
                                                self.subject.userContentController(self.webView.configuration.userContentController, didReceive: message)
                                            }

                                            it("pushes the item") {
                                                expect(self.dispatcher.actionTypeArguments).notTo(beNil())
                                                let arguments = self.dispatcher.actionTypeArguments as! [DataStoreAction]
                                                expect(arguments).to(contain(DataStoreAction.updated(item: self.parser.item)))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            describe("Action equality") {
                let itemA = Item.Builder().id("something").build()
                let itemB = Item.Builder().id("something else").build()

                it("updateList is always equal") {
                    expect(DataStoreAction.list(list: [itemA.id!: itemA])).to(equal(DataStoreAction.list(list: [itemA.id!: itemA])))
                    expect(DataStoreAction.list(list: [itemA.id!: itemA])).to(equal(DataStoreAction.list(list: [itemA.id!: itemA, itemB.id!: itemA])))
                    expect(DataStoreAction.list(list: [itemA.id!: itemA])).to(equal(DataStoreAction.list(list: [itemB.id!: itemB])))
                }

                it("update is equal based on the contained item") {
                    expect(DataStoreAction.updated(item: itemA)).to(equal(DataStoreAction.updated(item: itemA)))
                    expect(DataStoreAction.updated(item: itemA)).notTo(equal(DataStoreAction.updated(item: itemB)))
                }

                it("initialize is equal based on the contained boolean") {
                    expect(DataStoreAction.initialized(initialized: true)).to(equal(DataStoreAction.initialized(initialized: true)))
                    expect(DataStoreAction.initialized(initialized: true)).notTo(equal(DataStoreAction.initialized(initialized: false)))
                }

                it("initialize is equal based on the contained boolean") {
                    expect(DataStoreAction.locked(locked: true)).to(equal(DataStoreAction.locked(locked: true)))
                    expect(DataStoreAction.locked(locked: true)).notTo(equal(DataStoreAction.locked(locked: false)))
                }

                it("different enum values are not equal") {
                    expect(DataStoreAction.locked(locked: false)).notTo(equal(DataStoreAction.initialized(initialized: false)))
                }
            }
        }
    }
}
