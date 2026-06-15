import { THEMES } from './themes';

// Active accent preset. Swap to 'tealOnBlack' or 'monoBlue' to change the whole app.
const ACTIVE = 'pureMono';

export const theme = THEMES[ACTIVE];

export const radius = { sm: 10, md: 14, lg: 20, pill: 999 };
export const space = { xs: 6, sm: 10, md: 16, lg: 22, xl: 30 };
