import { LanguageCode, ModelSpec } from './types';
import { DEFAULT_MODEL_ID, LANGUAGE_ROUTES, modelById } from './registry';

export function resolveModel(language: LanguageCode): ModelSpec {
  const id = LANGUAGE_ROUTES[language] ?? DEFAULT_MODEL_ID;
  return modelById(id);
}
