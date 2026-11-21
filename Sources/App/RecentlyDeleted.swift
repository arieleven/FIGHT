import SwiftUI

/// Deleted fighters and workouts, kept for 30 days, plus sessions from fighters that no longer exist.
struct RecentlyDeletedView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var confirmEmpty = false

    var body: some View {
        List {
            if !workoutStore.foundFighters.isEmpty {
                Section {
                    ForEach(workoutStore.foundFighters) { f in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.headline)
                                Text("\(f.sessions) session\(f.sessions == 1 ? "" : "s") found").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { workoutStore.restore(f) }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                        }
                    }
                } header: {
                    Text("Found sessions")
                } footer: {
                    Text("These sessions belong to a fighter that was deleted. Restore brings the fighter back with their history.")
                }
            }

            if !workoutStore.deletedProfiles.isEmpty {
                Section("Fighters") {
                    ForEach(workoutStore.deletedProfiles) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.profile.name).font(.headline)
                                Text(daysLeft(d.deletedAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { workoutStore.restore(d) }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                        }
                    }
                }
            }

            let trash = workoutStore.trash.filter { w in !workoutStore.deletedProfiles.contains { $0.id == w.profileID } }
            if !trash.isEmpty {
                Section("Workouts") {
                    ForEach(trash) { w in
                        HStack {
                            Image(systemName: w.category.icon).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(w.category.rawValue) · \(Int(w.duration / 60)) min").font(.subheadline.weight(.semibold))
                                Text("\(w.startDate.formatted(date: .abbreviated, time: .shortened)) · \(daysLeft(w.deletedAt ?? Date()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { workoutStore.restore(w) }
                                .buttonStyle(.bordered)
                                .tint(.green)
                        }
                    }
                }
            }

            if !workoutStore.trash.isEmpty || !workoutStore.deletedProfiles.isEmpty {
                Section {
                    Button("Delete Everything Now", role: .destructive) { confirmEmpty = true }
                } footer: {
                    Text("Deleted items are removed for good after 30 days.")
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .overlay {
            if workoutStore.trash.isEmpty && workoutStore.deletedProfiles.isEmpty && workoutStore.foundFighters.isEmpty {
                ContentUnavailableView("Nothing deleted", systemImage: "trash", description: Text("Deleted fighters and workouts appear here for 30 days."))
            }
        }
        .confirmationDialog("Delete everything for good?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete for Good", role: .destructive) {
                for d in workoutStore.deletedProfiles { workoutStore.permanentlyDelete(d) }
                for w in workoutStore.trash { workoutStore.permanentlyDelete(w) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func daysLeft(_ deletedAt: Date) -> String {
        let left = max(0, Int(ceil(WorkoutStore.trashDays - Date().timeIntervalSince(deletedAt) / 86400)))
        return left <= 1 ? "Removed tomorrow" : "\(left) days left"
    }
}
