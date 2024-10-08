//
//  CoinCollectStoreProvider.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 22.05.2024.
//

import Foundation
import Combine

protocol CoinCollectStoreProvider: AnyObject {
    var collectedCoinsStream: AnyPublisher<[Coin], Never> { get }
    var cachedCoinsCount: Int? { get }

    func getCoins() -> AnyPublisher<[Coin], Never>
    func collectCoin(type: Coin.CoinType)
}

class CoinCollectStore: CoinCollectStoreProvider {
    private let userSession: UserSessionProvider

    let collectedCoinsStream: AnyPublisher<[Coin], Never>
    var cachedCoinsCount: Int? {
        userSession.user?.coins.count
    }

    init(userSession: UserSessionProvider) {
        self.userSession = userSession
        self.collectedCoinsStream = userSession.userStream
            .map({ user in
                return user?.coins ?? []
            })
            .eraseToAnyPublisher()
    }

    func getCoins() -> AnyPublisher<[Coin], Never> {
        return userSession.getCoins()
    }

    func collectCoin(type: Coin.CoinType) {
        if let promocodeMultiplier = userSession.user?.promocodes.max(by: { $0.multiplier < $1.multiplier })?.multiplier, !userSession.isGuestUser {
            var newCoins = [Coin]()
            for _ in 0..<promocodeMultiplier {
                newCoins.append(Coin(id: UUID(), type: type, state: .collected))
            }
            self.userSession.addCoins(newCoins)
        }
        else {
            let newCoin = Coin(id: UUID(), type: type, state: .collected)
            userSession.addCoin(newCoin)
        }
    }
}
