import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { ModelSpec } from './types';

function modelsDir(): Directory {
  const dir = new Directory(Paths.document, 'models');
  if (!dir.exists) dir.create({ intermediates: true });
  return dir;
}

export function localFile(model: ModelSpec): File {
  return new File(modelsDir(), model.fileName);
}

export function isInstalled(model: ModelSpec): boolean {
  return localFile(model).exists;
}

export async function downloadModel(
  model: ModelSpec,
  onProgress?: (ratio: number) => void
): Promise<File> {
  const dest = localFile(model);
  if (dest.exists) return dest;

  const task = new DownloadTask(model.url, dest, {
    onProgress: ({ bytesWritten, totalBytes }) => {
      if (totalBytes > 0) onProgress?.(bytesWritten / totalBytes);
    },
  });
  const file = await task.downloadAsync();
  if (!file) throw new Error(`Download of ${model.id} did not complete`);
  return file;
}

export function deleteModel(model: ModelSpec): void {
  const f = localFile(model);
  if (f.exists) f.delete();
}
