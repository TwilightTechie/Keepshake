import Constants from 'expo-constants';

// In Expo dev the bundle is served from the dev machine; reuse that host for the
// backend so the phone reaches the Mac's LAN IP without configuration.
const devHost = Constants.expoConfig?.hostUri?.split(':')[0] ?? 'localhost';

export const API_URL = process.env.EXPO_PUBLIC_API_URL ?? `http://${devHost}:8100`;
export const API_TOKEN = process.env.EXPO_PUBLIC_API_TOKEN ?? 'dev-token-change-me';
