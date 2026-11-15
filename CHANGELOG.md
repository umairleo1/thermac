# Changelog

All notable changes to thermac are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Relocation handling:** after the lid has been closed for 30 minutes or more (e.g.
  carrying the Mac to work), the room is treated as uncertain again, so the estimate
  re-converges at the new place.
- **Change detection** for large, sudden room changes.
- **Trend in the panel** ("Up 0.3 °C in the last hour").
- Optional **Responsive** mode (Settings → Response): reacts faster, jitters more.
- `thermac replay` reports through-the-day tracking error and jitter.

### Changed
- **Calibration uses only time at known places:** periods after a mid-day move are no
  longer compared against the home reference.
- The **filter is re-tuned** from model-error statistics measured at known places.
- `replay` scores next-night predictions only for days spent in one place.
- The menu bar shows **one decimal** by default, matching the panel; whole degrees are
  optional. The panel always shows one decimal.
- Refreshes **every minute** by default.
- The installer **moves** the app to `~/Applications` instead of copying it, so no
  duplicate app appears in Spotlight or Launchpad.

### Fixed
- README screenshots now render on GitHub's dark theme.
- Tests build with older Swift compilers on CI.

## [0.2.0] - 2026-11-14

First public release.

### Added
- **Menu bar app** with the room temperature, uncertainty, trend over the last hour,
  24-hour chart with hover, and a Settings window (units, precision, refresh rate,
  response, open at login, background recording).
- **One-step setup:** the recorder ships inside the app and runs as a login item.
- **One-line installer** (`install.sh`) with update and uninstall.
- **Estimators:** overnight sleep-cooling, a power-response model calibrated from nightly
  anchors, and a Kalman filter that combines them, with change detection for large
  sudden room changes (e.g. the Mac carried to another room).
- **Background recorder:** 55 sensor and power channels every 5 s into SQLite, about
  0.03 % CPU and 10 MB a day; sleep sessions spanning macOS maintenance wakes.
- **Command-line tool** `thermac` for diagnostics, export and validation
  (`doctor`, `sensors`, `now`, `status`, `export`, `validate`, `calibrate`, `replay`).
- °C/°F following the system setting, locale-aware numbers, VoiceOver support for the chart.

[Unreleased]: https://github.com/umairleo1/thermac/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/umairleo1/thermac/releases/tag/v0.2.0
