import { Stack } from 'expo-router';
import React from 'react';
import { color } from '@/theme';

export default function ConvosLayout() {
  return <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: color.bg } }} />;
}
