# Contributing to thermac

Thanks for helping! thermac is young, and the most valuable contributions right now are
**measurements from Macs other than the one it was developed on**.

## Report how thermac works on your Mac

1. Install thermac (see the [README](README.md#installation)).
2. Run:
   ```sh
   thermac doctor
   thermac sensors
   ```
3. Open a **[Mac report](https://github.com/umairleo1/thermac/issues/new?template=mac-report.yml)**
   and paste the output with your Mac model (Apple menu → About This Mac).

If you have a thermometer, it's even better to compare its reading with `thermac now`
after a few nights. Note the time and the conditions: heating, an open window, and where
the Mac was (desk, lap, bed).

## Report a bug

Open a **[bug report](https://github.com/umairleo1/thermac/issues/new?template=bug-report.yml)**.
Include your macOS version, Mac model, what you expected, and what happened. Logs:

```sh
log show --last 1h --predicate 'subsystem == "com.thermac.bar"'
```

## Code changes

1. Fork the repository and create a branch.
2. Build and test:
   ```sh
   swift build
   scripts/test.sh        # with the Command Line Tools (or `swift test` with full Xcode)
   ```
3. Keep pull requests focused, and add tests for new behaviour. Estimator changes should
   include a simulation test (see `Tests/ThermacCoreTests`).
4. Describe *why* the change is needed in the PR, and how you checked it.

### Guidelines

- **Accuracy claims need evidence.** If a change affects the estimate, say how you
  validated it (simulation, `thermac replay`, `thermac calibrate`) and include the numbers,
  including when they get worse.
- **Privacy is non-negotiable.** thermac makes no network connections and keeps all data
  on the Mac.
- **Stay light.** The recorder must stay well under 0.5 % CPU.
- Swift 6 with strict concurrency; follow the existing style.

## Code of conduct

Be kind and constructive. Harassment or personal attacks of any kind aren't tolerated.
