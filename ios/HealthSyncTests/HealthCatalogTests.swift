import HealthKit
import Testing
@testable import HealthSync

struct HealthCatalogTests {
    @Test func metricNamesAreUnique() {
        let names = HealthMetric.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyDataGroupHasSomethingToUpload() {
        for group in DataGroup.allCases where group != .workouts {
            #expect(HealthMetric.all.contains { $0.group == group }, "\(group) has no metrics")
        }
        #expect(HealthMetric.readTypes(for: [.workouts]).contains(HKObjectType.workoutType()))
    }

    @Test func quantityUnitsMatchTheirHealthKitTypes() throws {
        for metric in HealthMetric.all {
            guard case let .quantity(identifier) = metric.typeID else { continue }
            let unit = try #require(metric.hkUnit, "\(metric.name) has no unit")
            #expect(HKQuantityType(identifier).is(compatibleWith: unit), "\(metric.name) can't be read in \(metric.unit ?? "")")
        }
    }

    @Test func categoryValuesGetReadableLabels() throws {
        let sleep = try #require(HealthMetric.all.first { $0.name == "sleepAnalysis" })
        let flow = try #require(HealthMetric.all.first { $0.name == "menstrualFlow" })
        let ovulation = try #require(HealthMetric.all.first { $0.name == "ovulationTestResult" })
        #expect(sleep.categoryLabel(HKCategoryValueSleepAnalysis.asleepDeep.rawValue) == "asleepDeep")
        #expect(flow.categoryLabel(3) == "medium")
        #expect(ovulation.categoryLabel(2) == "luteinizingHormoneSurge")
        #expect(flow.categoryLabel(99) == "unknown")
    }

    @Test func workoutTypesUseTheirCaseNames() {
        #expect(HKWorkoutActivityType.running.name == "running")
        #expect(HKWorkoutActivityType.highIntensityIntervalTraining.name == "highIntensityIntervalTraining")
    }
}
