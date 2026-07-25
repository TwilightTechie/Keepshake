import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useAppStore } from '../store/appStore';
import { color, radius } from '../theme';
import { MutedMicIcon } from './icons';

/**
 * The pendant consent surface (PR-1): visible on every tab.
 * Tapping it opens the pendant sheet.
 */
export function StatusPill() {
  const pendant = useAppStore((s) => s.pendant);
  const setDeviceOpen = useAppStore((s) => s.setDeviceOpen);

  return (
    <View style={styles.wrap}>
      <Pressable onPress={() => setDeviceOpen(true)} style={({ pressed }) => pressed && { transform: [{ scale: 0.97 }] }}>
        {pendant === 'recording' && (
          <View style={[styles.pill, styles.recPill]}>
            <View style={styles.recDot} />
            <Text style={styles.recText}>Recording</Text>
            <Text style={styles.recPct}>· 82%</Text>
          </View>
        )}
        {pendant === 'muted' && (
          <View style={[styles.pill, styles.mutedPill]}>
            <MutedMicIcon />
            <Text style={styles.mutedText}>Muted</Text>
          </View>
        )}
        {pendant === 'disconnected' && (
          <View style={[styles.pill, styles.discPill]}>
            <View style={styles.discDot} />
            <Text style={styles.discText}>Disconnected</Text>
            <Text style={styles.discSub}>· last seen 2:14 PM</Text>
          </View>
        )}
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { paddingHorizontal: 16, alignItems: 'center' },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    height: 36,
    paddingHorizontal: 16,
    borderRadius: radius.pill,
  },
  recPill: {
    backgroundColor: color.chipTrack,
    borderWidth: 0.5,
    borderColor: 'rgba(255,98,89,.4)',
  },
  recDot: {
    width: 9,
    height: 9,
    borderRadius: radius.pill,
    backgroundColor: color.recording,
    shadowColor: color.recording,
    shadowOpacity: 0.8,
    shadowRadius: 4,
    shadowOffset: { width: 0, height: 0 },
  },
  recText: { fontSize: 13, fontWeight: '600', color: color.text },
  recPct: { fontSize: 13, color: color.text2 },
  mutedPill: { backgroundColor: color.muted },
  mutedText: { fontSize: 13, fontWeight: '700', color: '#1a1a1a' },
  discPill: { borderWidth: 1, borderColor: 'rgba(235,235,245,.25)' },
  discDot: {
    width: 9,
    height: 9,
    borderRadius: radius.pill,
    borderWidth: 1.5,
    borderColor: 'rgba(235,235,245,.4)',
  },
  discText: { fontSize: 13, fontWeight: '600', color: color.text55 },
  discSub: { fontSize: 13, color: 'rgba(235,235,245,.4)' },
});
