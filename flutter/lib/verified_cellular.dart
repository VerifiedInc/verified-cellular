import 'package:flutter/services.dart';

// VerifiedCellular, v2 — the Dart half. The forcing lives in the two native files
// beside the platform entry points, which are the iOS and Android apps' own
// `VerifiedCellular` copied over unchanged:
//
//   ios/Runner/VerifiedCellular.swift
//   android/app/src/main/kotlin/<your/app/package>/VerifiedCellular.kt
//
// This file is what makes them look like one module: it declares the types the
// chain answers with, and turns a `PlatformException` back into the typed error
// the native apps would have caught. It stands alone, the way the native snippets
// do — the app imports it and nothing else.

const MethodChannel _methods = MethodChannel('verified_cellular');

const EventChannel _cellularAvailable =
    EventChannel('verified_cellular/cellular_available');

const EventChannel _wifiIsDefaultRoute =
    EventChannel('verified_cellular/wifi_is_default_route');

/// A 1-Click verification, as core-service returns it — the API calls this entity
/// `1ClickVerificationEntity`, which no language can spell. Everything past
/// [uuid] is nullable: one shape covers create, this chain's last hop, and
/// verify — the same record at different points in its life.
class OneClickVerificationEntity {
  const OneClickVerificationEntity({
    required this.uuid,
    this.channel,
    this.status,
    this.phone,
    this.verified,
    this.createdAt,
    this.expiresAt,
    this.verifiedAt,
    this.deliveredAt,
    this.attemptsRemaining,
  });

  final String uuid;
  final String? channel;
  final String? status;
  final String? phone;
  final bool? verified;
  final int? createdAt;
  final int? expiresAt;
  final int? verifiedAt;
  final int? deliveredAt;
  final int? attemptsRemaining;

  /// `verified` is derived from `verifiedAt` server-side, so either one being set
  /// is the same answer.
  bool get isVerified => verified == true || verifiedAt != null;

  /// Reads the record from either source it can arrive from: this chain, over the
  /// method channel, or the API, as JSON.
  factory OneClickVerificationEntity.fromMap(Map<String, Object?> map) {
    return OneClickVerificationEntity(
      uuid: map['uuid']! as String,
      channel: map['channel'] as String?,
      status: map['status'] as String?,
      phone: map['phone'] as String?,
      verified: map['verified'] as bool?,
      createdAt: _asInt(map['createdAt']),
      expiresAt: _asInt(map['expiresAt']),
      verifiedAt: _asInt(map['verifiedAt']),
      deliveredAt: _asInt(map['deliveredAt']),
      attemptsRemaining: _asInt(map['attemptsRemaining']),
    );
  }
}

/// An API refusal. [errorCode] carries the product code — OCV008 is "autofill
/// failed" — and it is read out of the `data` object core-service wraps every
/// error payload in. The other fields are that envelope.
///
/// Declared here rather than in the app because every call the app makes,
/// cellular or not, can come back with one, and this module is the thing both
/// platforms share.
class VerifiedApiError implements Exception {
  const VerifiedApiError({
    required this.message,
    this.name,
    this.code,
    this.className,
    this.errorCode,
  });

  final String message;
  final String? name;
  final int? code;
  final String? className;
  final String? errorCode;

  String get describedMessage {
    final prefix = errorCode ?? name;
    return (prefix == null || prefix.isEmpty) ? message : '$prefix: $message';
  }

  /// Only `message` is required, so some unrelated object can't pass for an error
  /// by accident — the same bar the native snippets' own `ApiError.from` sets.
  /// Returns null when it isn't one.
  static VerifiedApiError? fromMap(Map<String, Object?> map) {
    final message = map['message'];
    if (message is! String) return null;
    final data = map['data'];
    return VerifiedApiError(
      message: message,
      name: map['name'] as String?,
      code: _asInt(map['code']),
      className: map['className'] as String?,
      // Over the channel the bridge has already unwrapped `data.errorCode`; from
      // the API's JSON it is still nested.
      errorCode: (map['errorCode'] as String?) ??
          (data is Map ? _asStringMap(data)['errorCode'] as String? : null),
    );
  }

  @override
  String toString() => 'VerifiedApiError($describedMessage)';
}

/// The six ways a chain can fail to answer. The same list the two bridges spell as
/// their error code, and the reason a [CellularError] survives the trip with its
/// status code and URL intact.
enum CellularErrorCode {
  noCellularAvailable('NO_CELLULAR_AVAILABLE'),
  timeout('TIMEOUT'),
  tooManyRedirects('TOO_MANY_REDIRECTS'),
  cleartextRedirectBlocked('CLEARTEXT_REDIRECT_BLOCKED'),

  /// A URL with no host, or a redirect pointing somewhere unparseable.
  unusableUrl('UNUSABLE_URL'),

  /// The chain answered, but the body was not what was asked for.
  unreadableBody('UNREADABLE_BODY'),

  /// A code this build has never heard of, which means the native half is ahead
  /// of the Dart half. Reporting it as a timeout would be a lie.
  unknown('UNKNOWN');

  const CellularErrorCode(this.wireName);

  final String wireName;

  static CellularErrorCode fromWire(String wireName) => values.firstWhere(
        (code) => code.wireName == wireName,
        orElse: () => unknown,
      );
}

/// No answer at all: the radio, the route, or the reply itself.
class CellularError implements Exception {
  const CellularError(this.code, {this.statusCode, this.url, this.body});

  final CellularErrorCode code;

  /// Set for [CellularErrorCode.unreadableBody].
  final int? statusCode;

  /// Set for [CellularErrorCode.unusableUrl] and [CellularErrorCode.unreadableBody].
  final String? url;

  /// Set for [CellularErrorCode.unreadableBody] — what arrived instead of the record.
  final String? body;

  @override
  String toString() => 'CellularError(${code.wireName})';
}

/// The IP this device shows over cellular, not the one the default route shows.
/// Read over cellular, so it holds even while WiFi is winning.
Future<String> getDeviceIp({Duration timeout = const Duration(seconds: 3)}) async {
  try {
    final deviceIp = await _methods.invokeMethod<String>('getDeviceIp', {
      'timeoutMs': timeout.inMilliseconds,
    });
    if (deviceIp == null) {
      // The bridges answer with the address or an error; reaching here means one
      // did neither.
      throw const CellularError(CellularErrorCode.unreadableBody);
    }
    return deviceIp;
  } on PlatformException catch (error) {
    throw _typed(error);
  }
}

/// GETs [url] over cellular and follows wherever it leads. The chain ends back at
/// core-service with the verification record, so that record is what comes back.
///
/// Any other status is the API's refusal, which is an answer too — its body is the
/// reason, and it arrives as a thrown [VerifiedApiError]. The native snippets hand
/// that back as a `Result` for the caller to unwrap; a throw is the same thing
/// spelled the way Dart spells it, and callers that care read `errorCode`. A
/// thrown [CellularError] means no answer at all.
///
/// Every hop is a bare GET carrying only cookies picked up along the way.
Future<OneClickVerificationEntity> followRedirects(
  String url, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final verification = await _methods.invokeMapMethod<String, Object?>(
      'followRedirects',
      {'url': url, 'timeoutMs': timeout.inMilliseconds},
    );
    if (verification == null) {
      throw const CellularError(CellularErrorCode.unreadableBody);
    }
    return OneClickVerificationEntity.fromMap(verification);
  } on PlatformException catch (error) {
    throw _typed(error);
  }
}

/// Does a usable cellular network exist at all, whatever the default route happens
/// to be. This is what gates the verify button. Observe only: it never asks the OS
/// to bring cellular up. That is [followRedirects]' job, at the moment a request
/// is made.
Stream<bool> watchCellularAvailable() =>
    _cellularAvailable.receiveBroadcastStream().map((event) => event == true);

/// Does WiFi win the default route right now. Display copy only, it gates nothing:
/// every hop of a forced request is pinned to cellular regardless.
Stream<bool> watchWifiIsDefaultRoute() =>
    _wifiIsDefaultRoute.receiveBroadcastStream().map((event) => event == true);

/// Turns what crossed the channel back into the error the native apps would have
/// caught. Both bridges leave `message` unset on purpose — the sentence a person
/// reads belongs to the app's Dart layer, which is the one copy both platforms
/// share.
Object _typed(PlatformException error) {
  final details = error.details;
  final fields = details is Map ? _asStringMap(details) : const <String, Object?>{};

  if (error.code == 'API_ERROR') {
    return VerifiedApiError.fromMap(fields) ??
        const CellularError(CellularErrorCode.unreadableBody);
  }

  final code = CellularErrorCode.fromWire(error.code);
  if (code == CellularErrorCode.unknown) {
    // Not one of the six, and not an API refusal — an unclassified native failure
    // the bridge forwarded under its own code. Keep its message, which is the only
    // thing that describes it.
    return CellularError(
      code,
      body: error.message,
    );
  }
  return CellularError(
    code,
    statusCode: _asInt(fields['statusCode']),
    url: fields['url'] as String?,
    body: fields['body'] as String?,
  );
}

/// The standard message codec hands back `Map<Object?, Object?>`, and JSON gives
/// `Map<String, dynamic>`. Both become this.
Map<String, Object?> _asStringMap(Map<Object?, Object?> map) =>
    map.map((key, value) => MapEntry(key.toString(), value));

/// Timestamps arrive as int over the channel and can arrive as double from JSON,
/// since JSON has one number type.
int? _asInt(Object? value) => switch (value) {
      int value => value,
      double value => value.toInt(),
      _ => null,
    };
