import { registerRootComponent } from 'expo';
import { createElement } from 'react';

import App from './App';
import { ErrorBoundary } from './src/ui/ErrorBoundary';

registerRootComponent(() => createElement(ErrorBoundary, null, createElement(App)));
