enum SeedingPolicyAction: Sendable, Equatable {
    case none
    case pause
    case setUploadLimit(Int64)
}
