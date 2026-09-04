// Native backend for the `octodo/environment` platform channel
// (Windows). Dart-side contract:
// lib/src/terminal/fresh_environment.dart.
//
//   get → Map<String, String> of the CURRENT system + user environment
//         as the registry defines it right now, rebuilt via
//         CreateEnvironmentBlock — NOT the process's launch-time
//         snapshot. Called every time a terminal tab spawns a shell,
//         so environment edits made after octodo started (installers
//         appending to the user PATH, System Properties edits,
//         `setx`, …) are visible to the next tab without restarting
//         the app — the same contract Windows Terminal gives its
//         tabs.
//
// Failure of any step resolves to a null reply, which the Dart side
// translates to "fall back to Platform.environment" (the historical
// behavior) — a registry hiccup can never block tab creation.

#ifndef RUNNER_ENVIRONMENT_H_
#define RUNNER_ENVIRONMENT_H_

namespace flutter {
class FlutterEngine;
}

namespace octodo {

// Registers the method channel on [engine]. Call once after
// RegisterPlugins.
void RegisterEnvironmentChannel(flutter::FlutterEngine* engine);

}  // namespace octodo

#endif  // RUNNER_ENVIRONMENT_H_
