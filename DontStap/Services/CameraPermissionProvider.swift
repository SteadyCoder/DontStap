//
//  CameraPermisionProvider.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 23.05.2024.
//

import AVFoundation
import Foundation
import Combine

protocol CameraPermissionProvider: AnyObject {
    func getCameraPermission() -> Future<Bool, Never>
}

class CameraPermissionManager: CameraPermissionProvider {
    func getCameraPermission() -> Future<Bool, Never> {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let isCameraAccessGranted: Bool

        switch currentStatus {
        case .notDetermined:
            isCameraAccessGranted = false
        case .restricted:
            isCameraAccessGranted = false
        case .denied:
            isCameraAccessGranted = false
        case .authorized:
            isCameraAccessGranted = true
        @unknown default:
            isCameraAccessGranted = false
        }

        return Future { promise in
            promise(.success(isCameraAccessGranted))
        }
    }
}
