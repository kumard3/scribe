import { Component, type ReactNode } from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';

type Props = { children: ReactNode };
type State = { error: Error | null };

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <View style={{ flex: 1, backgroundColor: '#000', padding: 24, justifyContent: 'center' }}>
        <Text style={{ color: '#fff', fontSize: 20, fontWeight: '600', marginBottom: 8 }}>
          Something broke
        </Text>
        <Text style={{ color: '#9a9a9a', fontSize: 14, marginBottom: 16 }}>
          The app hit an error instead of closing. Tap below to start over.
        </Text>
        <ScrollView style={{ maxHeight: 220, marginBottom: 20 }}>
          <Text style={{ color: '#6a6a6a', fontSize: 12 }}>
            {error.message}
            {'\n\n'}
            {error.stack?.slice(0, 1200)}
          </Text>
        </ScrollView>
        <Pressable
          onPress={() => this.setState({ error: null })}
          style={{ backgroundColor: '#fff', borderRadius: 12, paddingVertical: 14, alignItems: 'center' }}
        >
          <Text style={{ color: '#000', fontSize: 16, fontWeight: '600' }}>Try again</Text>
        </Pressable>
      </View>
    );
  }
}
