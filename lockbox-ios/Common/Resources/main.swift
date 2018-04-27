/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

final class MockAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]? = nil) -> Bool {
        self.window?.rootViewController = UIViewController()
        return true
    }
}

private func appDelegateClassName() -> String {
    let isTesting = NSClassFromString("XCTestCase") != nil
    return NSStringFromClass(isTesting ? MockAppDelegate.self : AppDelegate.self)
}

UIApplicationMain(
    CommandLine.argc,
    UnsafeMutableRawPointer(CommandLine.unsafeArgv).bindMemory(
        to: UnsafeMutablePointer<Int8>.self,
        capacity: Int(CommandLine.argc)
    ),
    NSStringFromClass(UIApplication.self),
    appDelegateClassName()
)
