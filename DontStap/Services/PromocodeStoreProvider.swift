//
//  PromocodeStoreProvider.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 09.06.2024.
//

import Combine
import Foundation

enum PromocodeStoreProviderError: Error, UserRepresentableError {
    case unexpectedError
    case invalidFormat
    case wrongPromocode

    case promocodeAlreadyUsed
    case userAlreadyUserPromocode

    var userErrorText: String {
        switch self {
        case .promocodeAlreadyUsed:
            return String(localized: "Promocode was already used by someone else 😢")
        case .userAlreadyUserPromocode:
            return String(localized: "You've already used this promocode 🙂")
        case .unexpectedError:
            return String.genericErrorText
        case .invalidFormat:
            return String(localized: "Promocode format is invalid, please check and try again.")
        case .wrongPromocode:
            return String(localized: "Promocode is incorrect.")
        }
    }
}

protocol PromocodeStoreProvider {
    func submitPromocode(_ promocode: String) async throws
}

class PromocodeStore: PromocodeStoreProvider {
    @Inject
    private var userSessionProvider: UserSessionProvider
    @Inject
    private var promocodesProvider: PromocodesProvider

    func submitPromocode(_ promocode: String) async throws {
        try await Task.sleep(for: .seconds(1.5))

        guard !promocode.isEmpty,
              let promocodeUuid = UUID(uuidString: promocode) else {
            throw PromocodeStoreProviderError.invalidFormat
        }

        let userPromocodes = try await promocodesProvider.getUserPromocodes()
        
        guard !userPromocodes.contains(where: { $0.id == promocodeUuid }) else {
            throw PromocodeStoreProviderError.userAlreadyUserPromocode
        }

        let promocode = try await promocodesProvider.getPromocode(id: promocodeUuid)

        guard !promocode.isUsed else {
            throw PromocodeStoreProviderError.promocodeAlreadyUsed
        }

        try await promocodesProvider.usePromocode(promocodeUuid)
        // mark promocode as used cause it will be only marked on service side as used here locally is still not used at this moment
        // to make it used and store correctly for user I mark it as used
        let promocodeMarkedAsUsed = promocode.update(isUsed: true)
        _ = userSessionProvider.addPromocode(promocodeMarkedAsUsed)
    }
}
