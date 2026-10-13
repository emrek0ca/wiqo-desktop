import { MaterialCommunityIcons } from '@expo/vector-icons';
import * as Clipboard from 'expo-clipboard';
import { useState } from 'react';
import { Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { ChatArtifact, ChatWidget } from '@/data/chat-api';
import { useWiqoColors } from '@/theme';
import { ChatWidgetCard } from './ChatWidgetCard';

type Props = {
  text: string;
  widgets?: ChatWidget[];
  artifacts?: ChatArtifact[];
  streaming?: boolean;
  onFollowUp: (text: string) => void;
  onClarification: (text: string, taskId: string, questionId: string) => void;
  onAct: (text: string) => void;
  onAsk: (text: string) => void;
  onFix: (text: string) => void;
  activeQuestionId?: string;
  sending?: boolean;
};

type Block = { kind: 'paragraph' | 'heading' | 'quote' | 'list' | 'code' | 'table' | 'rule'; lines: string[]; level?: number; language?: string };

function parseBlocks(text: string): Block[] {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const blocks: Block[] = [];
  let index = 0;
  while (index < lines.length) {
    const raw = lines[index] ?? '';
    const line = raw.trim();
    if (!line) { index += 1; continue; }
    if (line.startsWith('```')) {
      const language = line.slice(3).trim();
      const code: string[] = [];
      index += 1;
      while (index < lines.length && !(lines[index] ?? '').trim().startsWith('```')) code.push(lines[index++] ?? '');
      index += 1;
      blocks.push({ kind: 'code', lines: code, language });
    } else if (/^\|.+\|$/.test(line) && index + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[index + 1] ?? '')) {
      const cells = (value: string) => value.trim().replace(/^\||\|$/g, '').split('|').map(cell => cell.trim());
      const rows = [cells(line)];
      index += 2;
      while (index < lines.length && /^\s*\|/.test(lines[index] ?? '')) rows.push(cells(lines[index++] ?? ''));
      blocks.push({ kind: 'table', lines: rows.map(row => row.join('\u001f')) });
    } else if (/^#{1,6}\s+/.test(line)) {
      const match = /^(#{1,6})\s+(.*)$/.exec(line)!;
      blocks.push({ kind: 'heading', level: match[1]!.length, lines: [match[2]!] }); index += 1;
    } else if (/^(---+|___+|\*\*\*+)$/.test(line)) {
      blocks.push({ kind: 'rule', lines: [] }); index += 1;
    } else if (/^>\s?/.test(line)) {
      const quote: string[] = [];
      while (index < lines.length && /^\s*>/.test(lines[index] ?? '')) quote.push((lines[index++] ?? '').replace(/^\s*>\s?/, ''));
      blocks.push({ kind: 'quote', lines: quote });
    } else if (/^\s*(?:[-+*]|\d+[.)])\s+/.test(raw)) {
      const list: string[] = [];
      while (index < lines.length && /^\s*(?:[-+*]|\d+[.)])\s+/.test(lines[index] ?? '')) list.push(lines[index++] ?? '');
      blocks.push({ kind: 'list', lines: list });
    } else {
      const paragraph = [line]; index += 1;
      while (index < lines.length && (lines[index] ?? '').trim() && !/^(?:```|#{1,6}\s|>|\s*(?:[-+*]|\d+[.)])\s+)/.test(lines[index] ?? '')) paragraph.push((lines[index++] ?? '').trim());
      blocks.push({ kind: 'paragraph', lines: paragraph });
    }
  }
  return blocks;
}

function InlineText({ value, color, fontSize, selectable = true }: { value: string; color: string; fontSize: number; selectable?: boolean }) {
  const tokens = value.split(/(\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|`[^`]+`|\*[^*]+\*|_[^_]+_|https?:\/\/[^\s)]+)/g).filter(Boolean);
  return <Text selectable={selectable} style={{ color, fontSize, lineHeight: fontSize * 1.48 }}>{tokens.map((token, index) => {
    const bold = (token.startsWith('**') && token.endsWith('**')) || (token.startsWith('__') && token.endsWith('__'));
    const italic = !bold && ((token.startsWith('*') && token.endsWith('*')) || (token.startsWith('_') && token.endsWith('_')));
    const code = token.startsWith('`') && token.endsWith('`');
    const strike = token.startsWith('~~') && token.endsWith('~~');
    const link = /^https?:\/\//.test(token);
    const content = bold || italic || code || strike ? token.slice(bold || strike ? 2 : 1, -(bold || strike ? 2 : 1)) : token;
    if (link) return <Text key={index} style={{ color: '#477e70', textDecorationLine: 'underline' }} onPress={() => void Linking.openURL(token)}>{token}</Text>;
    return <Text key={index} style={[bold && { fontWeight: '700' }, italic && { fontStyle: 'italic' }, code && { fontFamily: 'monospace', backgroundColor: 'rgba(120,120,128,0.12)' }, strike && { textDecorationLine: 'line-through' }]}>{content}</Text>;
  })}</Text>;
}

function CodeBlock({ code, language, background, ink }: { code: string; language?: string; background: string; ink: string }) {
  const [copied, setCopied] = useState(false);
  return <View style={[styles.codeCard, { backgroundColor: background }]}>
    <View style={styles.codeHeader}><Text style={[styles.codeLanguage, { color: ink }]}>{language || 'Kod'}</Text><Pressable accessibilityRole="button" onPress={() => { void Clipboard.setStringAsync(code); setCopied(true); }} style={styles.codeCopy}><MaterialCommunityIcons name={copied ? 'check' : 'content-copy'} size={15} color={ink} /><Text style={[styles.codeLanguage, { color: ink }]}>{copied ? 'Kopyalandı' : 'Kopyala'}</Text></Pressable></View>
    <ScrollView horizontal showsHorizontalScrollIndicator={false}><Text selectable style={[styles.codeText, { color: ink }]}>{code}</Text></ScrollView>
  </View>;
}

export function ChatReply({ text, widgets = [], artifacts = [], streaming = false, onFollowUp, onClarification, onAct, onAsk, onFix, activeQuestionId, sending = false }: Props) {
  const colors = useWiqoColors();
  const blocks = parseBlocks(text);
  const hiddenText = widgets.some(widget => widget.presentation === 'widget_only');
  const replaced = new Set(widgets.map(widget => typeof widget.replaces === 'string' ? widget.replaces : '').filter(Boolean));
  const hasArtifactCard = artifacts.length > 0 || widgets.some(widget => widget.type === 'artifact');
  const visibleWidgets = widgets.filter(widget => {
    if (widget.type === 'approval' || widget.type === 'unknown') return false;
    if (widget.type === 'task_plan' && Array.isArray(widget.planSteps) && widget.planSteps.length > 0 && widget.planSteps.every(step => (step as Record<string, unknown>).status === 'verified')) return false;
    if (widget.type === 'task_result' && (!widget.taskStatus || widget.taskStatus === 'completed')) return false;
    if (widget.type === 'list' && hasArtifactCard && widget.domain === 'files' && String(widget.widgetId ?? '').startsWith('file-evidence-')) return false;
    return true;
  });
  return <View style={styles.root}>
    {!hiddenText && blocks.map((block, index) => {
      if (block.kind === 'rule') return <View key={index} style={[styles.rule, { backgroundColor: colors.line }]} />;
      if (block.kind === 'code') return <CodeBlock key={index} code={block.lines.join('\n')} language={block.language} background={colors.surface} ink={colors.ink} />;
      if (block.kind === 'table') {
        const rows = block.lines.map(row => row.split('\u001f'));
        return <ScrollView key={index} horizontal showsHorizontalScrollIndicator contentContainerStyle={[styles.table, { borderColor: colors.line }]}><View>{rows.map((row, rowIndex) => <View key={rowIndex} style={[styles.tableRow, { borderBottomColor: colors.line, backgroundColor: rowIndex === 0 ? colors.surface : 'transparent' }]}>{row.map((cell, cellIndex) => <View key={cellIndex} style={[styles.tableCell, { borderRightColor: colors.line }]}><InlineText value={cell} color={colors.ink} fontSize={13} /></View>)}</View>)}</View></ScrollView>;
      }
      if (block.kind === 'list') return <View key={index} style={styles.list}>{block.lines.map((line, row) => { const match = /^\s*((?:[-+*])|(?:\d+[.)]))\s+(.*)$/.exec(line); return <View key={row} style={styles.listRow}><Text style={[styles.listMarker, { color: colors.muted }]}>{match?.[1] ?? '•'}</Text><View style={styles.listText}><InlineText value={match?.[2] ?? line} color={colors.ink} fontSize={16} /></View></View>; })}</View>;
      if (block.kind === 'quote') return <View key={index} style={[styles.quote, { borderLeftColor: colors.line }]}><InlineText value={block.lines.join('\n')} color={colors.muted} fontSize={15} /></View>;
      const value = block.lines.join('\n');
      return block.kind === 'heading' ? <View key={index} style={styles.heading}><InlineText value={value} color={colors.ink} fontSize={block.level === 1 ? 23 : block.level === 2 ? 19 : 16} /></View> : <View key={index} style={styles.paragraph}><InlineText value={value} color={colors.ink} fontSize={16} /></View>;
    })}
    {streaming && !text ? <View style={styles.loading}><View style={[styles.loadingDot, { backgroundColor: colors.muted }]} /><Text style={{ color: colors.muted, fontSize: 13 }}>Yanıt hazırlanıyor</Text></View> : null}
    {visibleWidgets.map((widget, index) => {
      const artifact = artifacts.find(item => item.id === widget.artifactId);
      const widgetId = String(widget.widgetId ?? `${widget.type}-${index}`);
      if (widget.type === 'inline_app' && replaced.has(widgetId)) return <Text key={widgetId} style={{ color: colors.muted, fontSize: 12, paddingVertical: 4 }}>{`“${String(widget.title ?? 'Uygulama')}” güncellendi; yeni sürümü aşağıda.`}</Text>;
      return <ChatWidgetCard key={widgetId} widget={widget} artifact={artifact} onFollowUp={onFollowUp} onClarification={onClarification} onAct={onAct} onAsk={onAsk} onFix={onFix} activeQuestionId={activeQuestionId} sending={sending} />;
    })}
    {artifacts.filter(artifact => !widgets.some(widget => widget.artifactId === artifact.id)).map(artifact => <Pressable key={artifact.id} accessibilityRole="button" onPress={() => void Linking.openURL(artifact.downloadURL)} style={[styles.artifactRow, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="file-download-outline" size={20} color={colors.muted} /><Text numberOfLines={1} style={[styles.artifactName, { color: colors.ink }]}>{artifact.filename}</Text><MaterialCommunityIcons name="arrow-top-right" size={17} color={colors.muted} /></Pressable>)}
  </View>;
}

const styles = StyleSheet.create({
  root: { width: '100%', alignSelf: 'stretch', gap: 11 },
  paragraph: { width: '100%' },
  heading: { width: '100%', paddingTop: 3, paddingBottom: 1 },
  list: { width: '100%', gap: 6 },
  listRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 8 },
  listMarker: { width: 22, textAlign: 'right', fontSize: 15, lineHeight: 24 },
  listText: { flex: 1, minWidth: 0 },
  quote: { width: '100%', borderLeftWidth: 3, paddingLeft: 12, paddingVertical: 2 },
  rule: { width: '100%', height: StyleSheet.hairlineWidth, marginVertical: 4 },
  codeCard: { width: '100%', borderRadius: 14, paddingVertical: 10, gap: 8, overflow: 'hidden' },
  codeHeader: { minHeight: 24, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 12 },
  codeLanguage: { fontSize: 12, fontWeight: '600' },
  codeCopy: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  codeText: { paddingHorizontal: 12, fontFamily: 'monospace', fontSize: 13, lineHeight: 19 },
  table: { maxWidth: '100%', borderRadius: 12, borderWidth: StyleSheet.hairlineWidth, overflow: 'hidden' },
  tableRow: { flexDirection: 'row', borderBottomWidth: StyleSheet.hairlineWidth },
  tableCell: { minWidth: 90, maxWidth: 240, paddingHorizontal: 9, paddingVertical: 8, borderRightWidth: StyleSheet.hairlineWidth },
  loading: { minHeight: 26, flexDirection: 'row', alignItems: 'center', gap: 8 },
  loadingDot: { width: 7, height: 7, borderRadius: 4 },
  artifactRow: { width: '100%', minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 10, borderRadius: 14, paddingHorizontal: 12 },
  artifactName: { flex: 1, fontSize: 14, fontWeight: '500' },
});
