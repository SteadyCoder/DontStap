//
//  AppCheckService.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 13.06.2024.
//

import Foundation
import Firebase

class AppCheckService: NSObject, AppCheckProviderFactory {
  func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
    #if DEBUG
      // App Attest is not available on simulators.
      // Use a debug provider.
      return AppCheckDebugProvider(app: app)
    #else
      // Use App Attest provider on real devices.
      return AppAttestProvider(app: app)
    #endif
  }
}
