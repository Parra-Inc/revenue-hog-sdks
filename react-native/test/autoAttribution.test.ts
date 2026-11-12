import { describe, expect, it } from 'vitest';
import { jwsFromPurchase, transactionIdFromPurchase } from '../src/autoAttribution';

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

describe('transactionIdFromPurchase', () => {
  it('uses the Play purchase token on Android, not the per-renewal order id', () => {
    expect(
      transactionIdFromPurchase({ transactionId: 'GPA.1234-5678-9012-34567', purchaseToken: 'tok_play' })
    ).toBe('tok_play');
    expect(transactionIdFromPurchase({ transactionId: 'GPA.1', purchaseTokenAndroid: 'tok_old' })).toBe('tok_old');
  });

  it('keeps the original transaction id on iOS', () => {
    expect(
      transactionIdFromPurchase({ transactionId: '2000000999', originalTransactionIdentifierIOS: '2000000001' })
    ).toBe('2000000001');
    expect(transactionIdFromPurchase({ transactionId: '2000000999' })).toBe('2000000999');
    expect(transactionIdFromPurchase(undefined)).toBeUndefined();
  });
});

describe('react-native-iap 14/15 purchase shapes', () => {
  // v15 iOS: unified id + platform, JWS in purchaseToken, null for absent fields.
  const v15Ios = {
    id: '2000000999',
    transactionId: '2000000999',
    originalTransactionIdentifierIOS: '2000000001',
    productId: 'pro.monthly',
    platform: 'ios',
    purchaseToken: JWS,
    jwsRepresentationIos: null,
  };
  // v15 Android: unified id is the order id, purchaseToken is the Play token.
  const v15Android = {
    id: 'GPA.1234-5678',
    transactionId: 'GPA.1234-5678',
    productId: 'pro.monthly',
    platform: 'android',
    purchaseToken: 'opaque.AO-J1Oxyz',
    autoRenewingAndroid: true,
    originalTransactionIdentifierIOS: null,
  };
  // v14 iOS without originalTransactionIdentifierIOS: id only.
  const v14Ios = { id: '2000000777', productId: 'pro.yearly', platform: 'ios', purchaseToken: JWS };

  it('reads the JWS from purchaseToken on iOS', () => {
    expect(jwsFromPurchase(v15Ios)).toBe(JWS);
    expect(jwsFromPurchase(v14Ios)).toBe(JWS);
  });

  it('never uses the iOS JWS as the transaction id', () => {
    expect(transactionIdFromPurchase(v15Ios)).toBe('2000000001');
    expect(transactionIdFromPurchase(v14Ios)).toBe('2000000777');
  });

  it('keeps the Play token as the Android id and never treats it as a JWS', () => {
    expect(transactionIdFromPurchase(v15Android)).toBe('opaque.AO-J1Oxyz');
    expect(jwsFromPurchase(v15Android)).toBeUndefined();
    expect(jwsFromPurchase({ platform: 'android', purchaseToken: JWS })).toBeUndefined();
  });

  it('uses Platform.OS when the purchase carries no platform', () => {
    expect(jwsFromPurchase({ id: '1', purchaseToken: JWS }, 'ios')).toBe(JWS);
    expect(transactionIdFromPurchase({ id: '1', purchaseToken: JWS }, 'ios')).toBe('1');
    expect(transactionIdFromPurchase({ id: 'GPA.1', purchaseToken: 'tok' }, 'android')).toBe('tok');
  });

  it('prefers jwsRepresentationIos over purchaseToken', () => {
    const other = 'eyJvdGhlciI6MX0.eyJ4IjoxfQ.c2ln';
    expect(jwsFromPurchase({ platform: 'ios', jwsRepresentationIos: other, purchaseToken: JWS })).toBe(other);
  });

  it('ignores a non-JWS iOS purchaseToken', () => {
    expect(jwsFromPurchase({ platform: 'ios', purchaseToken: 'a.b.c' })).toBeUndefined();
  });
});
