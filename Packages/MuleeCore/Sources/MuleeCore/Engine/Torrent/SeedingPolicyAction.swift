enum SeedingPolicyAction: Sendable, Equatable {
    case none
    case pause
    case remove
    case setUploadLimit(Int64)
}
