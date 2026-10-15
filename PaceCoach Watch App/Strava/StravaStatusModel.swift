import Combine
import Foundation

@MainActor
final class StravaStatusModel: ObservableObject {
    @Published private(set) var presentation: StravaStatusPresentation

    private let reader: StravaStatusReader
    private var observations = Set<AnyCancellable>()

    init() {
        let store = try? PendingStravaUploadStore()
        let reader = StravaStatusReader(store: store, readCredentials: {
            do {
                return try WatchStravaCredentialStore().load() == nil ? .notSetUp : .setUp
            } catch {
                return .unavailable
            }
        })
        self.reader = reader
        presentation = reader.read()

        NotificationCenter.default.publisher(for: PendingStravaUploadStore.didChangeNotification)
            .filter { ($0.object as? URL) == store?.directory }
            // Do not read files synchronously inside the uploader's save/handoff.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)

        CompanionConnectivity.shared.$stravaProvisioningStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
    }

    func refresh() {
        let updated = reader.read()
        if updated != presentation { presentation = updated }
    }
}
