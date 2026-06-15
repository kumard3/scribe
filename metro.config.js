const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const config = getDefaultConfig(__dirname);

// whisper.rn exposes its realtime classes under a `./*` exports wildcard whose
// target is a directory; Metro's package-exports resolver won't index it, so
// `whisper.rn/realtime-transcription` fails to resolve. Point it at the built
// module file directly. (The `/adapters` subpath needs @fugood, which we don't
// install — the index re-exports only the transcriber + helpers, not adapters.)
const baseResolveRequest = config.resolver.resolveRequest;
config.resolver.resolveRequest = (context, moduleName, platform) => {
  if (moduleName === 'whisper.rn/realtime-transcription') {
    return {
      type: 'sourceFile',
      filePath: path.resolve(
        __dirname,
        'node_modules/whisper.rn/lib/module/realtime-transcription/index.js'
      ),
    };
  }
  const resolver = baseResolveRequest || context.resolveRequest;
  return resolver(context, moduleName, platform);
};

module.exports = config;
