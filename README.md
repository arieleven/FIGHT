# CoospoTracker (Coospo Workout)

iOS SwiftUI + CoreBluetooth heart rate & fight conditioning tracker built for CooSpo chest/arm straps (H9Z / HW807).

## Project Structure

- `project.yml` — XcodeGen specification for `CoospoTracker` + `CoospoWidgetExtension` (Live Activities / Dynamic Island).
- `.github/workflows/build.yml` — Automated GitHub Actions workflow producing `CoospoTracker-IPA`.
- `Sources/App/` — Main iOS app (`LiveWorkoutView`, `AudioCoachEngine`, `WorkoutStore`, `WorkoutDetailView`, `ProfileSettingsView`, `HistoryListView`, `ComparisonView`, `BLEHeartRateManager`, `Models`, `CoospoTrackerApp`).
- `Sources/Shared/` — Shared `WorkoutActivityAttributes` between app and widget extension.
- `Sources/Widget/` — Lock Screen & Dynamic Island Live Activity widget.

## Deploying to Your Repo

1. Extract this archive into `X:\projects\CoospoTracker` (replacing existing files).
2. Run:
   ```powershell
   git add .
   git commit -m "Update CoospoTracker v2 with audio coach, LTHR test, ghost mode, and wheel pickers"
   git push
   ```
3. Download `CoospoTracker-IPA` from the GitHub Actions run and install via Sideloadly (note: the embedded Live Activity extension uses 2 of your 3 free Apple ID app slots).
