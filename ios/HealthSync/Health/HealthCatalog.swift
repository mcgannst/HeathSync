import HealthKit

enum DataGroup: String, CaseIterable, Identifiable, Sendable {
    case activity, heart, sleep, body, vitals, workouts, mindfulnessAndCycle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .heart: "Heart"
        case .sleep: "Sleep"
        case .body: "Body"
        case .vitals: "Vitals"
        case .workouts: "Workouts"
        case .mindfulnessAndCycle: "Mindfulness & Cycle"
        }
    }

    var summary: String {
        switch self {
        case .activity: "Steps, distance, energy, exercise and stand time, flights climbed"
        case .heart: "Heart rate, resting and walking heart rate, HRV, blood oxygen, breathing rate"
        case .sleep: "Time asleep, sleep stages, time in bed"
        case .body: "Weight, body fat, BMI, lean body mass"
        case .vitals: "Blood pressure, blood glucose, body and wrist temperature, VO2 max"
        case .workouts: "Type, duration, distance and energy of each workout"
        case .mindfulnessAndCycle: "Mindful minutes, cycle tracking, sound exposure"
        }
    }

    var systemImage: String {
        switch self {
        case .activity: "figure.walk"
        case .heart: "heart.fill"
        case .sleep: "bed.double.fill"
        case .body: "figure.stand"
        case .vitals: "waveform.path.ecg"
        case .workouts: "figure.run"
        case .mindfulnessAndCycle: "leaf.fill"
        }
    }
}

/// One HealthKit sample type that is uploaded. `name` is what the server and Claude see.
struct HealthMetric: Identifiable, Sendable {
    enum TypeID: Sendable {
        case quantity(HKQuantityTypeIdentifier)
        case category(HKCategoryTypeIdentifier)
    }

    /// How daily summaries are computed.
    enum Kind: Sendable {
        /// Daily total (sum), e.g. steps.
        case cumulative
        /// Daily average, minimum, maximum and latest, e.g. heart rate.
        case discrete
        /// Nightly sleep stages.
        case sleep
        /// Daily total minutes of category samples, e.g. mindful sessions.
        case duration
        /// Individual samples only.
        case category
    }

    let name: String
    let title: String
    let typeID: TypeID
    let group: DataGroup
    let kind: Kind
    /// HealthKit unit string, also sent to the server as the unit label.
    let unit: String?
    /// HealthKit stores percentages as 0–1; the server stores 0–100.
    let scale: Double

    var id: String { name }

    var sampleType: HKSampleType {
        switch typeID {
        case let .quantity(identifier): HKQuantityType(identifier)
        case let .category(identifier): HKCategoryType(identifier)
        }
    }

    var hkUnit: HKUnit? {
        guard case .quantity = typeID, let unit else { return nil }
        return HKUnit(from: unit == "%" ? "%" : unit)
    }

    private init(
        _ name: String, _ title: String, _ typeID: TypeID, _ group: DataGroup, _ kind: Kind,
        unit: String? = nil, scale: Double = 1
    ) {
        self.name = name
        self.title = title
        self.typeID = typeID
        self.group = group
        self.kind = kind
        self.unit = unit
        self.scale = scale
    }

    /// Label stored for a category sample's value.
    func categoryLabel(_ value: Int) -> String {
        guard case let .category(identifier) = typeID else { return "present" }
        switch identifier {
        case .sleepAnalysis:
            switch HKCategoryValueSleepAnalysis(rawValue: value) {
            case .inBed: return "inBed"
            case .awake: return "awake"
            case .asleepCore: return "asleepCore"
            case .asleepDeep: return "asleepDeep"
            case .asleepREM: return "asleepREM"
            case .asleepUnspecified: return "asleepUnspecified"
            default: return "unknown"
            }
        case .menstrualFlow:
            return Self.label(value, ["unspecified", "light", "medium", "heavy", "none"])
        case .ovulationTestResult:
            return Self.label(value, ["negative", "luteinizingHormoneSurge", "indeterminate", "estrogenSurge"])
        default:
            return "present"
        }
    }

    /// HealthKit category raw values start at 1 for these types.
    private static func label(_ value: Int, _ labels: [String]) -> String {
        labels.indices.contains(value - 1) ? labels[value - 1] : "unknown"
    }
}

extension HealthMetric {
    static let all: [HealthMetric] = [
        // Activity
        .init("stepCount", "Steps", .quantity(.stepCount), .activity, .cumulative, unit: "count"),
        .init("distanceWalkingRunning", "Walking + Running Distance", .quantity(.distanceWalkingRunning), .activity, .cumulative, unit: "m"),
        .init("distanceCycling", "Cycling Distance", .quantity(.distanceCycling), .activity, .cumulative, unit: "m"),
        .init("activeEnergyBurned", "Active Energy", .quantity(.activeEnergyBurned), .activity, .cumulative, unit: "kcal"),
        .init("basalEnergyBurned", "Resting Energy", .quantity(.basalEnergyBurned), .activity, .cumulative, unit: "kcal"),
        .init("appleExerciseTime", "Exercise Time", .quantity(.appleExerciseTime), .activity, .cumulative, unit: "min"),
        .init("appleStandTime", "Stand Time", .quantity(.appleStandTime), .activity, .cumulative, unit: "min"),
        .init("flightsClimbed", "Flights Climbed", .quantity(.flightsClimbed), .activity, .cumulative, unit: "count"),

        // Heart
        .init("heartRate", "Heart Rate", .quantity(.heartRate), .heart, .discrete, unit: "count/min"),
        .init("restingHeartRate", "Resting Heart Rate", .quantity(.restingHeartRate), .heart, .discrete, unit: "count/min"),
        .init("walkingHeartRateAverage", "Walking Heart Rate", .quantity(.walkingHeartRateAverage), .heart, .discrete, unit: "count/min"),
        .init("heartRateVariabilitySDNN", "Heart Rate Variability", .quantity(.heartRateVariabilitySDNN), .heart, .discrete, unit: "ms"),
        .init("oxygenSaturation", "Blood Oxygen", .quantity(.oxygenSaturation), .heart, .discrete, unit: "%", scale: 100),
        .init("respiratoryRate", "Respiratory Rate", .quantity(.respiratoryRate), .heart, .discrete, unit: "count/min"),

        // Sleep
        .init("sleepAnalysis", "Sleep", .category(.sleepAnalysis), .sleep, .sleep),

        // Body
        .init("bodyMass", "Weight", .quantity(.bodyMass), .body, .discrete, unit: "kg"),
        .init("bodyFatPercentage", "Body Fat", .quantity(.bodyFatPercentage), .body, .discrete, unit: "%", scale: 100),
        .init("bodyMassIndex", "Body Mass Index", .quantity(.bodyMassIndex), .body, .discrete, unit: "count"),
        .init("leanBodyMass", "Lean Body Mass", .quantity(.leanBodyMass), .body, .discrete, unit: "kg"),

        // Vitals
        .init("bloodPressureSystolic", "Blood Pressure (Systolic)", .quantity(.bloodPressureSystolic), .vitals, .discrete, unit: "mmHg"),
        .init("bloodPressureDiastolic", "Blood Pressure (Diastolic)", .quantity(.bloodPressureDiastolic), .vitals, .discrete, unit: "mmHg"),
        .init("bloodGlucose", "Blood Glucose", .quantity(.bloodGlucose), .vitals, .discrete, unit: "mg/dL"),
        .init("bodyTemperature", "Body Temperature", .quantity(.bodyTemperature), .vitals, .discrete, unit: "degC"),
        .init("appleSleepingWristTemperature", "Sleeping Wrist Temperature", .quantity(.appleSleepingWristTemperature), .vitals, .discrete, unit: "degC"),
        .init("vo2Max", "VO2 Max", .quantity(.vo2Max), .vitals, .discrete, unit: "ml/(kg*min)"),

        // Mindfulness & cycle
        .init("mindfulSession", "Mindful Minutes", .category(.mindfulSession), .mindfulnessAndCycle, .duration),
        .init("menstrualFlow", "Menstrual Flow", .category(.menstrualFlow), .mindfulnessAndCycle, .category),
        .init("intermenstrualBleeding", "Spotting", .category(.intermenstrualBleeding), .mindfulnessAndCycle, .category),
        .init("ovulationTestResult", "Ovulation Test", .category(.ovulationTestResult), .mindfulnessAndCycle, .category),
        .init("environmentalAudioExposure", "Environmental Sound Levels", .quantity(.environmentalAudioExposure), .mindfulnessAndCycle, .discrete, unit: "dBASPL"),
        .init("headphoneAudioExposure", "Headphone Audio Levels", .quantity(.headphoneAudioExposure), .mindfulnessAndCycle, .discrete, unit: "dBASPL"),
    ]

    static func title(for name: String) -> String {
        all.first { $0.name == name }?.title ?? name
    }

    static func observedTypes(for groups: Set<DataGroup>) -> [HKSampleType] {
        var types = all.filter { groups.contains($0.group) }.map(\.sampleType)
        if groups.contains(.workouts) {
            types.append(HKObjectType.workoutType())
        }
        return types
    }

    static func readTypes(for groups: Set<DataGroup>) -> Set<HKObjectType> {
        Set(observedTypes(for: groups))
    }
}
