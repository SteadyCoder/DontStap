//
//  AuthenticationProvider.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 18.04.2024.
//

import AuthenticationServices
import Combine
import Foundation

enum AuthenticationProviderError: Error, UserRepresentableError {
    case noCredentials
    case sessionNotStartedProperly

    var userErrorText: String {
        switch self {
        case .noCredentials:
            return String.genericErrorText
        case .sessionNotStartedProperly:
            return String.genericErrorText
        }
    }
}

protocol AuthenticationProvider {
    func authenticationAppLaunch()
    func authenticate(with authorization: ASAuthorization) -> AnyPublisher<AuthenticationStatus, Error>
    func authenticateSession(nickname: String, profileImage: Data?) -> AnyPublisher<Bool, Error>
}

enum AuthenticationStatus {
    case signedIn
    case redirectToSignUp
}

class AuthenticationService: AuthenticationProvider {
    private let userSessionProvider: UserSessionProvider
    private let coinCollectStoreProvider: CoinCollectStoreProvider

    init(userSessionProvider: UserSessionProvider, coinCollectStoreProvider: CoinCollectStoreProvider) {
        self.userSessionProvider = userSessionProvider
        self.coinCollectStoreProvider = coinCollectStoreProvider
    }

    func authenticationAppLaunch() {
        if let authToken = userSessionProvider.authToken {
            let appleIDProvider = ASAuthorizationAppleIDProvider()
            appleIDProvider.getCredentialState(forUserID: authToken) { credentialState, error in
                switch credentialState {
                case .revoked:
                    self.userSessionProvider.signOutSession()
                case .authorized, .notFound, .transferred:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    func authenticate(with authorization: ASAuthorization) -> AnyPublisher<AuthenticationStatus, Error> {
        if let appleIdCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            // Create an account in your system. "002001.5774d62a35ce45ba8c8225fe489fc075.1629"
            let userIdentifier = appleIdCredential.user
            let email = appleIdCredential.email

            return userSessionProvider.signInSession(authToken: userIdentifier, email: email)
                .eraseToAnyPublisher()
        }
        else {
            return Fail(error: AuthenticationProviderError.noCredentials)
                .eraseToAnyPublisher()
        }
    }

    func authenticateSession(nickname: String, profileImage: Data?) -> AnyPublisher<Bool, Error> {
        return userSessionProvider.signUpSession(nickname: nickname, photo: profileImage)
            .eraseToAnyPublisher()
    }
}
