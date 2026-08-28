# VerifiedCellular — Flutter

The canonical module behind a MethodChannel plugin, in three layers:

| Layer           | Files                                                              | Knows about              |
| --------------- | ------------------------------------------------------------------ | ------------------------ |
| Native snippets | `ios/VerifiedCellular.swift`, `android/VerifiedCellular.kt`        | Cellular, HTTP, decoding |
| Channel bridges | `ios/VerifiedCellularPlugin.swift`, `android/VerifiedCellularPlugin.kt` | Dart, nothing of cellular |
| Dart            | `lib/verified_cellular.dart` — the app's one import                | The app                  |

The snippets are this repo's own files, byte-identical to
`../ios/VerifiedCellular.swift` and `../android/VerifiedCellular.kt` — `diff` is
the test when either changes. In your app the Kotlin `package` lines change to
wherever the files land, and nothing else does.

A failure crosses the channel as a `PlatformException` whose `details` carries
the status code, URL and body that go with it — lossless, unlike the React
Native port. `lib/verified_cellular.dart` turns that back into the typed errors
the native apps would have caught (`VerifiedApiError`, `CellularError`), so keep
the wrapper: it is part of the module, not a convenience. The bridges leave
error messages unset on purpose — the sentence a person reads is the Dart
side's to write, once, for both platforms.

## Where the files go

| File                             | Destination in your app                                             |
| -------------------------------- | ------------------------------------------------------------------- |
| `lib/verified_cellular.dart`     | anywhere under `lib/`                                               |
| `ios/*.swift`                    | `ios/Runner/`, added to the Runner target in Xcode                  |
| `android/*.kt`                   | `android/app/src/main/kotlin/<your/package>/`, `package` line yours |

## Wiring

There is no pub package, so the plugin registers by hand. Android, in your
`FlutterActivity`:

```kotlin
class MainActivity : FlutterActivity() {
    private var cellularPlugin: VerifiedCellularPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The application context, not the activity: the plugin's network
        // callbacks outlive a configuration change, and holding the activity
        // would leak it.
        val plugin = VerifiedCellularPlugin(applicationContext)
        plugin.attach(flutterEngine.dartExecutor.binaryMessenger)
        cellularPlugin = plugin
    }

    override fun onDestroy() {
        cellularPlugin?.detach()
        cellularPlugin = null
        super.onDestroy()
    }
}
```

iOS, in your `AppDelegate`:

```swift
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Retained here on purpose: the plugin's channel handlers only capture
  // `[weak self]`, so without a strong reference somewhere it is deallocated
  // right after registration and the event channels never fire again.
  private var cellularPlugin: VerifiedCellularPlugin?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VerifiedCellularPlugin") {
      let plugin = VerifiedCellularPlugin()
      plugin.register(with: registrar)
      cellularPlugin = plugin
    }
  }
}
```

## Floors, dependencies, permissions

- **iOS 16**: the snippet builds request targets with
  `URL.path(percentEncoded:)`.
- **minSdk 26** in `android/app/build.gradle.kts`: where
  `ConnectivityManager.requestNetwork`'s timeout overload lands.
- `kotlinx-coroutines-android` on the classpath — the Flutter embedding does
  not pull coroutines in on its own:

  ```kotlin
  implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
  ```

- Three permissions in the app manifest — `INTERNET`, plus
  `ACCESS_NETWORK_STATE` to read what networks exist and `CHANGE_NETWORK_STATE`
  to ask for the cellular one.

## Using it

```dart
import 'verified_cellular.dart';

try {
  final verification = await followRedirects(url);
} on VerifiedApiError catch (error) {
  // The API answered with a refusal — error.errorCode carries the product code.
} on CellularError catch (error) {
  // No answer at all — error.code names which of the six ways.
}

final deviceIp = await getDeviceIp();
watchCellularAvailable().listen((available) => /* gates the verify button */);
```

A working consumer lives in `verified-demo/flutter`.
