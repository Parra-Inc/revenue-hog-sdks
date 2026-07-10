// Ambient declarations for globals React Native (Hermes/JSC) provides at
// runtime. We compile with lib=ES2020 only — no DOM, no node types — so the
// SDK can't accidentally depend on APIs the RN runtime doesn't have.

// CJS require, used only for optional peer-dependency detection.
// Metro treats literal requires inside try/catch as optional dependencies.
declare function require(id: string): unknown;

declare const console: { log(...args: unknown[]): void };

declare function setTimeout(callback: () => void, ms: number): unknown;

// Hermes ships crypto.randomUUID on modern RN; guarded at runtime anyway.
declare const crypto: { randomUUID(): string } | undefined;

declare function fetch(
  url: string,
  init: { method: string; headers: Record<string, string>; body: string }
): Promise<{ status: number }>;
