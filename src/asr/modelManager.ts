import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { ModelSpec } from './types';
import { MODELS } from './registry';

function modelsDir(): Directory {
  const dir = new Directory(Paths.document, 'models');
  if (!dir.exists) dir.create({ intermediates: true });
  return dir;
}

export function localFile(model: ModelSpec): File {
  return new File(modelsDir(), model.fileName);
}

export function isInstalled(model: ModelSpec): boolean {
  const f = localFile(model);
  return f.exists && f.size === model.sizeBytes;
}

export async function downloadModel(
  model: ModelSpec,
  onProgress?: (ratio: number) => void
): Promise<File> {
  const dest = localFile(model);
  if (isInstalled(model)) return dest;
  if (dest.exists) dest.delete();

  const task = new DownloadTask(model.url, dest, {
    onProgress: ({ bytesWritten, totalBytes }) => {
      const total = totalBytes > 0 ? totalBytes : model.sizeBytes;
      if (total > 0) onProgress?.(bytesWritten / total);
    },
  });
  const file = await task.downloadAsync();
  if (!file) throw new Error(`Download of ${model.id} did not complete`);

  if (file.size !== model.sizeBytes) {
    file.delete();
    throw new Error(
      `Model "${model.label}" downloaded incomplete (${file.size} of ${model.sizeBytes} bytes). Please retry.`
    );
  }
  return file;
}

export function deleteModel(model: ModelSpec): void {
  const f = localFile(model);
  if (f.exists) f.delete();
}

export function installedStorageBytes(): number {
  return MODELS.reduce((sum, m) => {
    const f = localFile(m);
    return sum + (f.exists ? f.size : 0);
  }, 0);
}

export function deleteAllModels(): void {
  const dir = modelsDir();
  if (dir.exists) dir.delete();
}
