import {
  SITE_URL,
  SITE_NAME,
  SITE_DESC,
  REPO,
  RELEASES,
  OG_IMAGE,
  APP_VERSION,
  AUTHOR,
} from '../consts';
import { FAQ } from '../data/faq';

const abs = (path: string) => new URL(path, SITE_URL).href;

export const softwareAppSchema = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: SITE_NAME,
  applicationCategory: 'ProductivityApplication',
  applicationSubCategory: 'Speech to text',
  operatingSystem: 'Android, macOS, Windows',
  url: SITE_URL,
  downloadUrl: RELEASES,
  softwareVersion: APP_VERSION,
  description: SITE_DESC,
  isAccessibleForFree: true,
  license: `${REPO}/blob/master/LICENSE`,
  screenshot: abs(OG_IMAGE),
  featureList: [
    'On-device live dictation',
    'Long-form record mode with background capture',
    'On-device speaker diarization',
    'Offline translation in 59 languages',
    'Floating Flow Bubble and voice keyboard',
    'Multiple selectable speech engines',
  ],
  offers: {
    '@type': 'Offer',
    price: '0',
    priceCurrency: 'USD',
  },
  author: {
    '@type': 'Person',
    name: AUTHOR,
    url: `https://github.com/${AUTHOR}`,
  },
};

export const webSiteSchema = {
  '@context': 'https://schema.org',
  '@type': 'WebSite',
  name: SITE_NAME,
  url: SITE_URL,
  description: SITE_DESC,
};

export const faqSchema = {
  '@context': 'https://schema.org',
  '@type': 'FAQPage',
  mainEntity: FAQ.map((item) => ({
    '@type': 'Question',
    name: item.q,
    acceptedAnswer: {
      '@type': 'Answer',
      text: item.a,
    },
  })),
};

export function breadcrumbSchema(trail: { name: string; path: string }[]) {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: trail.map((step, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      name: step.name,
      item: abs(step.path),
    })),
  };
}
