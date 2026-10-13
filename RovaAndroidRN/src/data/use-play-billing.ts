import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { deepLinkToSubscriptions, ErrorCode, getAvailablePurchases, useIAP, type Purchase, type ProductSubscription } from 'expo-iap';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, Platform } from 'react-native';
import { ChatApiError, chatApi, type SubscriptionInfo } from '@/data/chat-api';

export const WIQO_PLAY_PRODUCT_ID = 'wiqo_pro_monthly';
export const WIQO_PLAY_BASE_PLAN_ID = 'monthly';
export const WIQO_ANDROID_PACKAGE_ID = 'wiqo.android.com';

type PurchaseBusyState = 'purchase' | 'restore' | 'verify' | null;

function decodeBase64Url(value: string): string | null {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const input = value.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/g, '');
  let output = '';
  let bits = 0;
  let bitCount = 0;
  for (const character of input) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) return null;
    bits = (bits << 6) | digit;
    bitCount += 6;
    if (bitCount >= 8) {
      bitCount -= 8;
      output += String.fromCharCode((bits >> bitCount) & 0xff);
    }
  }
  return output;
}

/** Mirrors the backend's sha256("wiqo-account:<numeric user id>") binding. */
function obfuscatedAccountIdFromToken(token: string): string | null {
  const payload = token.split('.')[1];
  if (!payload) return null;
  const decoded = decodeBase64Url(payload);
  if (!decoded) return null;
  try {
    const userId: unknown = (JSON.parse(decoded) as { userId?: unknown }).userId;
    if (!(typeof userId === 'number' && Number.isSafeInteger(userId) && userId > 0)
      && !(typeof userId === 'string' && /^\d+$/.test(userId))) return null;
    return bytesToHex(sha256(utf8ToBytes(`wiqo-account:${userId}`)));
  } catch {
    return null;
  }
}

function matchingBasePlanOffer(product: ProductSubscription | undefined) {
  const offers = product?.subscriptionOffers?.filter(offer => offer.basePlanIdAndroid === WIQO_PLAY_BASE_PLAN_ID) ?? [];
  const standardOffer = offers.find(offer => !offer.id);
  if (standardOffer) return standardOffer;
  // Never silently select a Play offer with a free phase. This app's trial is owned by Wiqo's backend.
  if (offers.length === 1) {
    const phases = offers[0].pricingPhasesAndroid?.pricingPhaseList ?? [];
    if (phases.length > 0 && phases.every(phase => Number(phase.priceAmountMicros) > 0)) return offers[0];
  }
  return undefined;
}

export function usePlayBilling(token: string | null, onSubscriptionUpdated: (value: SubscriptionInfo) => void) {
  const [busy, setBusy] = useState<PurchaseBusyState>(null);
  const [storeError, setStoreError] = useState('');
  const [statusMessage, setStatusMessage] = useState('');
  const accountId = useMemo(() => token ? obfuscatedAccountIdFromToken(token) : null, [token]);
  const onSubscriptionUpdatedRef = useRef(onSubscriptionUpdated);
  const inFlightPurchaseKeys = useRef(new Set<string>());
  const verifiedPurchaseKeys = useRef(new Set<string>());
  const purchaseHandlerRef = useRef<(purchase: Purchase) => void>(() => undefined);

  useEffect(() => { onSubscriptionUpdatedRef.current = onSubscriptionUpdated; }, [onSubscriptionUpdated]);

  const { connected, subscriptions, fetchProducts, finishTransaction, requestPurchase, reconnect } = useIAP({
    onPurchaseSuccess: purchase => purchaseHandlerRef.current(purchase),
    onPurchaseError: error => {
      if (error.code === ErrorCode.UserCancelled) {
        setBusy(null);
        setStatusMessage('Satın alma iptal edildi.');
        return;
      }
      if (error.code === ErrorCode.Pending || error.code === ErrorCode.DeferredPayment) {
        setBusy(null);
        setStatusMessage('Satın alma beklemede. Google Play onayladığında aboneliğin etkinleşecek.');
        return;
      }
      setBusy(null);
      setStoreError('Google Play satın alımı tamamlayamadı. Biraz sonra tekrar deneyebilirsin.');
    },
    onError: () => setStoreError('Google Play bağlantısı şu anda kullanılamıyor.'),
  });

  const product = useMemo(
    () => subscriptions.find(item => item.id === WIQO_PLAY_PRODUCT_ID),
    [subscriptions],
  );
  const basePlanOffer = useMemo(() => matchingBasePlanOffer(product), [product]);
  const offerToken = basePlanOffer?.offerTokenAndroid ?? null;
  const price = basePlanOffer?.displayPrice ?? product?.displayPrice ?? null;

  const refreshServerSubscription = useCallback(async () => {
    if (!token) return;
    const snapshot = await chatApi.getSubscription(token, true);
    onSubscriptionUpdatedRef.current(snapshot);
  }, [token]);

  const processPurchase = useCallback(async (purchase: Purchase) => {
    if (purchase.productId !== WIQO_PLAY_PRODUCT_ID) return;
    if (purchase.purchaseState === 'pending') {
      setBusy(null);
      setStatusMessage('Satın alma beklemede. Google Play onayladığında aboneliğin etkinleşecek.');
      return;
    }
    if (purchase.purchaseState !== 'purchased') {
      setBusy(null);
      return;
    }
    const purchaseToken = purchase.purchaseToken?.trim();
    if (!purchaseToken || !token || !accountId) {
      setStoreError('Satın alma güvenli biçimde Wiqo hesabına bağlanamadı. Oturumu yenileyip tekrar dene.');
      return;
    }
    const expectedAccountId = 'obfuscatedAccountIdAndroid' in purchase ? purchase.obfuscatedAccountIdAndroid : undefined;
    if (expectedAccountId && expectedAccountId !== accountId) {
      setStoreError('Bu satın alma farklı bir Wiqo hesabıyla başlatılmış. Doğru hesapla tekrar dene.');
      return;
    }
    const purchaseKey = bytesToHex(sha256(utf8ToBytes(purchaseToken)));
    if (verifiedPurchaseKeys.current.has(purchaseKey) || inFlightPurchaseKeys.current.has(purchaseKey)) return;

    inFlightPurchaseKeys.current.add(purchaseKey);
    setBusy('verify');
    setStoreError('');
    setStatusMessage('Satın alma Wiqo hesabında doğrulanıyor…');
    try {
      const snapshot = await chatApi.verifyGooglePlayPurchase(token, purchaseToken);
      verifiedPurchaseKeys.current.add(purchaseKey);
      onSubscriptionUpdatedRef.current(snapshot);
      setStatusMessage('Wiqo Pro aboneliğin etkin.');
      try {
        await finishTransaction({ purchase, isConsumable: false });
      } catch {
        // The backend acknowledges verified Google Play purchases. Entitlement remains server-owned.
        setStatusMessage('Wiqo Pro etkin. Google Play işlem durumu yeniden eşitleniyor.');
      }
    } catch (error) {
      const message = error instanceof ChatApiError
        ? error.message
        : 'Satın alma sunucuda doğrulanamadı. Bağlantı gelince tekrar deneyebilirsin.';
      setStoreError(message);
      setStatusMessage('Satın alma doğrulanana kadar Pro özellikleri açılmaz.');
    } finally {
      inFlightPurchaseKeys.current.delete(purchaseKey);
      setBusy(null);
    }
  }, [accountId, finishTransaction, token]);

  useEffect(() => { purchaseHandlerRef.current = purchase => { void processPurchase(purchase); }; }, [processPurchase]);

  const reconcilePurchases = useCallback(async () => {
    if (!token) return;
    try {
      const purchases = await getAvailablePurchases();
      const matching = purchases.filter(item => item.productId === WIQO_PLAY_PRODUCT_ID && item.purchaseState === 'purchased');
      if (matching.length) {
        for (const purchase of matching) await processPurchase(purchase);
      } else {
        await refreshServerSubscription();
      }
    } catch {
      // Keep the current server snapshot visible; a later foreground/restore action can retry.
    }
  }, [processPurchase, refreshServerSubscription, token]);

  useEffect(() => {
    if (!connected || !token) return;
    let active = true;
    void fetchProducts({ skus: [WIQO_PLAY_PRODUCT_ID], type: 'subs' })
      .then(async () => {
        if (active) {
          setStoreError('');
          await reconcilePurchases();
        }
      })
      .catch(() => {
        if (active) setStoreError('Wiqo Pro fiyatı Google Play’den alınamadı. Biraz sonra yeniden dene.');
      });
    return () => { active = false; };
  }, [connected, fetchProducts, reconcilePurchases, token]);

  useEffect(() => {
    let wasBackgrounded = false;
    const subscription = AppState.addEventListener('change', state => {
      if (state !== 'active') { wasBackgrounded = true; return; }
      if (wasBackgrounded) {
        wasBackgrounded = false;
        void refreshServerSubscription().catch(() => undefined);
        void reconcilePurchases();
      }
    });
    return () => subscription.remove();
  }, [reconcilePurchases, refreshServerSubscription]);

  const purchase = useCallback(async () => {
    if (Platform.OS !== 'android' || !token) {
      setStoreError('Satın alma yalnızca Android’de Google Play üzerinden kullanılabilir.');
      return;
    }
    if (!accountId) {
      setStoreError('Wiqo hesabı güvenli biçimde eşleştirilemedi. Çıkış yapıp yeniden giriş yap.');
      return;
    }
    if (!connected || !product || !offerToken) {
      setStoreError('Wiqo Pro şu anda Google Play’de satın alınamıyor. Ürün ve aylık planın etkin olduğunu kontrol et.');
      return;
    }
    setBusy('purchase');
    setStoreError('');
    setStatusMessage('Google Play satın alma ekranı açılıyor…');
    try {
      await requestPurchase({
        request: {
          google: {
            skus: [WIQO_PLAY_PRODUCT_ID],
            subscriptionOffers: [{ sku: WIQO_PLAY_PRODUCT_ID, offerToken }],
            obfuscatedAccountId: accountId,
          },
        },
        type: 'subs',
      });
      // Completion is delivered by onPurchaseSuccess; keep busy until that callback settles.
    } catch {
      setBusy(null);
      setStatusMessage('');
      setStoreError('Google Play satın alma ekranı açılamadı. Tekrar deneyebilirsin.');
    }
  }, [accountId, connected, offerToken, product, requestPurchase, token]);

  const restore = useCallback(async () => {
    if (Platform.OS !== 'android' || !token) return;
    setBusy('restore');
    setStoreError('');
    setStatusMessage('Google Play satın alımları kontrol ediliyor…');
    try {
      const purchases = await getAvailablePurchases();
      const matching = purchases.filter(item => item.productId === WIQO_PLAY_PRODUCT_ID && item.purchaseState === 'purchased');
      if (matching.length) {
        for (const purchase of matching) await processPurchase(purchase);
      } else {
        const snapshot = await chatApi.getSubscription(token, true);
        onSubscriptionUpdatedRef.current(snapshot);
        setStatusMessage(snapshot.tier === 'pro'
          ? 'Abonelik durumun Wiqo hesabından eşitlendi.'
          : 'Geri yüklenecek etkin Wiqo Pro satın alımı bulunamadı.');
      }
    } catch (error) {
      setStoreError(error instanceof ChatApiError ? error.message : 'Satın alımlar şu anda kontrol edilemedi. Tekrar deneyebilirsin.');
      setStatusMessage('');
    } finally {
      setBusy(null);
    }
  }, [processPurchase, token]);

  const manageSubscription = useCallback(async () => {
    if (Platform.OS !== 'android') return;
    try {
      await deepLinkToSubscriptions({ skuAndroid: WIQO_PLAY_PRODUCT_ID, packageNameAndroid: WIQO_ANDROID_PACKAGE_ID });
    } catch {
      setStoreError('Google Play abonelik yönetimi açılamadı. Play Store’dan Profil > Ödemeler ve abonelikler bölümüne git.');
    }
  }, []);

  return {
    connected,
    price,
    readyToPurchase: connected && Boolean(product && offerToken && accountId),
    busy,
    storeError,
    statusMessage,
    purchase,
    restore,
    manageSubscription,
    retry: () => { void reconnect(); },
  };
}
