import { StyleSheet } from 'react-native';

export const color = {
  bg: '#000',
  card: '#1C1C1E',
  cardRecessed: '#141416',
  sheet: '#161618',
  bubbleUser: '#2C2C2E',
  chipTrack: 'rgba(120,120,128,.24)',
  separator: 'rgba(84,84,88,.65)',

  text: '#FFF',
  text2: 'rgba(235,235,245,.6)',
  text3: 'rgba(235,235,245,.45)',
  text4: 'rgba(235,235,245,.35)',
  text55: 'rgba(235,235,245,.55)',
  text5: 'rgba(235,235,245,.5)',
  text7: 'rgba(235,235,245,.7)',
  text75: 'rgba(235,235,245,.75)',
  text85: 'rgba(235,235,245,.85)',
  text9: 'rgba(235,235,245,.9)',

  decision: '#6CA8FF',
  commitment: '#E5A54B',
  fact: '#6FBF8F',
  question: '#B28CE0',

  recording: '#FF6259',
  muted: '#FFB84D',
  overdue: '#FF8A80',
  link: '#6CA8FF',

  tabActive: '#6CA8FF',
  tabInactive: 'rgba(235,235,245,.5)',
  tabBarBg: 'rgba(28,28,30,.9)',
} as const;

export const entryColor = {
  decision: color.decision,
  commitment: color.commitment,
  fact: color.fact,
  question: color.question,
} as const;

export const radius = {
  card: 16,
  review: 18,
  sheet: 22,
  input: 11,
  banner: 12,
  pill: 999,
} as const;

export const hairline = StyleSheet.hairlineWidth;
