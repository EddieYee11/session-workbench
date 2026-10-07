import Foundation
@preconcurrency import HealthKit
import ComCore

@MainActor final class HealthReader {
    private let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private var types: Set<HKObjectType> {
        Set([HKObjectType.quantityType(forIdentifier: .stepCount)!, HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
             HKObjectType.quantityType(forIdentifier: .heartRate)!, HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
             HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, HKObjectType.workoutType()])
    }
    func requestPermission() async throws {
        guard available else { throw APIError(status: 0, detail: "此设备不支持健康数据") }
        try await store.requestAuthorization(toShare: [], read: types)
        UserDefaults.standard.set(true, forKey: "healthRequested")
    }
    func summary(days: Int) async throws -> JSON {
        let days = min(90, max(1, days)), end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
        let steps = try await statistic(.stepCount, unit: .count(), options: .cumulativeSum, start: start, end: end)
        let energy = try await statistic(.activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, start: start, end: end)
        let heart = try await statistic(.heartRate, unit: .count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end)
        let resting = try await statistic(.restingHeartRate, unit: .count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end)
        let sleep = try await samples(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, start: start, end: end)
        // HealthKit quantity aggregation merges sources. Sleep intervals are unioned so watch/phone don't double count.
        let intervals = sleep.compactMap { sample -> (Date, Date)? in
            guard let sample = sample as? HKCategorySample,
                  [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                   HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains(sample.value) else { return nil }
            return (max(start, sample.startDate), min(end, sample.endDate))
        }.sorted { $0.0 < $1.0 }
        var asleep: TimeInterval = 0; var interval: (Date, Date)?
        for next in intervals {
            if let current = interval, next.0 <= current.1 { interval = (current.0, max(current.1, next.1)) }
            else { if let current = interval { asleep += max(0, current.1.timeIntervalSince(current.0)) }; interval = next }
        }
        if let current = interval { asleep += max(0, current.1.timeIntervalSince(current.0)) }
        let workouts = try await samples(HKObjectType.workoutType(), start: start, end: end)
        return .object([
            "steps": steps, "active_energy_kcal": energy, "heart_rate_average": heart, "resting_heart_rate": resting,
            "sleep_hours": intervals.isEmpty ? .null : .number(asleep / 3600),
            "workouts": .array(workouts.compactMap { s in
                guard let w = s as? HKWorkout else { return nil }
                return .object(["id": .string(w.uuid.uuidString), "activity_type": .number(Double(w.workoutActivityType.rawValue)),
                                "start": .string(w.startDate.ISO8601Format()), "end": .string(w.endDate.ISO8601Format()), "duration_seconds": .number(w.duration)])
            }),
            "start": .string(start.ISO8601Format()), "end": .string(end.ISO8601Format()), "updated_at": .string(Date().ISO8601Format()),
            "source": .string("Apple HealthKit"), "deduplicated": .bool(true),
            "missing_reason": steps.isNull && energy.isNull && heart.isNull && resting.isNull && intervals.isEmpty && workouts.isEmpty ? .string("指定时间内无可用数据；可能尚无记录或未允许读取") : .null
        ])
    }
    private func statistic(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, options: HKStatisticsOptions, start: Date, end: Date) async throws -> JSON {
        let type = HKObjectType.quantityType(forIdentifier: identifier)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, result, error in
                if let error {
                    let failure = error as NSError
                    if failure.domain == HKErrorDomain && failure.code == HKError.Code.errorNoData.rawValue {
                        continuation.resume(returning: .null)
                    } else { continuation.resume(throwing: error) }
                    return
                }
                let quantity = options == .cumulativeSum ? result?.sumQuantity() : result?.averageQuantity()
                continuation.resume(returning: quantity.map { .number($0.doubleValue(for: unit)) } ?? .null)
            }
            store.execute(query)
        }
    }
    private func samples(_ type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }
}
