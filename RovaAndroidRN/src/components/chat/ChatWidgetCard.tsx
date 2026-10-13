import { MaterialCommunityIcons } from '@expo/vector-icons';
import { useEffect, useState, type ComponentProps, type ReactNode } from 'react';
import { Linking, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { ChatArtifact, ChatWidget } from '@/data/chat-api';
import { useWiqoColors } from '@/theme';
import { InlineAppCard } from './InlineAppCard';
import { WiqoAgentMascot } from './WiqoAgentMascot';

type Props = { widget: ChatWidget; artifact?: ChatArtifact; onFollowUp: (text: string) => void; onClarification: (text: string, taskId: string, questionId: string) => void; onAct: (text: string) => void; onAsk: (text: string) => void; onFix: (text: string) => void; activeQuestionId?: string; sending?: boolean };
type IconName = ComponentProps<typeof MaterialCommunityIcons>['name'];

function string(value: unknown, fallback = '') { return typeof value === 'string' ? value : fallback; }
function number(value: unknown, fallback = 0) { return typeof value === 'number' && Number.isFinite(value) ? value : fallback; }
function rows(value: unknown): Record<string, unknown>[] { return Array.isArray(value) ? value.filter(item => item && typeof item === 'object' && !Array.isArray(item)) as Record<string, unknown>[] : []; }
function strings(value: unknown): string[] { return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []; }

function WidgetFrame({ icon, title, subtitle, children, mascot, working = false }: { icon: IconName; title: string; subtitle?: string; children: ReactNode; mascot?: unknown; working?: boolean }) {
  const colors = useWiqoColors();
  return <View style={[styles.frame, { backgroundColor: colors.surface, borderColor: colors.line }]}>
    <View style={styles.frameHeader}>{mascot !== undefined ? <WiqoAgentMascot persona={mascot} size={38} isWorking={working} /> : <View style={[styles.iconBox, { backgroundColor: colors.inset }]}><MaterialCommunityIcons name={icon} size={18} color={colors.muted} /></View>}<View style={styles.frameHeading}><Text numberOfLines={2} style={[styles.frameTitle, { color: colors.ink }]}>{title}</Text>{subtitle ? <Text numberOfLines={1} style={[styles.frameSubtitle, { color: colors.muted }]}>{subtitle}</Text> : null}</View></View>
    {children}
  </View>;
}

function Action({ label, icon = 'arrow-right', onPress }: { label: string; icon?: IconName; onPress: () => void }) {
  const colors = useWiqoColors();
  return <Pressable accessibilityRole="button" onPress={onPress} style={styles.action}><Text style={[styles.actionText, { color: colors.accent }]}>{label}</Text><MaterialCommunityIcons name={icon} size={16} color={colors.accent} /></Pressable>;
}

function Clarification({ widget, onAnswer, active, sending }: { widget: ChatWidget; onAnswer: (answer: string) => void; active: boolean; sending: boolean }) {
  const colors = useWiqoColors();
  const [answer, setAnswer] = useState('');
  const [submitted, setSubmitted] = useState(false);
  const options = strings(widget.options).slice(0, 4);
  const send = (value: string) => { const text = value.trim(); if (!text || submitted) return; setSubmitted(true); onAnswer(text); };
  return (
    <View style={[styles.frame, { backgroundColor: colors.surface, borderColor: colors.line }]}>
      <Text style={[styles.question, { color: colors.ink }]}>
        {string(widget.question, string(widget.summary, 'Bir şeyi netleştirelim'))}
      </Text>
      {submitted ? (
        <Text style={[styles.frameSubtitle, { color: colors.muted }]}>Yanıtlandı</Text>
      ) : active ? (
        <>
          {options.map(option => (
            <Pressable key={option} disabled={sending} onPress={() => send(option)} style={[styles.option, { backgroundColor: colors.inset }]}>
              <Text style={[styles.body, { color: colors.ink }]}>{option}</Text>
            </Pressable>
          ))}
          <View style={styles.answerRow}>
            <TextInput value={answer} onChangeText={setAnswer} placeholder="Yanıtını yaz" placeholderTextColor={colors.muted} multiline maxLength={1200} editable={!sending} style={[styles.answerInput, { color: colors.ink, backgroundColor: colors.inset }]} />
            <Pressable accessibilityRole="button" disabled={!answer.trim() || sending} onPress={() => send(answer)} style={[styles.sendAnswer, { backgroundColor: answer.trim() && !sending ? colors.accent : colors.muted }]}>
              <MaterialCommunityIcons name="arrow-up" size={18} color={colors.onAccent} />
            </Pressable>
          </View>
        </>
      ) : (
        <Text style={[styles.frameSubtitle, { color: colors.muted }]}>Bu soru artık beklenmiyor</Text>
      )}
    </View>
  );
}

function CardBody({ widget, onFollowUp }: { widget: ChatWidget; onFollowUp: (text: string) => void }) {
  const colors = useWiqoColors();
  const kind = string(widget.kind);
  const [checked, setChecked] = useState<number[]>([]);
  const [remaining, setRemaining] = useState<number | null>(null);
  useEffect(() => { if (remaining === null || remaining <= 0) return; const timer = setTimeout(() => setRemaining(value => value === null ? null : Math.max(0, value - 1)), 1000); return () => clearTimeout(timer); }, [remaining]);
  if (kind === 'timer') return <WidgetFrame icon="timer-outline" title={string(widget.title, 'Zamanlayıcı')} subtitle={`${Math.ceil(number(widget.seconds, 60) / 60)} dk`}><View style={styles.timerRow}><Text style={[styles.timerValue, { color: colors.ink }]}>{remaining === null ? `${Math.ceil(number(widget.seconds, 60))} sn` : `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')}`}</Text><Action label={remaining ? 'İptal' : remaining === 0 ? 'Sıfırla' : 'Başlat'} onPress={() => setRemaining(remaining === null || remaining === 0 ? Math.max(1, Math.ceil(number(widget.seconds, 60))) : 0)} /></View></WidgetFrame>;
  if (kind === 'checklist' || kind === 'recipe') {
    const ingredients = strings(widget.ingredients);
    const checklist = strings(widget.checklist);
    const directions = rows(widget.directions);
    const items = kind === 'recipe' ? ingredients : checklist;
    return <WidgetFrame icon={kind === 'recipe' ? 'silverware-fork-knife' : 'format-list-checks'} title={string(widget.title, kind === 'recipe' ? 'Tarif' : 'Kontrol listesi')} subtitle={kind === 'recipe' ? [widget.servings ? `${widget.servings} kişilik` : '', widget.minutes ? `${widget.minutes} dk` : ''].filter(Boolean).join(' · ') : undefined}>
      {items.map((item, index) => <Pressable key={`${index}-${item}`} onPress={() => setChecked(current => current.includes(index) ? current.filter(value => value !== index) : [...current, index])} style={styles.checkRow}><MaterialCommunityIcons name={checked.includes(index) ? 'checkbox-marked-outline' : 'checkbox-blank-outline'} size={19} color={checked.includes(index) ? colors.accent : colors.muted} /><Text style={[styles.body, { color: checked.includes(index) ? colors.muted : colors.ink, textDecorationLine: checked.includes(index) ? 'line-through' : 'none' }]}>{item}</Text></Pressable>)}
      {directions.map((step, index) => <View key={index} style={styles.detailRow}><Text style={[styles.stepNumber, { color: colors.muted, backgroundColor: colors.inset }]}>{index + 1}</Text><Text style={[styles.body, { color: colors.ink }]}>{string(step.text)}</Text></View>)}
    </WidgetFrame>;
  }
  const values = kind === 'quotes' ? rows(widget.quotes) : kind === 'score' ? rows(widget.matches) : kind === 'trip' ? rows(widget.tripDays) : [];
  if (values.length) return <WidgetFrame icon={kind === 'quotes' ? 'chart-line' : kind === 'score' ? 'scoreboard-outline' : 'map-outline'} title={string(widget.title, kind === 'score' ? 'Maçlar' : kind === 'quotes' ? 'Piyasalar' : 'Seyahat planı')} subtitle={string(widget.subtitle)}>
    {values.map((item, index) => <View key={index} style={styles.dataRow}><View style={{ flex: 1 }}><Text style={[styles.bodyStrong, { color: colors.ink }]}>{string(item.name, string(item.home, string(item.title, `Gün ${index + 1}`)))}</Text><Text style={[styles.frameSubtitle, { color: colors.muted }]}>{string(item.symbol, string(item.status, string(item.description, string(item.when))))}</Text></View><Text style={[styles.bodyStrong, { color: colors.ink }]}>{String(item.price ?? [item.homeScore, item.awayScore].filter(value => value !== undefined).join(' – ') ?? item.location ?? '')}</Text></View>)}
  </WidgetFrame>;
  if (kind === 'translation') return <WidgetFrame icon="translate" title={[widget.sourceLang, widget.targetLang].filter(value => typeof value === 'string').join(' → ') || 'Çeviri'}><Text style={[styles.frameSubtitle, { color: colors.muted }]}>{string(widget.original)}</Text><Text selectable style={[styles.translation, { color: colors.ink }]}>{string(widget.translated)}</Text><Action label="Çeviriyi sor" icon="message-text-outline" onPress={() => onFollowUp(`Bu çeviriyi açıkla: ${string(widget.translated)}`)} /></WidgetFrame>;
  if (kind === 'calc') return <WidgetFrame icon="calculator-variant-outline" title={string(widget.title, 'Hesaplama')}><Text style={[styles.frameSubtitle, { color: colors.muted }]}>{string(widget.expression)}</Text><Text selectable style={[styles.calculation, { color: colors.ink }]}>{string(widget.result)}</Text></WidgetFrame>;
  if (kind === 'quotes' || kind === 'score' || kind === 'trip') return null;
  const lines = [widget.subtitle, widget.service, ...strings(widget.checklist)].filter((item): item is string => typeof item === 'string' && !!item);
  return <WidgetFrame icon={kind === 'media' ? 'play-circle-outline' : kind === 'contact' ? 'account-outline' : 'information-outline'} title={string(widget.title, 'Wiqo')} subtitle={string(widget.subtitle)}>{lines.filter(line => line !== widget.subtitle).map((line, index) => <Text key={index} style={[styles.body, { color: colors.ink }]}>{line}</Text>)}</WidgetFrame>;
}

export function ChatWidgetCard({ widget, artifact, onFollowUp, onClarification, onAct, onAsk, onFix, activeQuestionId, sending = false }: Props) {
  const colors = useWiqoColors();
  const type = string(widget.type, 'unknown');
  const title = string(widget.title, string(widget.summary, type.replaceAll('_', ' ')));
  if (type === 'approval' || type === 'unknown') return null;
  if (type === 'inline_app') return <InlineAppCard widget={widget} onAsk={onAsk} onFix={onFix} />;
  if (type === 'clarification') return <Clarification widget={widget} active={widget.questionId === activeQuestionId && typeof widget.taskId === 'string'} sending={sending} onAnswer={answer => { if (typeof widget.taskId === 'string' && typeof widget.questionId === 'string') onClarification(answer, widget.taskId, widget.questionId); }} />;
  if (type === 'card') return <CardBody widget={widget} onFollowUp={onFollowUp} />;
  if (type === 'weather') {
    const current = widget.current && typeof widget.current === 'object' ? widget.current as Record<string, unknown> : {};
    const days = rows(widget.days);
    return <WidgetFrame icon="weather-partly-cloudy" title={title} subtitle={string(widget.location)}><View style={styles.weatherRow}><Text style={[styles.weatherTemp, { color: colors.ink }]}>{number(current.temperatureC)}°</Text><View><Text style={[styles.bodyStrong, { color: colors.ink }]}>{string(current.condition)}</Text><Text style={[styles.frameSubtitle, { color: colors.muted }]}>Hissedilen {number(current.feelsLikeC)}° · Nem %{number(current.humidityPercent)}</Text></View></View>{days.map((day, index) => <View key={index} style={styles.dataRow}><Text style={[styles.body, { color: colors.ink }]}>{string(day.date)}</Text><Text style={[styles.frameSubtitle, { color: colors.muted }]}>{string(day.condition)}</Text><Text style={[styles.bodyStrong, { color: colors.ink }]}>{number(day.minC)}° / {number(day.maxC)}°</Text></View>)}</WidgetFrame>;
  }
  if (type === 'sources') {
    const sources = rows(widget.sources);
    return <WidgetFrame icon="web" title={title} subtitle={`${sources.length} kaynak`}>{sources.map((source, index) => <Pressable key={index} accessibilityRole="link" onPress={() => typeof source.url === 'string' && void Linking.openURL(source.url)} style={styles.sourceRow}><View style={{ flex: 1 }}><Text numberOfLines={2} style={[styles.bodyStrong, { color: colors.ink }]}>{string(source.title, string(source.url))}</Text>{typeof source.published === 'string' ? <Text style={[styles.frameSubtitle, { color: colors.muted }]}>{source.published}</Text> : null}</View><MaterialCommunityIcons name="open-in-new" size={16} color={colors.muted} /></Pressable>)}</WidgetFrame>;
  }
  if (type === 'artifact') return <WidgetFrame icon="file-download-outline" title={title} subtitle={artifact?.filename}><Action label={artifact?.filename ?? 'Dosyayı aç'} icon="open-in-new" onPress={() => artifact && void Linking.openURL(artifact.downloadURL)} />{widget.variant === 'table' && widget.tablePreview ? <TablePreview table={widget.tablePreview as Record<string, unknown>} /> : null}</WidgetFrame>;
  if (type === 'table') return <WidgetFrame icon="table-large" title={title} subtitle={typeof widget.totalRows === 'number' ? `${widget.totalRows} satır` : undefined}><TablePreview table={widget} /></WidgetFrame>;
  if (type === 'list') {
    const items = rows(widget.items);
    return <WidgetFrame icon="format-list-bulleted" title={title} subtitle={`${number(widget.total, items.length)} kayıt`}>{items.slice(0, 4).map((item, index) => <Pressable key={index} onPress={() => onFollowUp(`${string(item.title)} hakkında daha fazla bilgi ver.`)} style={styles.listItem}><Text numberOfLines={2} style={[styles.bodyStrong, { color: colors.ink }]}>{string(item.title)}</Text>{typeof item.subtitle === 'string' ? <Text numberOfLines={1} style={[styles.frameSubtitle, { color: colors.muted }]}>{item.subtitle}</Text> : null}{typeof item.detail === 'string' ? <Text numberOfLines={2} style={[styles.body, { color: colors.ink }]}>{item.detail}</Text> : null}</Pressable>)}{items.length > 4 ? <Action label={`${items.length - 4} kaydı daha sor`} onPress={() => onFollowUp(`Tüm ${string(widget.domain, 'sonuç')} kayıtlarını göster.`)} /> : null}</WidgetFrame>;
  }
  if (type === 'task_plan') {
    const steps = rows(widget.planSteps);
    return <WidgetFrame icon="format-list-checks" title={title} mascot={widget.persona ?? 'general'} working={widget.taskStatus === 'running'} subtitle={`${number(widget.completedSteps)}/${number(widget.totalSteps, steps.length)} adım`}>
      {steps.map((step, index) => <View key={String(step.id ?? index)} style={styles.planRow}><MaterialCommunityIcons name={step.status === 'completed' ? 'check-circle-outline' : step.status === 'failed' ? 'close-circle-outline' : 'circle-outline'} size={18} color={step.status === 'failed' ? colors.danger : colors.muted} /><View style={{ flex: 1 }}><Text style={[styles.bodyStrong, { color: colors.ink }]}>{string(step.title)}</Text>{typeof step.message === 'string' ? <Text style={[styles.frameSubtitle, { color: colors.muted }]}>{step.message}</Text> : null}</View></View>)}
    </WidgetFrame>;
  }
  if (type === 'task_result') {
    const failed = widget.taskStatus === 'failed';
    return <WidgetFrame icon={failed ? 'alert-circle-outline' : 'check-circle-outline'} title={title} mascot={widget.persona ?? 'general'} subtitle={`${number(widget.completedSteps)}/${number(widget.totalSteps)} adım · ${string(widget.taskStatus, 'completed')}`}><Text style={[styles.body, { color: colors.ink }]}>{string(widget.summary)}</Text></WidgetFrame>;
  }
  if (type === 'code_change') return <WidgetFrame icon="source-branch" title={title} subtitle={`Sürüm ${number(widget.projectVersion)}`}><Text style={[styles.body, { color: colors.ink }]}>{widget.verified === true ? 'Değişiklik doğrulandı.' : 'Değişiklik hazır.'}</Text></WidgetFrame>;
  if (type === 'error') return <View style={[styles.errorCard, { backgroundColor: 'rgba(214,64,69,0.06)', borderColor: 'rgba(214,64,69,0.18)' }]}><View style={styles.errorHeading}><MaterialCommunityIcons name="alert-circle-outline" size={18} color={colors.danger} /><Text style={[styles.bodyStrong, { color: colors.danger }]}>{title}</Text></View><Text style={[styles.body, { color: colors.muted }]}>{string(widget.message, string(widget.detail))}</Text>{typeof widget.code === 'string' && widget.code.startsWith('CONNECTION_') ? <Action label="Bağlantıyı kontrol et" onPress={() => onFollowUp('Bağlantılarımı kontrol etmeme yardım et.')} /> : null}</View>;
  if (type === 'map') return <WidgetFrame icon="map-outline" title={title} subtitle={string(widget.mode)}><Text style={[styles.body, { color: colors.ink }]}>{[widget.origin, widget.destination, widget.query, widget.near].filter(value => typeof value === 'string').join(' · ')}</Text><Action label="Haritada aç" icon="open-in-new" onPress={() => { const query = encodeURIComponent(string(widget.destination, string(widget.query, string(widget.location)))); void Linking.openURL(`geo:0,0?q=${query}`); }} /></WidgetFrame>;
  if (type === 'created_resource') return <WidgetFrame icon={widget.resourceType === 'automation' ? 'clock-outline' : 'account-cog-outline'} title={title} subtitle={string(widget.resourceType)}><Text style={[styles.body, { color: colors.ink }]}>{string(widget.detail)}</Text><Action label="Ayrıntılarını aç" onPress={() => onFollowUp(`${title} ayrıntılarını göster.`)} /></WidgetFrame>;
  if (type === 'act_handoff') return <WidgetFrame icon="flash-outline" title={title} subtitle={string(widget.projectName)}><Text style={[styles.body, { color: colors.ink }]}>{string(widget.request)}</Text><Action label="Act'te aç" icon="arrow-right" onPress={() => onAct(string(widget.request, title))} /></WidgetFrame>;
  return null;
}

function TablePreview({ table }: { table: Record<string, unknown> }) {
  const colors = useWiqoColors();
  const headers = strings(table.columns);
  const values = Array.isArray(table.rows) ? table.rows as unknown[][] : [];
  return <ScrollView horizontal showsHorizontalScrollIndicator><View style={styles.table}>{[headers, ...values].map((row, rowIndex) => <View key={rowIndex} style={[styles.tableRow, { borderBottomColor: colors.line, backgroundColor: rowIndex === 0 ? colors.inset : 'transparent' }]}>{row.map((cell, index) => <Text key={index} numberOfLines={4} style={[styles.tableCell, { color: colors.ink }]}>{String(cell ?? '')}</Text>)}</View>)}</View></ScrollView>;
}

const styles = StyleSheet.create({
  frame: { width: '100%', alignSelf: 'stretch', gap: 10, padding: 13, borderRadius: 17, borderWidth: StyleSheet.hairlineWidth },
  frameHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 38 },
  iconBox: { width: 34, height: 34, borderRadius: 11, alignItems: 'center', justifyContent: 'center' },
  frameHeading: { flex: 1, minWidth: 0, gap: 2 },
  frameTitle: { fontSize: 14, fontWeight: '600', lineHeight: 19 },
  frameSubtitle: { fontSize: 12, lineHeight: 17 },
  body: { fontSize: 13, lineHeight: 19, flexShrink: 1 },
  bodyStrong: { fontSize: 13, lineHeight: 18, fontWeight: '600', flexShrink: 1 },
  action: { minHeight: 32, flexDirection: 'row', alignItems: 'center', justifyContent: 'flex-end', gap: 5, alignSelf: 'flex-end', paddingHorizontal: 2 },
  actionText: { fontSize: 12, fontWeight: '600' },
  question: { fontSize: 14, lineHeight: 20, fontWeight: '600' },
  option: { minHeight: 40, justifyContent: 'center', borderRadius: 12, paddingHorizontal: 12, paddingVertical: 8 },
  answerRow: { flexDirection: 'row', alignItems: 'flex-end', gap: 8 },
  answerInput: { flex: 1, maxHeight: 110, minHeight: 40, borderRadius: 13, paddingHorizontal: 12, paddingVertical: 9, fontSize: 14 },
  sendAnswer: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
  weatherRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  weatherTemp: { fontSize: 38, lineHeight: 44, fontWeight: '300' },
  dataRow: { minHeight: 40, flexDirection: 'row', alignItems: 'center', gap: 8, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: 'rgba(120,120,128,0.14)', paddingVertical: 7 },
  sourceRow: { minHeight: 42, flexDirection: 'row', alignItems: 'center', gap: 10 },
  listItem: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: 'rgba(120,120,128,0.14)', paddingVertical: 9, gap: 3 },
  planRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 9, paddingVertical: 4 },
  errorCard: { width: '100%', gap: 7, padding: 12, borderWidth: StyleSheet.hairlineWidth, borderRadius: 14 },
  errorHeading: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  table: { minWidth: '100%', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(120,120,128,0.2)', borderRadius: 10, overflow: 'hidden' },
  tableRow: { flexDirection: 'row', borderBottomWidth: StyleSheet.hairlineWidth },
  tableCell: { minWidth: 85, maxWidth: 220, paddingHorizontal: 9, paddingVertical: 8, fontSize: 12, lineHeight: 17 },
  checkRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 8, paddingVertical: 3 },
  detailRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 9, paddingTop: 5 },
  stepNumber: { width: 22, height: 22, borderRadius: 11, textAlign: 'center', textAlignVertical: 'center', fontSize: 12, fontWeight: '600', overflow: 'hidden' },
  timerRow: { minHeight: 38, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  timerValue: { fontSize: 25, fontWeight: '600', fontVariant: ['tabular-nums'] },
  translation: { fontSize: 18, lineHeight: 25, fontWeight: '600' },
  calculation: { fontSize: 28, lineHeight: 36, fontWeight: '700' },
});
