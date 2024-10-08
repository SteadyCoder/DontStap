//
//  CoinEntity.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 16.03.2024.
//

import Combine
import Foundation
import RealityKit

final class CoinEntity: Entity {
    var model: Entity?

    static func loadCoinModel() -> AnyPublisher<CoinEntity, Error> {
        let boxExample = MeshResource.generateBox(size: 0.1, cornerRadius: 0.5)
        let material = SimpleMaterial(color: .green, isMetallic: false)
        let entity = ModelEntity(mesh: boxExample, materials: [material])
        entity.generateCollisionShapes(recursive: true)

    /// Area of coin in 2D
    static let circleArea: Float = .pi * CoinEntity.radius * CoinEntity.radius

    fileprivate enum Constants {
        static let modelName = "ARCoin"
    }

    private(set) var revealed = true
    private(set) var isSpinning = true

    static func loadCoin() -> AnyPublisher<CoinEntity, Error> {
        return Future { promise in
            guard let arCoin = try? Entity.load(named: Constants.modelName) else {
                return promise(.failure(CoinEntityLoadError.failedToLoad))
            }

            let coinEntity = CoinEntity()
            coinEntity.name = Constants.modelName
            coinEntity.addChild(arCoin)

            return promise(.success(coinEntity))
        }

        return result.eraseToAnyPublisher()
    }

    static func loadCoinSync() -> CoinEntity? {
        guard let arCoin = try? Entity.load(named: Constants.modelName) else {
            return nil
        }

        let coinEntity = CoinEntity()
        coinEntity.name = Constants.modelName
        coinEntity.addChild(arCoin)

        return coinEntity
    }
}

extension Entity {
    var isCoinEntity: Bool {
        return name == CoinEntity.Constants.modelName
    }
}
