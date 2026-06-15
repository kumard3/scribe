export type Theme = {
  bg: string;
  surface: string;
  surfaceAlt: string;
  border: string;
  primary: string;
  primaryDim: string;
  onPrimary: string;
  danger: string;
  text: string;
  textDim: string;
  textFaint: string;
};

// Swappable accent presets. Active one is exported from theme.ts.
// To switch: change ACTIVE in theme.ts to 'tealOnBlack' | 'monoBlue' | 'pureMono'.
export const THEMES: Record<string, Theme> = {
  tealOnBlack: {
    bg: '#08080A',
    surface: '#161619',
    surfaceAlt: '#1F1F24',
    border: '#2A2A31',
    primary: '#14B8A6',
    primaryDim: '#0E4F49',
    onPrimary: '#FFFFFF',
    danger: '#FF453A',
    text: '#FFFFFF',
    textDim: '#9A9AA3',
    textFaint: '#5C5C66',
  },
  monoBlue: {
    bg: '#000000',
    surface: '#161618',
    surfaceAlt: '#1E1E22',
    border: '#2A2A2E',
    primary: '#0A84FF',
    primaryDim: '#0A3A66',
    onPrimary: '#FFFFFF',
    danger: '#FF453A',
    text: '#FFFFFF',
    textDim: '#9A9AA3',
    textFaint: '#5C5C66',
  },
  pureMono: {
    bg: '#000000',
    surface: '#141416',
    surfaceAlt: '#1C1C1F',
    border: '#2A2A2E',
    primary: '#FFFFFF',
    primaryDim: '#3A3A3E',
    onPrimary: '#000000',
    danger: '#FF453A',
    text: '#FFFFFF',
    textDim: '#9A9AA3',
    textFaint: '#5C5C66',
  },
};
