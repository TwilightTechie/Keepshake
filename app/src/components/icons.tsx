import React from 'react';
import Svg, { Circle, Path, Rect } from 'react-native-svg';
import { color } from '../theme';

export function Chevron({ size = 12, stroke = 'rgba(235,235,245,.3)' }: { size?: number; stroke?: string }) {
  return (
    <Svg width={(size * 7) / 12} height={size} viewBox="0 0 8 14">
      <Path d="M1 1l6 6-6 6" stroke={stroke} strokeWidth={2} fill="none" strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function BackChevron() {
  return (
    <Svg width={10} height={16} viewBox="0 0 12 20">
      <Path d="M10 2L2 10l8 8" stroke={color.link} strokeWidth={2.2} fill="none" strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function SearchIcon() {
  return (
    <Svg width={14} height={14} viewBox="0 0 14 14">
      <Circle cx={6} cy={6} r={4.5} fill="none" stroke="rgba(235,235,245,.4)" strokeWidth={1.6} />
      <Path d="M9.5 9.5L13 13" stroke="rgba(235,235,245,.4)" strokeWidth={1.6} strokeLinecap="round" />
    </Svg>
  );
}

export function MutedMicIcon() {
  return (
    <Svg width={14} height={16} viewBox="0 0 14 16">
      <Rect x={4.5} y={1} width={5} height={9} rx={2.5} fill="#1a1a1a" />
      <Path d="M2 7.5a5 5 0 0010 0M7 12.5V15" fill="none" stroke="#1a1a1a" strokeWidth={1.6} strokeLinecap="round" />
      <Path d="M1 1l12 14" stroke={color.muted} strokeWidth={4} />
      <Path d="M1 1l12 14" stroke="#1a1a1a" strokeWidth={1.8} strokeLinecap="round" />
    </Svg>
  );
}

export function MicIcon() {
  return (
    <Svg width={14} height={18} viewBox="0 0 14 18">
      <Rect x={4.5} y={1} width={5} height={9} rx={2.5} fill="rgba(235,235,245,.7)" />
      <Path d="M2 7.5a5 5 0 0010 0M7 12.5V16" fill="none" stroke="rgba(235,235,245,.7)" strokeWidth={1.6} strokeLinecap="round" />
    </Svg>
  );
}

export function ExportIcon({ stroke = 'rgba(235,235,245,.55)' }: { stroke?: string }) {
  return (
    <Svg width={14} height={14} viewBox="0 0 14 14">
      <Path d="M7 1v8M4 6l3 3 3-3M2 11v2h10v-2" fill="none" stroke={stroke} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function CheckSmall() {
  return (
    <Svg width={10} height={8} viewBox="0 0 10 8">
      <Path d="M1 4l2.6 2.6L9 1" fill="none" stroke="#000" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function XIcon() {
  return (
    <Svg width={20} height={20} viewBox="0 0 20 20">
      <Path d="M4 4l12 12M16 4L4 16" stroke={color.recording} strokeWidth={2.2} strokeLinecap="round" />
    </Svg>
  );
}

export function PencilIcon() {
  return (
    <Svg width={20} height={20} viewBox="0 0 20 20">
      <Path d="M3 14.5V17h2.5L15 7.5 12.5 5 3 14.5zM13.8 3.7l2.5 2.5" fill="none" stroke="rgba(235,235,245,.75)" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function AcceptIcon() {
  return (
    <Svg width={22} height={18} viewBox="0 0 22 18">
      <Path d="M2.5 9.5l6 6L19.5 3" fill="none" stroke={color.fact} strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function AllClearIcon() {
  return (
    <Svg width={26} height={20} viewBox="0 0 26 20">
      <Path d="M3 10.5l7 7L23 3" fill="none" stroke={color.fact} strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function BubbleSmallIcon() {
  return (
    <Svg width={11} height={11} viewBox="0 0 22 22">
      <Path d="M4 5h14v9h-8l-4 3.5V14H4z" fill="none" stroke="rgba(235,235,245,.7)" strokeWidth={2} strokeLinejoin="round" />
    </Svg>
  );
}

/* ---- tab icons ---- */

export function HomeTabIcon({ c }: { c: string }) {
  return (
    <Svg width={22} height={22} viewBox="0 0 22 22">
      <Path d="M4 10.5L11 4l7 6.5V18h-5v-4.5h-4V18H4v-7.5z" fill="none" stroke={c} strokeWidth={1.8} strokeLinejoin="round" />
    </Svg>
  );
}

export function ConvosTabIcon({ c }: { c: string }) {
  return (
    <Svg width={22} height={22} viewBox="0 0 22 22">
      <Path d="M4 5h14v9h-8l-4 3.5V14H4z" fill="none" stroke={c} strokeWidth={1.7} strokeLinejoin="round" />
    </Svg>
  );
}

export function TasksTabIcon({ c }: { c: string }) {
  return (
    <Svg width={22} height={22} viewBox="0 0 22 22">
      <Circle cx={11} cy={11} r={7.5} fill="none" stroke={c} strokeWidth={1.7} />
      <Path d="M7.5 11.3l2.4 2.4 4.6-4.9" fill="none" stroke={c} strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function MemoryTabIcon({ c }: { c: string }) {
  return (
    <Svg width={22} height={22} viewBox="0 0 22 22">
      <Rect x={4} y={4.5} width={14} height={2} rx={1} fill={c} />
      <Rect x={4} y={10} width={14} height={2} rx={1} fill={c} />
      <Rect x={4} y={15.5} width={9} height={2} rx={1} fill={c} />
    </Svg>
  );
}
