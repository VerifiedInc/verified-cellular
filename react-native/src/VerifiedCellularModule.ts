import { NativeModule, requireNativeModule } from 'expo';

// The wire shape, exactly as the two bridges send it. Nothing here is meant for
// the app: `index.ts` turns these into values and thrown errors, and that is
// what the app imports.

/**
 * A native `CellularError`, flattened. `code` is the case name; the two bridges
 * spell the same six, and `cellularErrorCodes` in `index.ts` is the third copy
 * of that list.
 */
export type CellularErrorPayload = {
  code: string;
  statusCode?: number | null;
  url?: string | null;
  body?: string | null;
};

/** The verification record, minus the derived `isVerified`. */
export type VerificationPayload = {
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

/** The API's error body, minus the derived `describedMessage`. */
export type ApiErrorPayload = {
  message: string;
  name?: string | null;
  code?: number | null;
  className?: string | null;
  errorCode?: string | null;
};

/** Either this device's cellular address, or why there isn't one. */
export type DeviceIpAnswer = {
  deviceIp?: string | null;
  cellularError?: CellularErrorPayload | null;
};

/** The three ways a chain ends. Exactly one field is ever set. */
export type ChainAnswer = {
  verification?: VerificationPayload | null;
  apiError?: ApiErrorPayload | null;
  cellularError?: CellularErrorPayload | null;
};

export type CellularAvailabilityChangeEvent = {
  available: boolean;
};

export type DefaultRouteChangeEvent = {
  wifiIsDefaultRoute: boolean;
};

export type VerifiedCellularModuleEvents = {
  onCellularAvailabilityChange: (event: CellularAvailabilityChangeEvent) => void;
  onDefaultRouteChange: (event: DefaultRouteChangeEvent) => void;
};

declare class VerifiedCellularModule extends NativeModule<VerifiedCellularModuleEvents> {
  getDeviceIpAsync(timeoutMs: number): Promise<DeviceIpAnswer>;
  followRedirectsAsync(url: string, timeoutMs: number): Promise<ChainAnswer>;
}

export default requireNativeModule<VerifiedCellularModule>('VerifiedCellular');
