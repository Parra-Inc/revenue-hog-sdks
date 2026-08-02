import { describe, expect, it } from 'vitest';
import { jwsFromPurchase } from '../src/autoAttribution';

const JWS = 'eyJhbGciOiJFUzI1NiJ9.eyJidW5kbGVJZCI6ImNvbS5leGFtcGxlLmFwcCJ9.c2ln';

describe('jwsFromPurchase', () => {
  it('reads jwsRepresentationIos (react-native-iap ≥ 13)', () => {
    expect(jwsFromPurchase({ jwsRepresentationIos: JWS })).toBe(JWS);
  });

  it('falls back through the field-name variants in order', () => {
    expect(jwsFromPurchase({ jwsRepresentationIOS: JWS })).toBe(JWS);
    expect(jwsFromPurchase({ verificationResultIOS: JWS })).toBe(JWS);
    expect(
      jwsFromPurchase({ jwsRepresentationIos: JWS, verificationResultIOS: 'a.b.c' })
    ).toBe(JWS);
  });

  it('ignores values that do not look like a JWS', () => {
    expect(jwsFromPurchase({ jwsRepresentationIos: 'not-a-jws' })).toBeUndefined();
    expect(jwsFromPurchase({ verificationResultIOS: 'base64receipt==' })).toBeUndefined();
  });

  it('is undefined for Android purchases and empty objects', () => {
    expect(jwsFromPurchase({})).toBeUndefined();
    expect(jwsFromPurchase(undefined)).toBeUndefined();
  });
});
