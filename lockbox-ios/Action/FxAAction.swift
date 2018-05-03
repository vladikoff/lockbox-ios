/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import RxSwift
import FxAClient

enum FxADisplayAction: Action {
    case loadInitialURL(url: URL)
    case fetchingUserInformation
    case finishedFetchingUserInformation
}

extension FxADisplayAction: Equatable {

    static func ==(lhs: FxADisplayAction, rhs: FxADisplayAction) -> Bool {
        switch (lhs, rhs) {
        case (.loadInitialURL(let lhURL), .loadInitialURL(let rhURL)):
            return lhURL == rhURL
        case (.fetchingUserInformation, .fetchingUserInformation):
            return true
        case (.finishedFetchingUserInformation, .finishedFetchingUserInformation):
            return true
        default:
            return false
        }
    }

}

enum FxAError: Error {
    case RedirectNoState
    case RedirectNoCode
    case RedirectBadState
    case EmptyOAuthData
    case EmptyProfileInfoData
    case UnexpectedDataFormat
    case Unknown
}

class FxAActionHandler: ActionHandler {
    static let shared = FxAActionHandler()

    private var dispatcher: Dispatcher
    private var session: URLSession
    private var keyManager: KeyManager
    private let disposeBag = DisposeBag()

    lazy internal var scope = "https://identity.mozilla.com/apps/lockbox"
    lazy internal var state: String = self.keyManager.random32()!.base64URLEncodedString()
    lazy internal var codeVerifier: String = self.keyManager.random32()!.base64URLEncodedString()
    lazy internal var codeChallenge: String = self.codeVerifier.sha256withBase64URL()!
    internal var jwkKey: String?
    internal var flowId: String?
    internal var fxa: FirefoxAccount?

    lazy private var authURL: URL = { [weak self] in
        var components = URLComponents()

        components.scheme = "https"
        components.host = Constant.fxa.oauthHost
        components.path = "/v1/authorization"

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: Constant.fxa.clientID),
            URLQueryItem(name: "redirect_uri", value: Constant.app.redirectURI),
            URLQueryItem(name: "scope", value: "profile openid \(self?.scope ?? "")"),
            URLQueryItem(name: "action", value: "signin"),
            URLQueryItem(name: "keys_jwk", value: self?.jwkKey ?? ""),
            URLQueryItem(name: "state", value: self?.state),
            URLQueryItem(name: "code_challenge", value: self?.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        return components.url!
    }()

    lazy private var tokenURL: URL = { [weak self] in
        var components = URLComponents()

        components.scheme = "https"
        components.host = Constant.fxa.oauthHost
        components.path = "/v1/token"

        return components.url!
    }()

    lazy private var profileInfoURL: URL = { [weak self] in
        var components = URLComponents()
        components.scheme = "https"
        components.host = Constant.fxa.profileHost
        components.path = "/v1/profile"

        return components.url!
    }()

    init(dispatcher: Dispatcher = Dispatcher.shared,
         session: URLSession = URLSession.shared,
         keyManager: KeyManager = KeyManager()) {
        self.dispatcher = dispatcher
        self.session = session
        self.keyManager = keyManager
    }

    public func initiateFxAAuthentication() {
        
        let cfg = FxAConfig.release()
        let resp = "{\"customizeSync\":false,\"email\":\"vlad2@restmail.net\",\"keyFetchToken\":\"e25ea2b104e061142fa53827fcf98c83cea46ebdb1988169b9166e07d6ba2834\",\"sessionToken\":\"9996bdf23e8bf59f66f64db61732ef853bb6d912ff567fa3a027db3afe564d31\",\"uid\":\"5946fdc94c964f3c88f4f629a31cad3d\",\"unwrapBKey\":\"5cbac7381e37e3db256313415e10d0462239589945a862f5827c958efe12133a\",\"verified\":false,\"verifiedCanLinkAccount\":true}"
        self.fxa = FirefoxAccount.from(config: cfg, webChannelResponse: resp)
        let scopes = "profile openid \(self.scope ?? "")";
        let oauthFlow = fxa!.beginOAuthFlow(clientId: Constant.fxa.clientID, redirectURI: Constant.app.redirectURI, scopes: scopes)!
        let keys_jwk = URL(string: oauthFlow.authorizationURI)!;
        self.flowId = oauthFlow.flowId;
        
        var dict = [String:String]()
        let components = URLComponents(url: keys_jwk, resolvingAgainstBaseURL: false)!
        if let queryItems = components.queryItems {
            for item in queryItems {
                dict[item.name] = item.value!
            }
        }
        
        do {
            self.jwkKey = try self.keyManager.getEphemeralPublicECDH().base64URL()
        } catch {
            self.dispatcher.dispatch(action: ErrorAction(error: error))
            return
        }
        
        self.authURL = keys_jwk;


        self.dispatcher.dispatch(action: FxADisplayAction.loadInitialURL(url: self.authURL))
    }

    public func matchingRedirectURLReceived(components: URLComponents) {

        guard let state = components.queryItems!.first(where: { $0.name == "state" }),
            let stateValue = state.value else {
                self.dispatcher.dispatch(action: ErrorAction(error: FxAError.RedirectNoState))
                return
        }
        
        guard let code = components.queryItems!.first(where: { $0.name == "code" }),
            let codeValue = code.value else {
                self.dispatcher.dispatch(action: ErrorAction(error: FxAError.RedirectNoCode))
                return
        }


        self.dispatcher.dispatch(action: FxADisplayAction.fetchingUserInformation)
        let consumed = self.fxa!.consumeOAuthFlowCode(flowId: self.flowId!, code: codeValue, state: stateValue)
        self.authenticateAndRetrieveUserInformation(scopedKey: consumed!)
    }
}

extension FxAActionHandler {
    private func authenticateAndRetrieveUserInformation(scopedKey: String) {
        
        return Single<OAuthInfo>.create { single in
            
            let currentDate = Date()
            var dateComponent = DateComponents()
            dateComponent.year = 2030
            let futureDate = Calendar.current.date(byAdding: dateComponent, to: currentDate)
            let info = OAuthInfo(accessToken: "a", expiresAt: futureDate!, refreshToken: "c", idToken: "d", keysJWE: "wat")
            
            single(.success(info))
            return Disposables.create()
            }
                .do(onSuccess: { info in
                    self.dispatcher.dispatch(action: UserInfoAction.oauthInfo(info: info))
                    self.dispatcher.dispatch(action: UserInfoAction.scopedKey(key: scopedKey))
                })
                .flatMap { info -> Single<ProfileInfo> in
                    self.postProfileInfoRequest(accessToken: info.accessToken)
                }
                .subscribe(onSuccess: { profileInfo in
                    self.dispatcher.dispatch(action: UserInfoAction.profileInfo(info: profileInfo))
                    self.dispatcher.dispatch(action: FxADisplayAction.finishedFetchingUserInformation)
                }, onError: { err in
                    self.dispatcher.dispatch(action: ErrorAction(error: err))
                })
                .disposed(by: self.disposeBag)
    }

    private func deriveScopedKeyFromJWE(_ jwe: String) throws -> String {
        let jweString = try self.keyManager.decryptJWE(jwe)

        guard let jsonValue = try JSONSerialization.jsonObject(with: jweString.data(using: .utf8)!) as? [String: Any],
              let jweJSON = jsonValue[scope] as? [String: Any] else {
            throw FxAError.UnexpectedDataFormat
        }

        let jsonEncoding = try JSONSerialization.data(withJSONObject: jweJSON)
        guard let key = String(data: jsonEncoding, encoding: .utf8) else {
            throw FxAError.UnexpectedDataFormat
        }

        return key
    }

    private func validateQueryParamsForAuthCode(_ redirectParams: [URLQueryItem]) throws -> String {
        guard let state = redirectParams.first(where: { $0.name == "state" }) else {
            throw FxAError.RedirectNoState
        }

        guard let code = redirectParams.first(where: { $0.name == "code" }),
              let codeValue = code.value else {
            throw FxAError.RedirectNoCode
        }


        return codeValue
    }
}

// URL requests
extension FxAActionHandler {
    fileprivate func postTokenRequest(code: String) -> Single<OAuthInfo> {
        var request = URLRequest(url: self.tokenURL)
        let requestParams = [
            "grant_type": "authorization_code",
            "client_id": Constant.fxa.clientID,
            "code": code,
            "code_verifier": self.codeVerifier
        ]

        let oauthSingle = Single<OAuthInfo>.create { single in
            let disposable = Disposables.create()

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestParams)
            } catch {
                single(.error(error))
                return disposable
            }

            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")

            let task = self.session.dataTask(with: request) { data, _, error in
                if error != nil {
                    single(.error(error!))
                    return
                }

                guard let data = data else {
                    single(.error(FxAError.EmptyOAuthData))
                    return
                }

                var oauthInfo: OAuthInfo
                do {
                    oauthInfo = try JSONDecoder().decode(OAuthInfo.self, from: data)
                } catch {
                    single(.error(error))
                    return
                }

                single(.success(oauthInfo))
            }

            task.resume()

            return disposable
        }

        return oauthSingle
    }

    fileprivate func postProfileInfoRequest(accessToken: String) -> Single<ProfileInfo> {
        var request = URLRequest(url: self.profileInfoURL)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let profileInfoSingle = Single<ProfileInfo>.create { single in
            let disposable = Disposables.create()

            let task = self.session.dataTask(with: request) { data, _, error in
                if error != nil {
                    single(.error(error!))
                    return
                }

                guard let data = data else {
                    single(.error(FxAError.EmptyProfileInfoData))
                    return
                }

                var profileInfo: ProfileInfo
                do {
                    profileInfo = try JSONDecoder().decode(ProfileInfo.self, from: data)
                } catch {
                    single(.error(error))
                    return
                }

                single(.success(profileInfo))
            }

            task.resume()

            return disposable
        }

        return profileInfoSingle
    }
}
