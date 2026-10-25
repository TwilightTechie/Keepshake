import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { color } from '../theme';
import { StatusPill } from './StatusPill';

/** Black screen background with the pendant status pill pinned under the notch. */
export function ScreenShell({ children }: { children: React.ReactNode }) {
  const insets = useSafeAreaInsets();
  return (
    <View style={[styles.root, { paddingTop: insets.top + 8 }]}>
      <StatusPill />
      <View style={styles.body}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: color.bg },
  body: { flex: 1, minHeight: 0 },
});
