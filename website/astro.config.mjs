// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://scribe-site.kumard3.workers.dev',
  integrations: [sitemap()],
  build: { inlineStylesheets: 'auto' },
});
