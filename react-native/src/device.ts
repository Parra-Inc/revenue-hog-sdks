/**
 * Best-effort device context, all through optional modules and try/catch.
 * Nothing here is an identifier — no IDFA, no fingerprinting.
 */

export interface DeviceContext {
  bundleId?: string;
  platform: 'ios' | 'android';
  osVersion?: string;
  deviceModel?: string;
  locale?: string;
}

export function detectDevice(): DeviceContext {
  const context: DeviceContext = { platform: 'ios' };

  try {
    const rn = require('react-native') as {
      Platform?: { OS?: string; Version?: string | number };
    };
    const os = rn?.Platform?.OS;
    if (os === 'ios' || os === 'android') context.platform = os;
    if (rn?.Platform?.Version != null) {
      context.osVersion = String(rn.Platform.Version);
    }
  } catch {
    // not running inside react-native (tests, node) — fine
  }

  try {
    // expo-managed apps
    const expoApp = require('expo-application') as { applicationId?: string };
    if (expoApp?.applicationId) context.bundleId = expoApp.applicationId;
  } catch {
    // not installed
  }

  try {
    const dInfo = require('react-native-device-info') as {
      default?: { getBundleId?: () => string; getModel?: () => string };
    };
    const impl = dInfo?.default ?? (dInfo as never);
    if (!context.bundleId && typeof impl?.getBundleId === 'function') {
      context.bundleId = impl.getBundleId();
    }
    if (typeof impl?.getModel === 'function') {
      context.deviceModel = impl.getModel();
    }
  } catch {
    // not installed
  }

  try {
    const locale = Intl.DateTimeFormat().resolvedOptions().locale;
    if (locale) context.locale = locale;
  } catch {
    // hermes without Intl — fine
  }

  return context;
}
