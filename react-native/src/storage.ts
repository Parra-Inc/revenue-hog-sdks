import type { StorageAdapter } from './types';

/** Fallback when async-storage isn't installed. Lives for the JS session. */
export function memoryStorage(): StorageAdapter {
  const values = new Map<string, string>();
  return {
    async getItem(key) {
      return values.has(key) ? (values.get(key) as string) : null;
    },
    async setItem(key, value) {
      values.set(key, value);
    },
    async removeItem(key) {
      values.delete(key);
    },
  };
}

/**
 * Lazily picks up `@react-native-async-storage/async-storage` when the host
 * app has it installed. Literal require inside try/catch → Metro treats it
 * as an optional dependency and never fails the bundle.
 */
export function detectAsyncStorage(): StorageAdapter | undefined {
  try {
    const mod = require('@react-native-async-storage/async-storage') as {
      default?: StorageAdapter;
    } & StorageAdapter;
    const impl = mod?.default ?? mod;
    if (impl && typeof impl.getItem === 'function') return impl;
  } catch {
    // not installed — fine
  }
  return undefined;
}
