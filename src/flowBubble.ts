import { NativeModules, Platform } from 'react-native';

// Android-only floating dictation bubble that types into any app via an
// AccessibilityService. iOS has no equivalent (the OS forbids it), so the
// whole surface is gated to Android.
type FlowBubbleNative = {
  isOverlayGranted(): Promise<boolean>;
  requestOverlayPermission(): Promise<boolean>;
  isAccessibilityEnabled(): Promise<boolean>;
  openAccessibilitySettings(): Promise<boolean>;
  isRunning(): Promise<boolean>;
  start(): Promise<boolean>;
  stop(): Promise<boolean>;
};

const native: FlowBubbleNative | null =
  Platform.OS === 'android' ? (NativeModules.FlowBubble ?? null) : null;

export const flowBubbleSupported = native != null;

export const FlowBubble = {
  isOverlayGranted: () => native?.isOverlayGranted() ?? Promise.resolve(false),
  requestOverlayPermission: () => native?.requestOverlayPermission() ?? Promise.resolve(false),
  isAccessibilityEnabled: () => native?.isAccessibilityEnabled() ?? Promise.resolve(false),
  openAccessibilitySettings: () => native?.openAccessibilitySettings() ?? Promise.resolve(false),
  isRunning: () => native?.isRunning() ?? Promise.resolve(false),
  start: () => native?.start() ?? Promise.resolve(false),
  stop: () => native?.stop() ?? Promise.resolve(false),
};
