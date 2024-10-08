//
//  PromocodesProvider.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 13.06.2024.
//

import Foundation

protocol PromocodesProvider {
    func getAllPromocodes() async throws -> [Promocode]
    func getUserPromocodes() async throws -> [Promocode]
    func getPromocode(id: Promocode.ID) async throws -> Promocode
    func usePromocode(_ id: Promocode.ID) async throws
}

class PromocodesService: PromocodesProvider {
    @Inject
    private var databaseProvider: DatabaseProvider
    @Inject
    private var userSessionProvider: UserSessionProvider
    
    func getAllPromocodes() async throws -> [Promocode] {
        try await databaseProvider.getPromocodes()
    }

    func getUserPromocodes() async throws -> [Promocode] {
        return userSessionProvider.user?.promocodes ?? []
    }

    func getPromocode(id: Promocode.ID) async throws -> Promocode {
        try await databaseProvider.getPromocode(id: id.uuidString)
    }

    func usePromocode(_ id: Promocode.ID) async throws {
        try await databaseProvider.markPromocodeAsUsed(id: id.uuidString, true)
    }
}
