import Flutter
import Foundation
import Network

// The channel bridge, and nothing else. The forcing, the HTTP and the decoding are
// all in VerifiedCellular.swift, which is the iOS app's file copied over
// unchanged — this file is the only part of the module that knows Dart exists.
//
// A failure crosses as a `FlutterError`, whose `details` can carry any value the
// standard message codec encodes — a map included. So unlike the React Native
// port, which has to answer with a record because an Expo exception carries only
// a code and a sentence, here a throw is lossless: the code names the case and
// `details` carries the status code, URL and body that go with it.
//
// The wording of those failures is deliberately not here. It belongs to the Dart
// layer, which is the one copy iOS and Android share; the native apps each carry
// their own.

final class VerifiedCellularPlugin: NSObject {
  // One monitor per active listener. An NWPathMonitor cannot be restarted once
  // cancelled, so each onListen creates a fresh one.
  private var cellularMonitor: NWPathMonitor?
  private var routeMonitor: NWPathMonitor?

  func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "verified_cellular",
      binaryMessenger: registrar.messenger()
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    // Scoped to cellular: does a usable cellular interface exist at all, whatever
    // the default route happens to be. This is what gates the button on the Dart
    // side. Observe only — it never asks the OS to bring cellular up. That is
    // VerifiedCellular's job, at the moment of a request.
    FlutterEventChannel(
      name: "verified_cellular/cellular_available",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(ClosureStreamHandler(
      onListen: { [weak self] _, events in
        let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
        monitor.pathUpdateHandler = { path in
          DispatchQueue.main.async { events(path.status == .satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))
        self?.cellularMonitor = monitor
        return nil
      },
      onCancel: { [weak self] _ in
        self?.cellularMonitor?.cancel()
        self?.cellularMonitor = nil
        return nil
      }
    ))

    // Unscoped: which interface currently wins the default route. Display copy
    // only, it gates nothing.
    FlutterEventChannel(
      name: "verified_cellular/wifi_is_default_route",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(ClosureStreamHandler(
      onListen: { [weak self] _, events in
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
          DispatchQueue.main.async { events(path.usesInterfaceType(.wifi)) }
        }
        monitor.start(queue: .global(qos: .utility))
        self?.routeMonitor = monitor
        return nil
      },
      onCancel: { [weak self] _ in
        self?.routeMonitor?.cancel()
        self?.routeMonitor = nil
        return nil
      }
    ))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getDeviceIp":
      getDeviceIp(call, result: result)
    case "followRedirects":
      followRedirects(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getDeviceIp(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let timeout = Self.timeout(from: call, default: 3)
    Task {
      do {
        let deviceIp = try await VerifiedCellular.getDeviceIp(timeout: timeout)
        await MainActor.run { result(deviceIp) }
      } catch let error as CellularError {
        await MainActor.run { result(error.flutterError) }
      } catch {
        await MainActor.run { result(Self.unexpected(error)) }
      }
    }
  }

  private func followRedirects(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let urlString = arguments["url"] as? String,
          let url = URL(string: urlString) else {
      // A URL the snippet would refuse anyway, refused here without a hop.
      result(FlutterError(code: "UNUSABLE_URL", message: nil, details: nil))
      return
    }
    let timeout = Self.timeout(from: call, default: 10)

    Task {
      do {
        switch try await VerifiedCellular.followRedirects(url: url, timeout: timeout) {
        case .success(let verification):
          await MainActor.run { result(Self.map(verification)) }
        case .failure(let apiError):
          await MainActor.run {
            result(FlutterError(code: "API_ERROR", message: nil, details: Self.map(apiError)))
          }
        }
      } catch let error as CellularError {
        await MainActor.run { result(error.flutterError) }
      } catch {
        await MainActor.run { result(Self.unexpected(error)) }
      }
    }
  }

  // MARK: - Wire shape

  private static func timeout(from call: FlutterMethodCall, default fallback: TimeInterval) -> TimeInterval {
    guard let arguments = call.arguments as? [String: Any],
          let milliseconds = (arguments["timeoutMs"] as? NSNumber)?.doubleValue else {
      return fallback
    }
    return milliseconds / 1000
  }

  /// `isVerified` and `describedMessage` are left off on purpose: both are
  /// derived, and Dart derives them the same way rather than trusting a second
  /// copy of the rule to have travelled.
  private static func map(_ entity: VerifiedCellular.OneClickVerificationEntity) -> [String: Any] {
    var fields: [String: Any] = ["uuid": entity.uuid]
    // Written through `put` rather than by subscript, so an optional is unwrapped
    // here instead of relying on how Swift coerces `T?` into an `Any` dictionary.
    // An absent key reads as null in Dart, which is what these fields mean when
    // the record hasn't reached that point in its life.
    func put(_ key: String, _ value: Any?) {
      if let value { fields[key] = value }
    }
    put("channel", entity.channel)
    put("status", entity.status)
    put("phone", entity.phone)
    put("verified", entity.verified)
    put("createdAt", entity.createdAt)
    put("expiresAt", entity.expiresAt)
    put("verifiedAt", entity.verifiedAt)
    put("deliveredAt", entity.deliveredAt)
    put("attemptsRemaining", entity.attemptsRemaining)
    return fields
  }

  private static func map(_ apiError: VerifiedCellular.ApiError) -> [String: Any] {
    var fields: [String: Any] = ["message": apiError.message]
    func put(_ key: String, _ value: Any?) {
      if let value { fields[key] = value }
    }
    put("name", apiError.name)
    put("code", apiError.code)
    put("className", apiError.className)
    put("errorCode", apiError.errorCode)
    return fields
  }

  /// Anything the snippet did not classify — an NWError the connect surfaced, say.
  /// Reported under its own code so Dart's message ladder falls through to it
  /// rather than calling it something it isn't.
  private static func unexpected(_ error: Error) -> FlutterError {
    FlutterError(code: "UNEXPECTED", message: error.localizedDescription, details: nil)
  }
}

private extension CellularError {
  /// `code` is the wire name of the case — the Kotlin bridge and the Dart wrapper
  /// spell the same six, and that agreement is the whole contract. `message` is
  /// left nil: the sentence a person reads is Dart's to write.
  var flutterError: FlutterError {
    switch self {
    case .noCellularAvailable:
      return FlutterError(code: "NO_CELLULAR_AVAILABLE", message: nil, details: nil)
    case .timeout:
      return FlutterError(code: "TIMEOUT", message: nil, details: nil)
    case .tooManyRedirects:
      return FlutterError(code: "TOO_MANY_REDIRECTS", message: nil, details: nil)
    case .cleartextRedirectBlocked:
      return FlutterError(code: "CLEARTEXT_REDIRECT_BLOCKED", message: nil, details: nil)
    case .unusableURL(let url):
      return FlutterError(code: "UNUSABLE_URL", message: nil, details: ["url": url.absoluteString])
    case .unreadableBody(let statusCode, let body, let url):
      // The body travels because it is the only thing that explains a carrier
      // gateway answering 200 with a login page.
      return FlutterError(code: "UNREADABLE_BODY", message: nil, details: [
        "statusCode": statusCode,
        "url": url.absoluteString,
        "body": String(decoding: body, as: UTF8.self),
      ])
    }
  }
}

/// Adapts closures to `FlutterStreamHandler` so each event channel above can
/// supply its own onListen/onCancel without a dedicated handler class.
private final class ClosureStreamHandler: NSObject, FlutterStreamHandler {
  private let onListenHandler: (Any?, @escaping FlutterEventSink) -> FlutterError?
  private let onCancelHandler: (Any?) -> FlutterError?

  init(
    onListen: @escaping (Any?, @escaping FlutterEventSink) -> FlutterError?,
    onCancel: @escaping (Any?) -> FlutterError?
  ) {
    self.onListenHandler = onListen
    self.onCancelHandler = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListenHandler(arguments, events)
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelHandler(arguments)
  }
}
