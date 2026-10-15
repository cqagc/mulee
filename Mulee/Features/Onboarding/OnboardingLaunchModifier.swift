import SwiftUI

struct OnboardingLaunchModifier: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                OnboardingView()
            }
            .task(presentIfNeeded)
    }

    private func presentIfNeeded() {
        let usesSampleData: Bool
        #if DEBUG
        usesSampleData = DebugLaunchOptions.usesSampleData
        #else
        usesSampleData = false
        #endif
        guard OnboardingPolicy.claimPresentation(
            defaults: .standard, usesSampleData: usesSampleData,
            isRunningUnitTests: AppEnvironment.isRunningUnitTests
        ) else { return }
        isPresented = true
    }
}
