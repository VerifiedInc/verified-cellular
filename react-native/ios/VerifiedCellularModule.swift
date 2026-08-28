import ExpoModulesCore
import Network

// The Expo bridge, and nothing else. The forcing, the HTTP and the decoding are
// all in VerifiedCellular.swift, which is the iOS app's file copied over
// unchanged — this file is the only part of the module that knows JavaScript
// exists.
//
// What it does own is the wire shape, because a thrown Swift error crosses the
// bridge as a code and a sentence and nothing else: a `CellularError` carrying a
// status code or a URL would arrive stripped. So no call here throws for a
// failure it expects. Each one answers with a record naming which of the three
// things happened — the verification, the API's refusal, or no answer at all —
// and the TypeScript wrapper turns that back into a returned value or a thrown
// typed error.
//
// The wording of those errors is deliberately not here. It belongs to the
// TypeScript layer, which is the one copy iOS and Android share; the native apps
// each carry their own.

public class VerifiedCellularModule: Module {
  // Advisory watchers only. The real enforcement is in VerifiedCellular, which
  // pins every hop to cellular no matter what these report. Fresh monitors per
  // observe cycle: a cancelled NWPathMonitor cannot be started again.
  private var cellularMonitor: NWPathMonitor?
  private var routeMonitor: NWPathMonitor?

  public func definition() -> ModuleDefinition {
    Name("VerifiedCellular")

    Events("onCellularAvailabilityChange", "onDefaultRouteChange")

    // Scoped to cellular: does a usable cellular interface exist at all,
    // whatever the default route happens to be. This is what gates the button
    // on the JavaScript side. Observe only — it never asks the OS to bring
    // cellular up. That is VerifiedCellular's job, at the moment of a request.
    OnStartObserving("onCellularAvailabilityChange") {
      let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
      monitor.pathUpdateHandler = { [weak self] path in
        self?.sendEvent("onCellularAvailabilityChange", [
          "available": path.status == .satisfied
        ])
      }
      monitor.start(queue: .main)
      self.cellularMonitor = monitor
    }

    OnStopObserving("onCellularAvailabilityChange") {
      self.cellularMonitor?.cancel()
      self.cellularMonitor = nil
    }

    // Unscoped: which interface currently wins the default route. Display copy
    // only, it gates nothing.
    OnStartObserving("onDefaultRouteChange") {
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { [weak self] path in
        self?.sendEvent("onDefaultRouteChange", [
          "wifiIsDefaultRoute": path.usesInterfaceType(.wifi)
        ])
      }
      monitor.start(queue: .main)
      self.routeMonitor = monitor
    }

    OnStopObserving("onDefaultRouteChange") {
      self.routeMonitor?.cancel()
      self.routeMonitor = nil
    }

    AsyncFunction("getDeviceIpAsync") { (timeoutMs: Double) -> DeviceIpAnswer in
      do {
        let deviceIp = try await VerifiedCellular.getDeviceIp(timeout: timeoutMs / 1000)
        return DeviceIpAnswer(deviceIp: deviceIp)
      } catch let error as CellularError {
        return DeviceIpAnswer(cellularError: error.record)
      }
    }

    AsyncFunction("followRedirectsAsync") { (url: String, timeoutMs: Double) -> ChainAnswer in
      // A URL the snippet would refuse anyway, refused here without a hop.
      guard let parsedURL = URL(string: url) else {
        return ChainAnswer(cellularError: CellularErrorRecord(code: "UNUSABLE_URL", url: url))
      }
      do {
        switch try await VerifiedCellular.followRedirects(url: parsedURL, timeout: timeoutMs / 1000) {
        case .success(let verification):
          return ChainAnswer(verification: VerificationRecord(verification))
        case .failure(let apiError):
          return ChainAnswer(apiError: ApiErrorRecord(apiError))
        }
      } catch let error as CellularError {
        return ChainAnswer(cellularError: error.record)
      }
    }
  }
}

// MARK: - Wire shape

/// A `CellularError` flattened into fields a record can carry. `code` is the
/// wire name of the case — the Kotlin bridge and the TypeScript wrapper spell
/// the same six, and that agreement is the whole contract.
struct CellularErrorRecord: Record {
  @Field var code: String = ""
  @Field var statusCode: Int? = nil
  @Field var url: String? = nil
  @Field var body: String? = nil
}

/// Either this device's cellular address, or why there isn't one.
struct DeviceIpAnswer: Record {
  @Field var deviceIp: String? = nil
  @Field var cellularError: CellularErrorRecord? = nil
}

/// The three ways a chain ends. Exactly one field is ever set.
struct ChainAnswer: Record {
  @Field var verification: VerificationRecord? = nil
  @Field var apiError: ApiErrorRecord? = nil
  @Field var cellularError: CellularErrorRecord? = nil
}

/// `OneClickVerificationEntity` as a record. `isVerified` is left off on
/// purpose: it is derived, and the TypeScript side derives it the same way
/// rather than trusting a second copy of the rule to have travelled.
struct VerificationRecord: Record {
  @Field var uuid: String = ""
  @Field var channel: String? = nil
  @Field var status: String? = nil
  @Field var phone: String? = nil
  @Field var verified: Bool? = nil
  @Field var createdAt: Int? = nil
  @Field var expiresAt: Int? = nil
  @Field var verifiedAt: Int? = nil
  @Field var deliveredAt: Int? = nil
  @Field var attemptsRemaining: Int? = nil

  init() {}

  init(_ entity: VerifiedCellular.OneClickVerificationEntity) {
    uuid = entity.uuid
    channel = entity.channel
    status = entity.status
    phone = entity.phone
    verified = entity.verified
    createdAt = entity.createdAt
    expiresAt = entity.expiresAt
    verifiedAt = entity.verifiedAt
    deliveredAt = entity.deliveredAt
    attemptsRemaining = entity.attemptsRemaining
  }
}

/// The API's error body. `describedMessage` is left off for the same reason
/// `isVerified` is: TypeScript composes it from these fields.
struct ApiErrorRecord: Record {
  @Field var message: String = ""
  @Field var name: String? = nil
  @Field var code: Int? = nil
  @Field var className: String? = nil
  @Field var errorCode: String? = nil

  init() {}

  init(_ apiError: VerifiedCellular.ApiError) {
    message = apiError.message
    name = apiError.name
    code = apiError.code
    className = apiError.className
    errorCode = apiError.errorCode
  }
}

private extension CellularError {
  var record: CellularErrorRecord {
    switch self {
    case .noCellularAvailable:
      return CellularErrorRecord(code: "NO_CELLULAR_AVAILABLE")
    case .timeout:
      return CellularErrorRecord(code: "TIMEOUT")
    case .tooManyRedirects:
      return CellularErrorRecord(code: "TOO_MANY_REDIRECTS")
    case .cleartextRedirectBlocked:
      return CellularErrorRecord(code: "CLEARTEXT_REDIRECT_BLOCKED")
    case .unusableURL(let url):
      return CellularErrorRecord(code: "UNUSABLE_URL", url: url.absoluteString)
    case .unreadableBody(let statusCode, let body, let url):
      // The body travels because it is the only thing that explains a carrier
      // gateway answering 200 with a login page.
      return CellularErrorRecord(
        code: "UNREADABLE_BODY",
        statusCode: statusCode,
        url: url.absoluteString,
        body: String(decoding: body, as: UTF8.self)
      )
    }
  }
}
