import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var selectedFilter: WorkoutCategory?
    @State private var filterByCurrentFighter = false
    @State private var showingComparison = false

    private var filteredWorkouts: [SavedWorkout] {
        workoutStore.workouts.filter { w in
            let matchesCat = (selectedFilter == nil || w.category == selectedFilter)
            let matchesFighter = (!filterByCurrentFighter || w.profileID == workoutStore.activeProfileID)
            return matchesCat && matchesFighter
        }
    }

    var body: some View {
        let acwr = workoutStore.acuteChronicWorkloadRatio

        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("FIGHT CAMP READINESS (ACWR)")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f • %@", acwr.ratio, acwr.status))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(acwr.ratio > 1.4 ? .orange : .green)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("7-DAY TRIMP")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            let weekTRIMP = workoutStore.workouts
                                .filter { $0.startDate >= Date().addingTimeInterval(-7 * 86400) }
                                .reduce(0.0) { $0 + $1.trimpScore }
                            Text("\(Int(weekTRIMP))")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.cyan)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Toggle("Only \(workoutStore.activeProfile.name)", isOn: $filterByCurrentFighter)
                                .toggleStyle(.button)
                                .controlSize(.small)

                            Button("All Disciplines") { selectedFilter = nil }
                                .buttonStyle(.bordered)
                                .tint(selectedFilter == nil ? .green : .secondary)
                                .controlSize(.small)

                            ForEach(WorkoutCategory.allCases) { cat in
                                Button(cat.rawValue) { selectedFilter = cat }
                                    .buttonStyle(.bordered)
                                    .tint(selectedFilter == cat ? .green : .secondary)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                if filteredWorkouts.isEmpty {
                    ContentUnavailableView(
                        "No Workouts Logged",
                        systemImage: "heart.text.square",
                        description: Text("Recorded sessions save automatically to On My iPhone / Coospo Workout.")
                    )
                } else {
                    ForEach(filteredWorkouts) { workout in
                        NavigationLink {
                            WorkoutDetailView(workout: workout)
                        } label: {
                            workoutRow(workout)
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            workoutStore.delete(filteredWorkouts[idx])
                        }
                    }
                }
            }
            .navigationTitle("Training Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingComparison = true
                    } label: {
                        Label("Compare", systemImage: "square.stack.3d.up")
                    }
                    .disabled(workoutStore.workouts.count < 2)
                }
            }
            .sheet(isPresented: $showingComparison) {
                ComparisonView(initialBaselineWorkout: workoutStore.workouts.first)
            }
        }
    }

    private func workoutRow(_ workout: SavedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: workout.category.icon)
                    .foregroundStyle(.green)
                Text(workout.category.rawValue)
                    .font(.headline)
                Text("• \(workout.drillTag.rawValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                if workout.isCompressedArchive {
                    Image(systemName: "archivebox.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(formatDuration(workout.duration), systemImage: "clock")
                Label("\(workout.averageBPM) avg", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Label("\(Int(workout.activeCalories)) act", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
                if let hrr = workout.hrr60Drop {
                    Label("-\(hrr)", systemImage: "arrow.down.heart")
                        .foregroundStyle(.cyan)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
