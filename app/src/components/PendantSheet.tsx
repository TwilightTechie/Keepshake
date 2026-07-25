import React from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { selectPendantSub, useAppStore } from '../store/appStore';
import { color, hairline, radius } from '../theme';
import { BatteryGlyph } from './BatteryGlyph';
import { Card, Separator } from './ui';

export function PendantSheet() {
  const deviceOpen = useAppStore((s) => s.deviceOpen);
  const setDeviceOpen = useAppStore((s) => s.setDeviceOpen);
  const pendant = useAppStore((s) => s.pendant);
  const toggleMute = useAppStore((s) => s.toggleMute);
  const pendantSub = useAppStore(selectPendantSub);
  const muted = pendant === 'muted';

  return (
    <Modal visible={deviceOpen} transparent animationType="slide" onRequestClose={() => setDeviceOpen(false)}>
      <Pressable style={styles.scrim} onPress={() => setDeviceOpen(false)} />
      <View style={styles.sheet}>
        <View style={styles.grabberWrap}>
          <View style={styles.grabber} />
        </View>
        <View style={styles.header}>
          <Text style={styles.title}>Pendant</Text>
          <Pressable onPress={() => setDeviceOpen(false)}>
            <Text style={styles.done}>Done</Text>
          </Pressable>
        </View>
        <ScrollView contentContainerStyle={styles.body}>
          {muted ? (
            <View style={styles.muteWarnCard}>
              <View style={styles.muteText}>
                <Text style={styles.muteWarnTitle}>Hard mute is on</Text>
                <Text style={styles.muteWarnSub}>
                  The microphone is powered off at the hardware switch. Nothing is heard, stored, or sent.
                </Text>
              </View>
              <Switch
                value
                onValueChange={toggleMute}
                trackColor={{ true: color.muted, false: 'rgba(120,120,128,.35)' }}
                thumbColor="#fff"
              />
            </View>
          ) : (
            <Card style={styles.muteCard}>
              <View style={styles.muteText}>
                <Text style={styles.muteTitle}>Hard mute</Text>
                <Text style={styles.muteSub}>Powers the microphone off at the hardware switch.</Text>
              </View>
              <Switch
                value={false}
                onValueChange={toggleMute}
                trackColor={{ true: color.muted, false: 'rgba(120,120,128,.35)' }}
                thumbColor="#fff"
              />
            </Card>
          )}

          <Card style={styles.batteryCard}>
            <BatteryGlyph width={34} height={52} />
            <View style={styles.muteText}>
              <Text style={styles.muteTitle}>82% · about 2 days</Text>
              <Text style={styles.muteSub}>{pendantSub}</Text>
            </View>
          </Card>

          <Card>
            <View style={styles.settingRow}>
              <Text style={styles.settingLabel}>Voice-activity sensitivity</Text>
              <Text style={styles.settingValue}>Balanced ▾</Text>
            </View>
            <Separator />
            <View style={styles.settingRow}>
              <Text style={styles.settingLabel}>Firmware</Text>
              <Text style={styles.firmware}>1.3.0 available · Update</Text>
            </View>
            <Separator />
            <View style={styles.settingRow}>
              <Text style={styles.settingLabel}>Pendant name</Text>
              <Text style={styles.settingValue}>Keepsake-7F2C</Text>
            </View>
          </Card>

          <View style={styles.forgetWrap}>
            <Text style={styles.forget}>Forget this pendant</Text>
          </View>
        </ScrollView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  scrim: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,.55)' },
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    top: 128,
    backgroundColor: color.sheet,
    borderTopLeftRadius: radius.sheet,
    borderTopRightRadius: radius.sheet,
    shadowColor: '#000',
    shadowOpacity: 0.6,
    shadowRadius: 20,
    shadowOffset: { width: 0, height: -12 },
  },
  grabberWrap: { alignItems: 'center', paddingTop: 9, paddingBottom: 2 },
  grabber: { width: 40, height: 4.5, borderRadius: radius.pill, backgroundColor: 'rgba(235,235,245,.25)' },
  header: {
    paddingTop: 10,
    paddingHorizontal: 20,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  title: { fontSize: 22, fontWeight: '700', color: color.text },
  done: { fontSize: 14, fontWeight: '600', color: color.link },
  body: { padding: 16, paddingTop: 14, paddingBottom: 24, gap: 11 },
  muteWarnCard: {
    backgroundColor: 'rgba(255,184,77,.12)',
    borderWidth: 1,
    borderColor: 'rgba(255,184,77,.55)',
    borderRadius: radius.card,
    padding: 14,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 13,
  },
  muteCard: { padding: 14, flexDirection: 'row', alignItems: 'center', gap: 13 },
  batteryCard: { padding: 14, flexDirection: 'row', alignItems: 'center', gap: 14 },
  muteText: { flex: 1, gap: 2 },
  muteWarnTitle: { fontSize: 16, fontWeight: '700', color: color.muted },
  muteWarnSub: { fontSize: 12.5, lineHeight: 18, color: 'rgba(235,235,245,.65)' },
  muteTitle: { fontSize: 16, fontWeight: '600', color: color.text },
  muteSub: { fontSize: 12.5, lineHeight: 18, color: color.text55 },
  settingRow: {
    paddingVertical: 12,
    paddingHorizontal: 14,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  settingLabel: { flex: 1, fontSize: 14.5, color: color.text },
  settingValue: { fontSize: 13.5, color: color.text55 },
  firmware: { fontSize: 13.5, fontWeight: '600', color: color.commitment },
  forgetWrap: { alignItems: 'center', paddingTop: 2 },
  forget: { fontSize: 14, fontWeight: '600', color: color.recording },
});
