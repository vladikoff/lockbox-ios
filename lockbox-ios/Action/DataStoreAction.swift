/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import RxSwift
import RxCocoa
import Storage
import SwiftyJSON

enum DataStoreAction: Action {
    case initialize(blob: JSON)
    case lock
    case unlock
    case reset
    case sync
    case touch(id: String)
    case add(item: LoginData)
    case remove(id: String)
}

class DataStoreActionHandler: ActionHandler {
    static let shared = DataStoreActionHandler()
    private var dispatcher: Dispatcher

    private let disposeBag = DisposeBag()

    init(dispatcher: Dispatcher = Dispatcher.shared) {
        self.dispatcher = dispatcher
    }

    func invoke(_ action: DataStoreAction) {
        self.dispatcher.dispatch(action: action)
    }
}
