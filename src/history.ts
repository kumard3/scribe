import { File, Paths } from 'expo-file-system';

export type HistoryItem = {
  id: string;
  text: string;
  language: string;
  translated: boolean;
  translatedTo?: string;
  createdAt: number;
};

const MAX_ITEMS = 200;

function file(): File {
  return new File(Paths.document, 'history.json');
}

export function loadHistory(): HistoryItem[] {
  try {
    const f = file();
    if (!f.exists) return [];
    const parsed = JSON.parse(f.textSync());
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function persist(items: HistoryItem[]): void {
  const f = file();
  if (!f.exists) f.create();
  f.write(JSON.stringify(items));
}

export function addHistory(
  entry: Omit<HistoryItem, 'id' | 'createdAt'>
): HistoryItem[] {
  const item: HistoryItem = {
    ...entry,
    id: `${Date.now()}-${Math.round(Math.random() * 1e6)}`,
    createdAt: Date.now(),
  };
  const next = [item, ...loadHistory()].slice(0, MAX_ITEMS);
  persist(next);
  return next;
}

export function updateHistory(id: string, text: string): HistoryItem[] {
  const next = loadHistory().map((i) => (i.id === id ? { ...i, text } : i));
  persist(next);
  return next;
}

export function deleteHistory(id: string): HistoryItem[] {
  const next = loadHistory().filter((i) => i.id !== id);
  persist(next);
  return next;
}

export function clearHistory(): HistoryItem[] {
  persist([]);
  return [];
}
