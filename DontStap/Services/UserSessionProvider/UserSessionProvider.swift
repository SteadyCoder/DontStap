import Combine
import Foundation
import UIKit

enum UserSessionError: Error, UserRepresentableError {
    case noExistingPhotoForUser
    case incorrectSignUp
    case failedToUploadPhoto
    case nicknameIsNotUnique

    var userErrorText: String {
        switch self {
        case .noExistingPhotoForUser:
            return String(localized: "You do not have a photo. Please try again.")
        case .incorrectSignUp:
            return String.genericErrorText
        case .failedToUploadPhoto:
            return String(localized: "Upload of photo failed, please try again.")
        case .nicknameIsNotUnique:
            return String(localized: "This nickname is already taken, please try another one.")
        }
    }
}

typealias UserInfo = (nickname: String?, photo: Data?)

protocol UserSessionProvider {
    var isGuestUser: Bool { get }
    var user: User? { get }
    var userCachedPhotoData: Data? { get }
    var userStream: AnyPublisher<User?, Never> { get }
    var userDidUploadPhotoStream: AnyPublisher<Bool, Never> { get }
    var userCollectedCoinsAmountStream: AnyPublisher<Int, Never> { get }
    var authToken: String? { get }

    func update(photo: Data) -> AnyPublisher<Bool, Error>

    func getCoins() -> AnyPublisher<[Coin], Never>
    func addCoin(_ coin: Coin)
    func addCoins(_ coins: [Coin])

    func getUserInfo() -> AnyPublisher<UserInfo, Never>
    func getUserInfo(ignoreCachedPhoto: Bool) -> AnyPublisher<UserInfo, Never>
    
    func getUserPhoto() -> AnyPublisher<Data, Error>
    func getUserPhoto(ignoreCachedPhoto: Bool) -> AnyPublisher<Data, Error>

    func addPromocode(_ promocode: Promocode) -> Bool

    func signUpSession(nickname: String, photo: Data?) -> AnyPublisher<Bool, Error>
    func signInSession(authToken: String, email: String?) -> AnyPublisher<AuthenticationStatus, Error>
    func signOutSession()
    func deleteAccount() -> AnyPublisher<Bool, Error>
}

class UserSessionService: UserSessionProvider {
    private let databaseProvider: DatabaseProvider
    private let keychainStore: KeychainStoreProvider
    private let userDefaultsProvider: UserDefaultsProvider

    private var userStreamCancellable: AnyCancellable?
    private var userFetchCancellable: AnyCancellable?
    private var uniqueNicknameCancellable: AnyCancellable?
    private var userPhotoUploadCancellable: AnyCancellable?
    private var userPhotoDownloadCancellable: AnyCancellable?

    init(
        userDefaultsProvider: UserDefaultsProvider,
        keychainStore: KeychainStoreProvider,
        databaseProvider: DatabaseProvider
    ) {
        self.userDefaultsProvider = userDefaultsProvider
        self.keychainStore = keychainStore
        self.databaseProvider = databaseProvider

        loadUserInitialState()
    }
    
    private var compressPhotoCancellable: AnyCancellable?
    private var uploadPhotoCancellable: AnyCancellable?
    private var deleteUserPhotoCancellable: AnyCancellable?

    private(set) var userCachedPhotoData: Data?
    private(set) var user: User?
    var userStream: AnyPublisher<User?, Never> {
        guard let userId = user?.id else {
            return Just<User?>(nil)
                .eraseToAnyPublisher()
        }
        
        return databaseProvider.observeUser(userId: userId)
    }
    var userDidUploadPhotoStream: AnyPublisher<Bool, Never> {
        return _userDidUploadPhotoStream
            .eraseToAnyPublisher()
    }

    var userCollectedCoinsAmountStream: AnyPublisher<Int, Never> {
        return _userCollectedCoinsAmountStream
            .eraseToAnyPublisher()
    }

    private var _userStream: PassthroughSubject<User?, Never> {
        return databaseProvider.userStream
    }

    private let _userDidUploadPhotoStream = PassthroughSubject<Bool, Never>()
    private let _userCollectedCoinsAmountStream = CurrentValueSubject<Int, Never>(0)

    var isGuestUser: Bool {
        !(authToken != nil && (user?.status ?? .guest) != .guest)
    }

    var authToken: String? {
        keychainStore.getUserToken()
    }

    func signUpSession(nickname: String, photo: Data?) -> AnyPublisher<Bool, Error> {
        guard let authToken = authToken else {
            return Fail(error: UserSessionError.incorrectSignUp)
                .eraseToAnyPublisher()
        }
        print("sign up started")

        return Future<Bool, Error> { [weak self] promise in
            guard let self else {
                promise(.failure(GenericError.genericError))
                return
            }

            uniqueNicknameCancellable = databaseProvider.checkIfNicknameUnique(nickname: nickname)
                .sink { isUnique in
                    if isUnique {
                        print("sign up nickname unique")
                        if let photo {
                            print("sign up photo upload started")
                            self.userPhotoUploadCancellable = self.update(photo: photo)
                                .sink { completion in
                                    switch completion {
                                    case .finished:
                                        break
                                    case .failure(let error):
                                        print("sign up photo upload failed")
                                        promise(.failure(error))
                                    }
                                } receiveValue: { isPhotoUploaded in
                                    if isPhotoUploaded {
                                        print("sign up finished")
                                        self.update(authToken: authToken, status: .signedIn, email: self.user?.email, nickname: nickname)
                                        promise(.success(true))
                                    }
                                    else {
                                        print("sign up failed")
                                        promise(.failure(UserSessionError.failedToUploadPhoto))
                                    }
                                }
                            return
                        }
                        else {
                            print("sign up finished without photo upload")
                            self.update(authToken: authToken, status: .signedIn, email: self.user?.email, nickname: nickname)
                            promise(.success(true))
                            return
                        }
                    }
                    print("sign up failed nickname not unique")
                    promise(.failure(UserSessionError.nicknameIsNotUnique))
                }
        }
        .eraseToAnyPublisher()
    }

    func signInSession(authToken: String, email: String?) -> AnyPublisher<AuthenticationStatus, Error> {
        try? keychainStore.storeUserToken(authToken)
        update(authToken: authToken)
        if let email {
            update(email: email)
        }

        return databaseProvider.getUser(userId: UIDevice.current.identifierForVendor!.uuidString)
            .map { remoteUser in
                if let remoteUser, remoteUser.nickname != nil {
                    self.update(status: .signedIn)
                    return .signedIn
                }
                return .redirectToSignUp
            }
            .eraseToAnyPublisher()
    }

    func signOutSession() {
        update(status: .guest)
        keychainStore.deleteUserToken()
        userCachedPhotoData = nil
    }
    
    func deleteAccount() -> AnyPublisher<Bool, Error> {
        guard let user else {
            return Fail<Bool, any Error>(error: UserSessionError.noExistingPhotoForUser)
                .eraseToAnyPublisher()
        }

        return Future<Bool, Error> { [weak self] result in
            guard let self else {
                return
            }
            deleteUserPhotoCancellable = Publishers.CombineLatest(databaseProvider.deletePhoto(userId: user.id), databaseProvider.delete(userId: user.id))
                .sink { [weak self] completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        let nsError = error as NSError
                        // Error that indicates that user just doesn't have photo , that's why it wasn't deleted
                        if let underlyingNSError = nsError.underlyingErrors.first as? NSError,
                           underlyingNSError.code == 404 {
                            self?.deleteUserAccountCachedData()
                            result(.success(true))
                        }
                        else {
                            result(.failure(error))
                        }
                    }
                } receiveValue: { [weak self] isPhotoDeleted, isUserDeleted in
                    if isPhotoDeleted, isUserDeleted {
                        self?.deleteUserAccountCachedData()
                    }
                    result(.success(isPhotoDeleted && isUserDeleted))
                }
        }
        .eraseToAnyPublisher()
    }

    private func deleteUserAccountCachedData() {
        guard (user?.id) != nil else {
            return
        }

        keychainStore.deleteUserToken()
        keychainStore.deleteUser()

        let deviceId = UIDevice.current.identifierForVendor!
        let emptyUser = User(id: deviceId.uuidString)
        user = emptyUser
        update(status: .guest)

        _userStream.send(user)

        userCachedPhotoData = nil
    }

    private func loadUserInitialState() {
        if let storedUser = keychainStore.getUser(),
           let deviceId = UIDevice.current.identifierForVendor,
           storedUser.id == deviceId.uuidString {
            update(user: storedUser)
        }
        else {
            let deviceId = UIDevice.current.identifierForVendor!
            userFetchCancellable = databaseProvider.getUser(userId: deviceId.uuidString)
                .sink(receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(_):
                        // if this call fails it means that user has never created on this device account
                        // and remote data is not available, so we can just make him as fresh local user. after sign in the data should update
                        let newFreshLocalUser = User(id: deviceId.uuidString)
                        self?.update(user: newFreshLocalUser)
                    }
                }, receiveValue: { [weak self] remoteUser in
                    guard let self else {
                        return
                    }

                    if let remoteUser {
                        update(user: remoteUser, withDatabaseUpdate: false)
                    }
                    else {
                        let newFreshUser = User(id: deviceId.uuidString)
                        update(user: newFreshUser)
                    }
                })
        }
    }
}

extension UserSessionService {
    func update(email: String) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: email,
            nickname: user.nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: user.status,
            authToken: user.authToken
        )

        update(user: newUser)
    }

    func update(photo: Data) -> AnyPublisher<Bool, Error> {
        guard let user else {
            return Fail(error: UserSessionError.failedToUploadPhoto)
                .eraseToAnyPublisher()
        }

        return Future<Bool, Error> { [weak self] result in
            let compressedPhoto = UIImage(data: photo)?.jpegData(compressionQuality: 0.5)
            let photoToUpload = compressedPhoto ?? photo
            self?.uploadPhotoCancellable = self?.databaseProvider.store(photoData: photoToUpload, with: user.id)
                .sink(receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let failure):
                        result(.failure(failure))
                    }
                }, receiveValue: { [weak self] success in
                    self?.userCachedPhotoData = photoToUpload
                    result(.success(success))
                    self?._userDidUploadPhotoStream.send(true)
                })
        }
        .eraseToAnyPublisher()
    }

    private func deleteUserPhoto() -> AnyPublisher<Bool, Error> {
        guard let userId = user?.id else {
            return Fail(error: UserSessionError.noExistingPhotoForUser)
                .eraseToAnyPublisher()
        }

        userCachedPhotoData = nil
        return databaseProvider.deletePhoto(userId: userId)
    }

    func getCoins() -> AnyPublisher<[Coin], Never> {
        guard let userId = user?.id else {
            return Just([Coin]())
                .eraseToAnyPublisher()
        }
        return databaseProvider.getCoins(userId: userId)
    }

    func addCoin(_ coin: Coin) {
        guard let user else {
            return
        }

        var newCoins = user.coins
        newCoins.append(coin)
        
        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: user.nickname,
            coins: newCoins,
            promocodes: user.promocodes,
            status: user.status,
            authToken: user.authToken
        )

        update(user: newUser)
    }

    func addCoins(_ coins: [Coin]) {
        guard let user else {
            return
        }

        var newCoins = user.coins
        newCoins.append(contentsOf: coins)

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: user.nickname,
            coins: newCoins,
            promocodes: user.promocodes,
            status: user.status,
            authToken: user.authToken
        )

        update(user: newUser)
    }

    func getUserInfo() -> AnyPublisher<UserInfo, Never> {
        return getUserInfo(ignoreCachedPhoto: false)
    }

    func getUserInfo(ignoreCachedPhoto: Bool) -> AnyPublisher<UserInfo, Never> {
        guard !isGuestUser else {
            return Just<UserInfo>((nil, nil))
                .eraseToAnyPublisher()
        }

        return getUserPhoto(ignoreCachedPhoto: ignoreCachedPhoto)
            .map { [weak self] photoData in
                return (self?.user?.nickname, photoData)
            }
            .replaceError(with: (user?.nickname, nil))
            .eraseToAnyPublisher()
    }

    func getUserPhoto() -> AnyPublisher<Data, any Error> {
        getUserPhoto(ignoreCachedPhoto: false)
    }

    func getUserPhoto(ignoreCachedPhoto: Bool) -> AnyPublisher<Data, any Error> {
        if !ignoreCachedPhoto, let userCachedPhotoData {
            return Future<Data, Error> { promise in
                promise(.success(userCachedPhotoData))
            }
            .eraseToAnyPublisher()
        }

        guard let userId = user?.id, authToken != nil else {
            return Fail(error: UserSessionError.noExistingPhotoForUser)
                .eraseToAnyPublisher()
        }

        let publisher = databaseProvider.getPhoto(userId: userId)
        userPhotoDownloadCancellable = publisher
            .sink(receiveCompletion: { _ in }) { [weak self] photoData in
            self?.userCachedPhotoData = photoData
        }
        return publisher
    }

    func addPromocode(_ promocode: Promocode) -> Bool {
        guard let user else {
            return false
        }

        guard !user.promocodes.contains(where: { $0.id == promocode.id }) else {
            return false
        }

        var newPromocodes = user.promocodes
        newPromocodes.append(promocode)

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: user.nickname,
            coins: user.coins,
            promocodes: newPromocodes,
            status: user.status,
            authToken: user.authToken
        )

        update(user: newUser)
        return true 
    }
}

// MARK: Helper methods
extension UserSessionService {
    private func update(user: User, withDatabaseUpdate: Bool = true) {
        self.user = user
        try? keychainStore.storeUser(user: user)
        if withDatabaseUpdate {
            try? databaseProvider.storeUser(user: user)
        }

        if _userCollectedCoinsAmountStream.value != user.coins.count {
            _userCollectedCoinsAmountStream.send(user.coins.count)
        }
    }

    private func update(authToken: String, status: User.Status, email: String?, nickname: String?) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: email,
            nickname: nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: status,
            authToken: authToken
        )

        update(user: newUser)
    }

    private func update(authToken: String, status: User.Status) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: user.nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: status,
            authToken: authToken
        )

        update(user: newUser)
    }

    private func update(authToken: String, status: User.Status, nickname: String) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: status,
            authToken: authToken
        )

        update(user: newUser)
    }

    private func update(authToken: String?) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: user.nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: user.status,
            authToken: authToken
        )

        update(user: newUser)
    }

    private func update(status: User.Status) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: user.nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: status,
            authToken: user.authToken
        )

        update(user: newUser)
    }

    private func update(nickname: String) {
        guard let user else {
            return
        }

        let newUser = User(
            id: user.id,
            email: user.email,
            nickname: nickname,
            coins: user.coins,
            promocodes: user.promocodes,
            status: user.status,
            authToken: user.authToken
        )

        update(user: newUser)
    }
}
