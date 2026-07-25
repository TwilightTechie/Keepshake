import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useAppStore } from '../store/appStore';
import { color, hairline, radius } from '../theme';
import { CheckSmall, ExportIcon } from './icons';
import type { Task } from '../types';

export function TaskRow({
  task,
  last,
  metaColor = color.text5,
  circleColor = 'rgba(235,235,245,.3)',
  showExport,
}: {
  task: Task;
  last?: boolean;
  metaColor?: string;
  circleColor?: string;
  showExport?: boolean;
}) {
  const toggleTask = useAppStore((s) => s.toggleTask);
  return (
    <Pressable onPress={() => toggleTask(task.id)} style={[styles.row, !last && styles.rowBorder]}>
      {task.done ? (
        <View style={styles.doneCircle}>
          <CheckSmall />
        </View>
      ) : (
        <View style={[styles.openCircle, { borderColor: circleColor }]} />
      )}
      <View style={styles.text}>
        <Text
          style={[
            styles.title,
            { color: task.done ? color.text3 : color.text, textDecorationLine: task.done ? 'line-through' : 'none' },
          ]}
        >
          {task.title}
        </Text>
        <Text style={[styles.meta, { color: metaColor }]}>{task.meta}</Text>
      </View>
      {showExport && <ExportIcon stroke="rgba(235,235,245,.35)" />}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    paddingVertical: 11,
    paddingHorizontal: 14,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 11,
  },
  rowBorder: { borderBottomWidth: hairline, borderBottomColor: color.separator },
  doneCircle: {
    width: 20,
    height: 20,
    borderRadius: radius.pill,
    backgroundColor: color.fact,
    alignItems: 'center',
    justifyContent: 'center',
  },
  openCircle: { width: 20, height: 20, borderRadius: radius.pill, borderWidth: 1.5 },
  text: { flex: 1, gap: 1 },
  title: { fontSize: 14.5, fontWeight: '500', lineHeight: 19 },
  meta: { fontSize: 12 },
});
