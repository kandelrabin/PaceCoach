import Foundation
import HealthKit

enum HealthKitAuthorization {
    enum Scope {
        case targetPaceWorkout
        case targetZoneProfile
        case targetZoneWorkout
        case workoutRoute
    }

    static let healthStore = HKHealthStore()

    @MainActor private static var inFlight: (id: UUID, task: Task<Void, Error>)?

    @MainActor
    static func ensureAuthorized(for scope: Scope) async throws {
        // Despite this legacy method name, success only means the permission
        // request was processed/already decided. It never proves read access.
        // Profile callers must invoke this from an explicit foreground action,
        // not as a prerequisite for every data refresh.
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AuthorizationError.healthDataUnavailable
        }

        let share: Set<HKSampleType>
        let read: Set<HKObjectType>
        switch scope {
        case .workoutRoute:
            let route = HKSeriesType.workoutRoute()
            // HealthKit requires workout authorization alongside route
            // authorization for both sharing and reading.
            share = [HKObjectType.workoutType(), route]
            read = [HKObjectType.workoutType(), route]
        case .targetZoneProfile:
            guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate),
                  let restingHeartRate = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
                throw AuthorizationError.healthDataUnavailable
            }
            share = []
            read = [heartRate, restingHeartRate, HKObjectType.workoutType()]
        case .targetPaceWorkout, .targetZoneWorkout:
            guard let speed = HKObjectType.quantityType(forIdentifier: .runningSpeed),
                  let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate),
                  let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) else {
                throw AuthorizationError.healthDataUnavailable
            }
            share = [HKObjectType.workoutType()]
            // Both modes use the same completed-workout reader. Do not depend
            // on permissions requested by the historical heart-rate profile.
            read = [HKObjectType.workoutType(), speed, heartRate, distance]
        }

        let status: HKAuthorizationRequestStatus
        do {
            status = try await healthStore.statusForAuthorizationRequest(toShare: share, read: read)
        } catch {
            log("status check failed; error=\(error)", scope: scope)
            throw error
        }
        switch status {
        case .unnecessary:
            // The user has already made a choice for every type. HealthKit does
            // not reveal whether read access was granted. Queries return only
            // available data and cannot distinguish denial from missing data.
            break
        case .shouldRequest:
            // A UI timeout cannot cancel HealthKit's native request. Retain it
            // until native completion; don't enqueue another sheet or wait for
            // it indefinitely. Already-decided workout scopes can proceed above.
            guard inFlight == nil else {
                log("request not started; another native request is still pending", scope: scope)
                throw AuthorizationError.requestStillPending
            }
            let id = UUID()
            let task = Task {
                do {
                    try await healthStore.requestAuthorization(toShare: share, read: read)
                } catch {
                    log("request failed; error=\(error)", scope: scope)
                    throw error
                }
            }
            inFlight = (id, task)
            defer {
                if inFlight?.id == id { inFlight = nil }
            }
            try await task.value
        case .unknown:
            throw AuthorizationError.unknownRequestStatus
        @unknown default:
            throw AuthorizationError.unknownRequestStatus
        }
    }

    private enum AuthorizationError: LocalizedError {
        case healthDataUnavailable
        case unknownRequestStatus
        case requestStillPending

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable: "Health data is unavailable on this device."
            case .unknownRequestStatus: "HealthKit could not determine authorization status."
            case .requestStillPending: "HealthKit still has a pending permission request. Complete it if shown, or check Health permissions. You can retry loading available data."
            }
        }
    }

    private static func log(_ message: @autoclosure () -> String, scope: Scope) {
        #if DEBUG
        switch scope {
        case .targetZoneProfile:
            print("[HeartRateProfile] profile authorization \(message())")
        case .targetZoneWorkout:
            print("[TargetZoneWorkout] workout authorization \(message())")
        case .targetPaceWorkout:
            break
        case .workoutRoute:
            break
        }
        #endif
    }
}
