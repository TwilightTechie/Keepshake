import { Tabs } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import React, { useEffect } from 'react';
import { PendantSheet } from '@/components/PendantSheet';
import { TabBar } from '@/components/TabBar';
import { useAppStore } from '@/store/appStore';
import { color } from '@/theme';

export default function RootLayout() {
  const hydrate = useAppStore((s) => s.hydrate);
  useEffect(() => {
    void hydrate();
  }, [hydrate]);
  return (
    <>
      <StatusBar style="light" />
      <Tabs
        screenOptions={{ headerShown: false, sceneStyle: { backgroundColor: color.bg } }}
        tabBar={(props) => <TabBar {...props} />}
      >
        <Tabs.Screen name="index" options={{ title: 'Home' }} />
        <Tabs.Screen name="convos" options={{ title: 'Convos' }} />
        <Tabs.Screen name="tasks" options={{ title: 'Tasks' }} />
        <Tabs.Screen name="memory" options={{ title: 'Memory' }} />
        <Tabs.Screen name="ask" options={{ title: 'Ask' }} />
      </Tabs>
      <PendantSheet />
    </>
  );
}
