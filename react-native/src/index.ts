import VerifiedCellularModule from './VerifiedCellularModule';

import type { ApiErrorPayload, CellularErrorPayload, VerificationPayload } from './VerifiedCellularModule';

// VerifiedCellular, v2 — the JavaScript half. The forcing lives in the two
// native files next to this one, which are the iOS and Android apps' own
// `VerifiedCellular` copied over unchanged. This file is what makes them look
// like one module: it declares the types the chain answers with, and turns the
// bridge's records back into returned values and thrown errors.
//
// It stands alone, the way the native snippets do — the app imports it and
// nothing else.

export type {
  CellularAvailabilityChangeEvent,
  DefaultRouteChangeEvent,
} from './VerifiedCellularModule';

// Structurally the same as expo-modules-core's EventSubscription. Declared
// locally so this module needs no direct dependency on expo-modules-core just
// for a type — expo-doctor flags that, and the runtime package is already there
// transitively through expo.
export type EventSubscription = {
  remove(): void;
};

/**
 * A 1-Click verification, as core-service returns it — the API calls this
 * entity `1ClickVerificationEntity`, which no language can spell. Everything
 * past `uuid` is optional: one shape covers create, this chain's last hop, and
 * verify — the same record at different points in its life.
 */
export type OneClickVerificationEntity = {
  uuid: string;
  channel?: string | null;
  status?: string | null;
  phone?: string | null;
  verified?: boolean | null;
  createdAt?: number | null;
  expiresAt?: number | null;
  verifiedAt?: number | null;
  deliveredAt?: number | null;
  attemptsRemaining?: number | null;
};

/**
 * `verified` is derived from `verifiedAt` server-side, so either one being set
 * is the same answer. A function rather than a field, because the entity arrives
 * as JSON — from this chain or from the API — and a field would have to be
 * grafted on at every boundary.
 */
export function isVerified(entity: OneClickVerificationEntity): boolean {
  return entity.verified === true || entity.verifiedAt != null;
}

/**
 * An API refusal. `errorCode` carries the product code — OCV008 is "autofill
 * failed" — and it is read out of the `data` object core-service wraps every
 * error payload in. The other fields are that envelope.
 *
 * Declared here rather than in the app because every call the app makes,
 * cellular or not, can come back with one, and this module is the thing both
 * platforms share.
 */
export class VerifiedApiError extends Error {
  readonly apiName?: string | null;
  readonly code?: number | null;
  readonly className?: string | null;
  readonly errorCode?: string | null;

  constructor(payload: ApiErrorPayload) {
    super(payload.message);
    // `name` is Error's own, and the API sends its own `name` in the envelope
    // ("BadRequest"). Keeping both means the envelope's lands on `apiName`.
    this.name = 'VerifiedApiError';
    this.apiName = payload.name;
    this.code = payload.code;
    this.className = payload.className;
    this.errorCode = payload.errorCode;
  }

  get describedMessage(): string {
    const prefix = this.errorCode ?? this.apiName;
    return prefix ? `${prefix}: ${this.message}` : this.message;
  }
}

/**
 * The six ways a chain can fail to answer. The same list the two bridges spell
 * as `code`, and the reason a `CellularError` survives the trip with its status
 * code and URL intact.
 */
export const cellularErrorCodes = [
  'NO_CELLULAR_AVAILABLE',
  'TIMEOUT',
  'TOO_MANY_REDIRECTS',
  'CLEARTEXT_REDIRECT_BLOCKED',
  /** A URL with no host, or a redirect pointing somewhere unparseable. */
  'UNUSABLE_URL',
  /** The chain answered, but the body was not what was asked for. */
  'UNREADABLE_BODY',
] as const;

export type CellularErrorCode = (typeof cellularErrorCodes)[number];

/** No answer at all: the radio, the route, or the reply itself. */
export class CellularError extends Error {
  readonly code: CellularErrorCode;
  /** Set for `UNREADABLE_BODY`. */
  readonly statusCode?: number;
  /** Set for `UNUSABLE_URL` and `UNREADABLE_BODY`. */
  readonly url?: string;
  /** Set for `UNREADABLE_BODY` — what arrived instead of the record. */
  readonly body?: string;

  constructor(payload: CellularErrorPayload) {
    super(payload.code);
    this.name = 'CellularError';
    // A code the bridge has but this list doesn't is a version skew between the
    // JavaScript bundle and the native build. Reporting it as a timeout would
    // be a lie, so it comes through as itself and the message ladder falls back.
    this.code = payload.code as CellularErrorCode;
    this.statusCode = payload.statusCode ?? undefined;
    this.url = payload.url ?? undefined;
    this.body = payload.body ?? undefined;
  }
}

/**
 * The IP this device shows over cellular, not the one the default route shows.
 * Read over cellular, so it holds even while WiFi is winning.
 *
 * @param timeout seconds
 */
export async function getDeviceIp(timeout: number = 3): Promise<string> {
  const answer = await VerifiedCellularModule.getDeviceIpAsync(timeout * 1000);
  if (answer.cellularError) {
    throw new CellularError(answer.cellularError);
  }
  if (answer.deviceIp == null) {
    // The bridges set exactly one field. Reaching here means one didn't.
    throw new CellularError({ code: 'UNREADABLE_BODY' });
  }
  return answer.deviceIp;
}

/**
 * GETs `url` over cellular and follows wherever it leads. The chain ends back at
 * core-service with the verification record, so that record is what comes back.
 *
 * Any other status is the API's refusal, which is an answer too — its body is
 * the reason, and it arrives as a thrown `VerifiedApiError`. The native
 * snippets hand that back as a `Result` for the caller to unwrap; a throw is the
 * same thing spelled the way JavaScript spells it, and callers that care read
 * `errorCode`. A thrown `CellularError` means no answer at all.
 *
 * Every hop is a bare GET carrying only cookies picked up along the way.
 *
 * @param timeout seconds, covering the whole chain
 */
export async function followRedirects(
  url: string,
  timeout: number = 10
): Promise<OneClickVerificationEntity> {
  const answer = await VerifiedCellularModule.followRedirectsAsync(url, timeout * 1000);
  if (answer.cellularError) {
    throw new CellularError(answer.cellularError);
  }
  if (answer.apiError) {
    throw new VerifiedApiError(answer.apiError);
  }
  if (!answer.verification) {
    throw new CellularError({ code: 'UNREADABLE_BODY' });
  }
  return toEntity(answer.verification);
}

/**
 * Does a usable cellular network exist at all, whatever the default route
 * happens to be. This is what gates the verify button. Observe only: it never
 * asks the OS to bring cellular up. That is `followRedirects`' job, at the
 * moment a request is made.
 */
export function watchCellularAvailable(
  onUpdate: (available: boolean) => void
): EventSubscription {
  return VerifiedCellularModule.addListener('onCellularAvailabilityChange', (event) => {
    onUpdate(event.available);
  });
}

/**
 * Does WiFi win the default route right now. Display copy only, it gates
 * nothing: every hop of a forced request is pinned to cellular regardless.
 */
export function watchWifiIsDefaultRoute(
  onUpdate: (wifiIsDefault: boolean) => void
): EventSubscription {
  return VerifiedCellularModule.addListener('onDefaultRouteChange', (event) => {
    onUpdate(event.wifiIsDefaultRoute);
  });
}

/**
 * The record as the app reads it. Both bridges send `null` for an absent field,
 * which is not what an optional property means in TypeScript, so this is where
 * the two spellings meet.
 */
function toEntity(payload: VerificationPayload): OneClickVerificationEntity {
  return {
    uuid: payload.uuid,
    channel: payload.channel ?? undefined,
    status: payload.status ?? undefined,
    phone: payload.phone ?? undefined,
    verified: payload.verified ?? undefined,
    createdAt: payload.createdAt ?? undefined,
    expiresAt: payload.expiresAt ?? undefined,
    verifiedAt: payload.verifiedAt ?? undefined,
    deliveredAt: payload.deliveredAt ?? undefined,
    attemptsRemaining: payload.attemptsRemaining ?? undefined,
  };
}
