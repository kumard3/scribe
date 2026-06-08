import { File } from 'expo-file-system';

export function deleteFileSafe(uri: string | null | undefined): void {
  if (!uri) return;
  try {
    const f = new File(uri);
    if (f.exists) f.delete();
  } catch {
    // best-effort cleanup
  }
}
