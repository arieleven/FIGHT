import SwiftUI

/// First launch: three quick screens instead of a long profile form.
struct OnboardingView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fight.onboarded") private var onboarded = false

    @State private var page = 0
    @State private var name = ""
    @State private var age = 25
    @State private var weightText = ""
    @State private var showingScanner = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                aboutYou.tag(0)
                strap.tag(1)
                ready.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                advance()
            } label: {
                Text(page == 2 ? "Start Training" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .padding()
        }
        .sheet(isPresented: $showingScanner) {
            DeviceScannerSheet()
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            let p = workoutStore.activeProfile
            name = p.name == "Fighter" ? "" : p.name
            age = p.age
            weightText = WeightUnits.number(p.weightKg, p.useImperial)
        }
        .interactiveDismissDisabled()
    }

    private var aboutYou: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FIGHT").font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(.red)
                    Text("Train with data. Tell us a little about you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Your name", text: $name)
                    .textContentType(.givenName)
                Stepper("Age: \(age)", value: $age, in: 13...85)
                HStack {
                    Text("Weight")
                    Spacer()
                    TextField("Weight", text: $weightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                    WeightUnitChip(text: $weightText)
                }
            } footer: {
                Text("Used for heart-rate zones and calories. You can change it any time in You.")
            }
        }
    }

    private var strap: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: bleManager.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 64))
                .foregroundStyle(bleManager.isConnected ? .green : .red)
            Text(bleManager.isConnected ? "Connected to \(bleManager.connectedDeviceName)" : "Connect your heart-rate strap")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Any Bluetooth chest strap, armband or watch in broadcast mode works. Put it on and wet the sensor.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !bleManager.isConnected {
                Button("Find My Strap") { showingScanner = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Text("No strap yet? Skip this. You can still time rounds and use the bag coach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(32)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("You're ready").font(.largeTitle.weight(.heavy))
            tip("heart.fill", "Train", "Press Start. FIGHT remembers your setup for next time.")
            tip("gauge.with.dots.needle.67percent", "Coach", "Tells you each day whether to train hard, go easy or rest. It gets smarter with every session.")
            tip("calendar.badge.clock", "Got a fight?", "Set the date in Coach for a camp plan and weight cut.")
            tip("square.and.arrow.up", "Share", "Post your progress straight to your Instagram story.")
            Spacer()
        }
        .padding(32)
    }

    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.red).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func advance() {
        if page == 0 { saveProfile() }
        if page < 2 {
            withAnimation { page += 1 }
        } else {
            onboarded = true
            dismiss()
        }
    }

    private func saveProfile() {
        var p = workoutStore.activeProfile
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { p.name = trimmed }
        p.age = age
        if let raw = Double(weightText.replacingOccurrences(of: ",", with: ".")) {
            let kg = WeightUnits.toKg(raw, p.useImperial)
            if (35...200).contains(kg) { p.weightKg = kg }
        }
        p.sanitize()
        workoutStore.activeProfile = p
    }
}

/// Shows onboarding on a true first launch, and offers the morning readiness check once a day before noon.
struct FirstRunModifier: ViewModifier {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @AppStorage("fight.onboarded") private var onboarded = false
    @AppStorage("fight.morningOffered") private var morningOffered = ""
    @State private var showingOnboarding = false
    @State private var offerMorningCheck = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showingOnboarding) {
                OnboardingView()
            }
            .alert("Good morning", isPresented: $offerMorningCheck) {
                Button("Check Readiness") {
                    navigation.selectedTab = .coach
                    navigation.requestReadinessCheck = true
                }
                Button("Not Today", role: .cancel) {}
            } message: {
                Text("Take the 2-minute readiness check so your coach can plan today.")
            }
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !onboarded {
                    let fresh = workoutStore.workouts.isEmpty && workoutStore.profiles.count == 1
                        && workoutStore.activeProfile.name == "Fighter"
                    if fresh {
                        showingOnboarding = true
                        return
                    }
                    onboarded = true
                }
                offerMorningCheckIfNeeded()
            }
    }

    private func offerMorningCheckIfNeeded() {
        let now = Date()
        let today = now.formatted(.iso8601.year().month().day())
        guard Calendar.current.component(.hour, from: now) < 12, morningOffered != today else { return }
        let checkedToday = workoutStore.activeReadings.contains { Calendar.current.isDateInToday($0.date) }
        morningOffered = today
        if !checkedToday { offerMorningCheck = true }
    }
}
