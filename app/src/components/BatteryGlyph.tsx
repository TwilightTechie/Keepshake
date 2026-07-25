import React from 'react';
import { View } from 'react-native';
import { color } from '../theme';

/** Vertical battery outline with green fill, as drawn in the prototype. */
export function BatteryGlyph({ width = 26, height = 40, level = 0.8 }: { width?: number; height?: number; level?: number }) {
  const pad = width < 30 ? 2.5 : 3;
  return (
    <View
      style={{
        width,
        height,
        borderRadius: width < 30 ? 8 : 10,
        borderWidth: 1.5,
        borderColor: 'rgba(235,235,245,.35)',
        justifyContent: 'flex-end',
        padding: pad,
      }}
    >
      <View style={{ width: '100%', height: `${level * 100}%`, borderRadius: width < 30 ? 5 : 6, backgroundColor: color.fact }} />
    </View>
  );
}
