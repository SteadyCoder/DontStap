//
//  DataBaseProvider.swift
//  ARCoinCollect
//
//  Created by Ivan Tkachenko on 26.05.2024.
//

import Combine
import Foundation
import FirebaseDatabase
import FirebaseStorage

enum DatabaseProviderError: Error {
    case valueNotFound
}

protocol DatabaseProvider {
    var userStream: PassthroughSubject<User?, Never> { get }

    func storeUser(user: User) throws
    func observeUser(userId: String) -> AnyPublisher<User?, Never>
    func getUser(userId: String) -> AnyPublisher<User?, Error>

    func getPhoto(userId: String) -> AnyPublisher<Data, Error>
    func store(photoData: Data, with userId: String) -> AnyPublisher<Bool, Error>
    func deletePhoto(userId: String) -> AnyPublisher<Bool, Error>

    func getCoins(userId: String) -> AnyPublisher<[Coin], Never>

    func checkIfNicknameUnique(nickname: String) -> AnyPublisher<Bool, Never>

    func getPromocodes() -> AnyPublisher<[Promocode], Never>
    func getPromocodes() async throws -> [Promocode]
    func getPromocode(id: String) async throws -> Promocode
    func markPromocodeAsUsed(id: String, _ isUsed: Bool) async throws

    func delete(userId: String) -> AnyPublisher<Bool, Error>
}

class DatabaseManager: DatabaseProvider {
    private enum Constants {
        static let users = "users"
        static let userCoins = "userCoins"
        static let userProfileImages = "userProfileImages"
        static let maxImageSize: Int64 = 10 * 1024 * 1024

        static let promocodes = "promocodes"
    }

    private let databaseRef: DatabaseReference
    private let storageRef: StorageReference
    private let database: Database

    private var coinObserverRefHandle: UInt?
    private var coinStream = CurrentValueSubject<[Coin], Never>(.init())

    var userStream = PassthroughSubject<User?, Never>()
    private var userObserverRefHandle: UInt?
    private var photoObserverRefHandles = [UInt]()

    init() {
        self.database = Database.database(url: "https://dontstap-d59d3-default-rtdb.europe-west1.firebasedatabase.app")
        self.databaseRef = self.database.reference()
        self.storageRef = Storage.storage(url: "gs://dontstap-d59d3.appspot.com").reference()

        NotificationCenter.default.addObserver(self, selector: #selector(reconnectDatabaseIfNeeded), name: .networkReachabilityFlagsChanged, object: nil)
    }

    @objc private func reconnectDatabaseIfNeeded(_ notification: Notification) {
        switch Network.reachability.status {
        case .unreachable:
            database.goOffline()
        case .wwan:
            database.goOffline()
            database.goOnline()
            database.goOnline()
        case .wifi:
            database.goOffline()
            database.goOnline()
            database.goOnline()
        }

        print("Reachability Summary")
        print("Status:", Network.reachability.status)
        print("HostName:", Network.reachability.hostname ?? "nil")
        print("Reachable:", Network.reachability.isReachable)
        print("Wifi:", Network.reachability.isReachableViaWiFi)
    }
}

// MARK: - User functionality
extension DatabaseManager {
    func storeUser(user: User) throws {
        let jsonUserData = try JSONEncoder().encode(user)

        if let jsonDictionary = try JSONSerialization.jsonObject(with: jsonUserData) as? [String: Any] {
            let userQuery = "\(Constants.users)/\(user.id)"
            databaseRef.child(userQuery).setValue(jsonDictionary) { error, dbRef in
                print("user store process finished with error == \(error)")
            }
        }
    }

    func observeUser(userId: String) -> AnyPublisher<User?, Never> {
        userObserverRefHandle = self.databaseRef.observe(.value) { snapshot in
            let user = self.decodeUser(snapshot: snapshot, userId: userId)
            self.userStream.send(user)
        }

        return userStream.eraseToAnyPublisher()
    }

    func getUser(userId: String) -> AnyPublisher<User?, Error> {
        Future<User?, Error> { result in
            self.databaseRef.child(Constants.users).child(userId).getData { error, snapshot in
                if let snapshot, snapshot.exists() {
                    let user = self.decodeUser(snapshot: snapshot, userId: userId)
                    result(.success(user))
                }
                else if let error {
                    result(.failure(error))
                }
                else {
                    result(.failure(DatabaseProviderError.valueNotFound))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    func checkIfNicknameUnique(nickname: String) -> AnyPublisher<Bool, Never> {
        return Future<Bool, Never> { [weak self] promise in
            guard let self else { return }

            self.userObserverRefHandle = self.databaseRef.observe(.value) { snapshot in
                let users = self.decodeUsers(snapshot: snapshot)
                let isNicknameUnique = !users.contains(where: { $0.nickname == nickname })
                promise(.success(isNicknameUnique))
            }
        }
        .eraseToAnyPublisher()
    }

    func delete(userId: String) -> AnyPublisher<Bool, Error> {
        Future<Bool, Error> { result in
            self.databaseRef.child(Constants.users).child(userId).setValue([:]) { error, dbRef in
                if let error {
                    result(.failure(error))
                }
                else  {
                    result(.success(true))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    func store(photoData: Data, with userId: String) -> AnyPublisher<Bool, Error> {
        let profileImagePathRef = storageRef.child("\(Constants.userProfileImages)/\(userId).jpg")
        print("photo upload started")
        return Future<Bool, Error> { promise in
            profileImagePathRef.putData(photoData) { result in
                switch result {
                case .success:
                    print("photo did upload")
                    promise(.success(true))
                case .failure(let error):
                    print("photo failed upload")
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    func deletePhoto(userId: String) -> AnyPublisher<Bool, Error> {
        let profileImagePathRef = storageRef.child("\(Constants.userProfileImages)/\(userId).jpg")

        return Future<Bool, Error> { promise in
            profileImagePathRef.delete { deleteError in
                if let deleteError {
                    promise(.failure(deleteError))
                }
                else {
                    promise(.success(true))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    func getPhoto(userId: String) -> AnyPublisher<Data, Error> {
        print("photo download started \(Thread.isMainThread)")
        let profileImagePathRef = storageRef.child("\(Constants.userProfileImages)/\(userId).jpg")

        return Future<Data, Error> { promise in
            let downloadTask = profileImagePathRef.getData(maxSize: Constants.maxImageSize) { result in
                print("photo download result \(result) \(Thread.isMainThread)")
                promise(result)
            }
            downloadTask.observe(.progress) { snapshot in
                print("photo download progress \(snapshot.progress) \(Thread.isMainThread)")
            }
        }
        .eraseToAnyPublisher()
    }

    private func clearPhotoDownloadRefHandles() {
        photoObserverRefHandles.removeAll()
    }
}

// MARK: - Coins functionality
extension DatabaseManager {
    func storeCoins(_ coins: [Coin], with userId: String) {
        let coinsDictionary = coins.map({ JSONSerialization.dictionary(from: $0) })

        let coinsQuery = "\(Constants.users)/\(userId)/coins"
        databaseRef.child(coinsQuery).setValue(coinsDictionary)
    }

    func getCoins(userId: String) -> AnyPublisher<[Coin], Never> {
        Future<[Coin], Never> { result in
            self.databaseRef.child(Constants.users).child(userId).observeSingleEvent(of: .value) { snapshot in
                let user = self.decodeSingleUser(snapshot: snapshot, userId: userId)
                let coins = user?.coins ?? []
                result(.success(coins))
            }
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - Promocodes functionality
extension DatabaseManager {
    func getPromocodes() -> AnyPublisher<[Promocode], Never> {
        Future<[Promocode], Never> { result in
            self.databaseRef.child(Constants.promocodes).observeSingleEvent(of: .value) { snapshot in
                let promocodes = self.decodePromocodes(snapshot: snapshot)
                result(.success(promocodes))
            }
        }
        .eraseToAnyPublisher()
    }

    func getPromocodes() async throws -> [Promocode] {
        let newRef = database.reference(withPath: Constants.promocodes)
        let data = try await newRef.child(Constants.promocodes).getData()
        return decodePromocodes(snapshot: data)
    }

    func getPromocode(id: String) async throws -> Promocode {
        let promocodes = try await getPromocodes()
        if let promocode = promocodes.first(where: { $0.id.uuidString == id }) {
            return promocode
        }
        else {
            throw DatabaseProviderError.valueNotFound
        }
    }

    func markPromocodeAsUsed(id: String, _ isUsed: Bool) async throws {
        let id = id.lowercased()
        try await databaseRef.child("\(Constants.promocodes)/\(id)/isUsed").setValue(isUsed)
    }
}

extension DatabaseManager {
    private func decodeUser(snapshot: DataSnapshot, userId: String) -> User? {
        guard let dictionary = snapshot.value as? [String: Any],
              let usersDictionary = dictionary[Constants.users] as? [String: Any],
              let currentUserDictionary = usersDictionary[userId] as? [String: Any]
        else {
            return nil
        }

        guard let currentUserDictionaryData = try? JSONSerialization.data(withJSONObject: currentUserDictionary) else {
            return nil
        }

        return try? JSONDecoder().decode(User.self, from: currentUserDictionaryData)
    }

    private func decodeSingleUser(snapshot: DataSnapshot, userId: String) -> User? {
        guard let currentUserDictionary = snapshot.value as? [String: Any] else {
            return nil
        }

        guard let currentUserDictionaryData = try? JSONSerialization.data(withJSONObject: currentUserDictionary) else {
            return nil
        }

        return try? JSONDecoder().decode(User.self, from: currentUserDictionaryData)
    }

    private func decodeUsers(snapshot: DataSnapshot) -> [User] {
        guard let dictionary = snapshot.value as? [String: Any],
              let usersDictionary = dictionary[Constants.users] as? [String: Any]
        else {
            return []
        }

        var users = [User]()
        usersDictionary.forEach { key, value in
            guard let userDictionaryData = try? JSONSerialization.data(withJSONObject: value),
                  let user = try? JSONDecoder().decode(User.self, from: userDictionaryData)
            else {
                return
            }

            users.append(user)
        }

        return users
    }

    private func decodePromocodes(snapshot: DataSnapshot) -> [Promocode] {
        guard let dictionary = snapshot.value as? [String: Any],
              let promocodesDictionary = dictionary[Constants.promocodes] as? [String: Any]
        else {
            return []
        }

        let promocodes: [Promocode] = promocodesDictionary.compactMap { promocodeDict in
            guard let promocodeDictValue = promocodeDict.value as? [String: Any] else {
                return nil
            }
            guard let promocodeData = try? JSONSerialization.data(withJSONObject: promocodeDictValue),
                  let promocode = try? JSONDecoder().decode(Promocode.self, from: promocodeData)
            else {
                return nil
            }

            return promocode
        }

        return promocodes
    }
}

extension JSONSerialization {
    static func dictionary(from object: Encodable) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let json = try? encoder.encode(object),
            let dict = try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any] else {
                return nil
        }
        return dict
    }
}
