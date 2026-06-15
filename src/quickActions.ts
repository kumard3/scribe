import { Platform } from 'react-native';
import * as QuickActions from 'expo-quick-actions';

export const QA_DICTATE = 'vox.dictate';
export const QA_HISTORY = 'vox.history';

const ITEMS: QuickActions.Action[] = [
  {
    id: QA_DICTATE,
    title: 'Start dictation',
    subtitle: 'Live, on-device',
    icon: Platform.OS === 'ios' ? 'symbol:mic.fill' : undefined,
    params: { mode: 'live' },
  },
  {
    id: QA_HISTORY,
    title: 'History',
    subtitle: 'Recent transcripts',
    icon: Platform.OS === 'ios' ? 'symbol:clock.fill' : undefined,
    params: { mode: 'history' },
  },
];

export async function registerQuickActions(): Promise<void> {
  try {
    await QuickActions.setItems(ITEMS);
  } catch {
    // best effort — long-press shortcuts are a nicety, not load-bearing
  }
}
