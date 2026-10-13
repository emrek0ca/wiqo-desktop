import { useCallback, useEffect, useRef } from 'react';
import { StyleSheet, View } from 'react-native';
import { WebView } from 'react-native-webview';

type Props = { level?: number; working?: boolean; flash?: number; accent?: string; compact?: boolean };
type OrbState = { level: number; working: boolean; flash: number; accent: [number, number, number] };

function rgb(color: string): [number, number, number] {
  const hex = color.replace('#', '');
  if (!/^[0-9a-fA-F]{6}$/.test(hex)) return [0.36, 0.48, 0.4];
  return [0, 2, 4].map((offset) => parseInt(hex.slice(offset, offset + 2), 16) / 255) as [number, number, number];
}

// The orb is rendered as a ray-marched, lit 3D volume on the Android WebGL/GPU
// surface. This is a direct GLES shader port of the iOS Metal orb, not a layered
// image or gradient illustration.
const ORB_HTML = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><style>*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden;background:transparent}canvas{display:block;width:100%;height:100%}</style></head><body><canvas id="orb"></canvas><script>
(()=>{
const canvas=document.getElementById('orb'),gl=canvas.getContext('webgl',{alpha:true,antialias:true,premultipliedAlpha:true,preserveDrawingBuffer:false,powerPreference:'high-performance'});
if(!gl){document.body.dataset.error='webgl-unavailable';return;}
const vertex='attribute vec2 position; varying vec2 uv; void main(){uv=position*.5+.5;gl_Position=vec4(position,0.,1.);}';
const fragment='precision highp float;\\n'+
'varying vec2 uv; uniform vec2 size; uniform vec3 accent; uniform float time; uniform float level; uniform float darkMode; uniform float pulse; uniform float squash; uniform float drift; uniform float work; uniform float flash;\\n'+
'float field(vec3 p,float t,float lv,float pl,float sq){vec3 q=p;q.y*=1.-.15*sq;q.xz*=1.+.08*sq;float speed=.6+.7*lv;float amp=.020+.062*lv;float n=sin(q.x*3.1+t*1.30*speed+sin(q.y*2.+t*.8*speed))*sin(q.y*2.7-t*1.10*speed)*sin(q.z*3.3+t*.90*speed)+.30*sin(q.x*4.-t*1.70*speed+q.y*2.1)*sin(q.z*3.2+t*1.20*speed);float r=length(q.xz);float ring=sin(r*5.-t*4.2)*exp(-r*.85)*smoothstep(-.3,1.,q.y)*pl*.07;return length(q)-(1.+.10*lv)-amp*n-ring;}\\n'+
'vec3 normalAt(vec3 p,float t,float lv,float pl,float sq){float e=.004;vec2 k=vec2(1.,-1.);return normalize(k.xyy*field(p+k.xyy*e,t,lv,pl,sq)+k.yyx*field(p+k.yyx*e,t,lv,pl,sq)+k.yxy*field(p+k.yxy*e,t,lv,pl,sq)+k.xxx*field(p+k.xxx*e,t,lv,pl,sq));}\\n'+
'void main(){float aspect=size.x/max(size.y,1.);vec2 p2=(uv*2.-1.)*vec2(aspect,1.)*2.05;p2.y=-p2.y;p2.y+=.05;p2.x-=drift*.22;p2.y-=squash*.20;float lv=max(clamp(level,0.,1.),.28*work);vec3 ro=vec3(p2,3.),rd=vec3(0.,0.,-1.);float t=0.,dmin=1e9;bool hit=false;vec3 pos=ro;for(int i=0;i<72;i++){pos=ro+rd*t;float d=field(pos,time,lv,pulse,squash);dmin=min(dmin,d);if(d<.0015){hit=true;break;}t+=d*.6;if(t>6.)break;}vec3 color=vec3(0.);float orbAlpha=0.;if(hit){vec3 n=normalAt(pos,time,lv,pulse,squash),v=vec3(0.,0.,1.),key=normalize(vec3(-.55,.70,.55));float ndv=clamp(dot(n,v),0.,1.),diffuse=clamp(dot(n,key),0.,1.),wrap=diffuse*.78+.22;float speed=.7+.9*lv;float swirl=.5+.35*sin(pos.x*3.6+time*1.3*speed+sin(pos.y*2.8-time*.9*speed)*1.6)*cos(pos.z*3.1-time*speed+pos.y*2.2);vec3 shade=accent*.20;vec3 lit=mix(accent*.92,accent*1.18+.05,swirl*(.30+.60*lv))+.03;color=mix(shade,lit,wrap);float streak=pow(clamp(swirl,0.,1.),6.)*.30*lv;color+=mix(accent,vec3(1.),.5)*streak;float rim=pow(1.-ndv,2.2);color+=accent*rim*(.12+.16*lv);float fresnel=pow(1.-ndv,4.);color+=vec3(1.)*fresnel*(.12+.08*darkMode);vec3 r=reflect(-v,n);vec2 q=(r.xy-vec2(-.42,.52))/vec2(.34,.20);float box=exp(-dot(q,q)*.55);color+=vec3(1.)*box*.38;vec3 h=normalize(key+v);float spec=pow(clamp(dot(n,h),0.,1.),48.);color+=vec3(1.)*spec*.55;float bounce=smoothstep(.1,1.,-n.y)*.22;color+=mix(accent,vec3(1.),.35)*bounce;color+=mix(accent,vec3(1.),.6)*flash*(.18+.30*pow(1.-ndv,2.));color=clamp(color,0.,1.);orbAlpha=1.;}else{float px=2.05*2./max(size.y,1.);orbAlpha=1.-smoothstep(0.,px*1.4,dmin);color=accent*.5;}float glow=exp(-max(dmin,0.)*3.)*(.20+.38*lv)*(1.-darkMode*.15);glow=hit?0.:glow;vec2 sp=vec2(p2.x/(1.05-.12*lv),(p2.y+1.62)/.22);float shadow=exp(-dot(sp,sp)*1.5)*(.26-.06*lv)*(1.-darkMode*.35);vec2 edge=min(uv,1.-uv);float window=smoothstep(0.,.34,edge.x)*smoothstep(0.,.42,edge.y);window*=window;glow*=window;shadow*=window;float a=orbAlpha,glowA=glow*(1.-a),shadowA=shadow*(1.-a)*(1.-glowA);vec3 rgb=color*a+accent*glowA;float alpha=a+glowA+shadowA;gl_FragColor=vec4(rgb,alpha);}\\n';
function shader(type,source){const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s)||'shader compile failed');return s;}
let program;try{program=gl.createProgram();gl.attachShader(program,shader(gl.VERTEX_SHADER,vertex));gl.attachShader(program,shader(gl.FRAGMENT_SHADER,fragment));gl.linkProgram(program);if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(program)||'shader link failed');}catch(e){document.body.dataset.error='shader-error';return;}
gl.useProgram(program);const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]),gl.STATIC_DRAW);const pos=gl.getAttribLocation(program,'position');gl.enableVertexAttribArray(pos);gl.vertexAttribPointer(pos,2,gl.FLOAT,false,0,0);gl.enable(gl.BLEND);gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
const names=['size','accent','time','level','darkMode','pulse','squash','drift','work','flash'],u={};names.forEach(n=>u[n]=gl.getUniformLocation(program,n));let state={level:0,working:false,flash:0,accent:[.36,.48,.4]},shown=0,lastTarget=0,pulse=0,squash=0,squashV=0,work=0,last=performance.now(),start=last,lastDraw=0;
document.addEventListener('message',event=>{try{state=Object.assign(state,JSON.parse(event.data));}catch(_){}});window.addEventListener('message',event=>{try{state=Object.assign(state,JSON.parse(event.data));}catch(_){}});
function resize(){const dpr=Math.min(window.devicePixelRatio||1,1.5),w=Math.max(1,Math.round(canvas.clientWidth*dpr)),h=Math.max(1,Math.round(canvas.clientHeight*dpr));if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h;gl.viewport(0,0,w,h);}}
function frame(now){requestAnimationFrame(frame);if(now-lastDraw<30)return;lastDraw=now;resize();const dt=Math.min(Math.max((now-last)/1000,1/240),1/30);last=now;const heard=Math.min(1,Math.pow(Math.max(state.level||0,0),.55)*1.25),follow=heard>shown?.28:.07;shown+=(heard-shown)*follow;const onset=Math.max(0,heard-lastTarget);lastTarget=heard;pulse=Math.min(pulse*Math.exp(-dt*2)+onset*3,1.2);const drive=3*onset+.8*(shown-.2);squashV+=(-30*squash-7.5*squashV+drive*40)*dt;squash=Math.max(-1,Math.min(1,squash+squashV*dt));const tm=(now-start)/1000;work+=((state.working?1:0)-work)*Math.min(dt*3,1);state.flash=Math.max(0,(state.flash||0)-dt*2.2);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT);gl.uniform2f(u.size,canvas.width,canvas.height);gl.uniform3fv(u.accent,new Float32Array(state.accent||[.36,.48,.4]));gl.uniform1f(u.time,tm);gl.uniform1f(u.level,shown);gl.uniform1f(u.darkMode,0.);gl.uniform1f(u.pulse,pulse);gl.uniform1f(u.squash,squash);gl.uniform1f(u.drift,Math.sin(tm*1.1)*shown);gl.uniform1f(u.work,work);gl.uniform1f(u.flash,state.flash||0);gl.drawArrays(gl.TRIANGLES,0,6);}
requestAnimationFrame(frame);window.ReactNativeWebView&&window.ReactNativeWebView.postMessage('ready');
})();</script></body></html>`;

export function WiqoListeningOrb({ level = 0, working = false, flash = 0, accent = '#5C7A67', compact = false }: Props) {
  const webRef = useRef<WebView>(null);
  const ready = useRef(false);
  const state = useRef<OrbState>({ level, working, flash, accent: rgb(accent) });
  state.current = { level: Math.max(0, Math.min(1, level)), working, flash: flash ? 1 : 0, accent: rgb(accent) };

  const sendState = useCallback(() => {
    if (ready.current) webRef.current?.postMessage(JSON.stringify(state.current));
  }, []);
  useEffect(() => { sendState(); }, [level, working, flash, accent, sendState]);
  const onMessage = useCallback((event: { nativeEvent: { data: string } }) => {
    if (event.nativeEvent.data === 'ready') {
      ready.current = true;
      sendState();
    }
  }, [sendState]);
  const width = compact ? 176 : 240;
  const height = compact ? 176 : 210;

  return <View accessible accessibilityLabel={working ? 'Wiqo yanıt hazırlıyor' : 'Wiqo dinliyor'} style={[styles.stage, { width, height }]}>
    <WebView
      ref={webRef}
      source={{ html: ORB_HTML, baseUrl: 'https://wiqo.android.com' }}
      originWhitelist={['https://wiqo.android.com']}
      javaScriptEnabled
      domStorageEnabled={false}
      scrollEnabled={false}
      bounces={false}
      overScrollMode="never"
      androidLayerType="hardware"
      setSupportMultipleWindows={false}
      onMessage={onMessage}
      onLoadEnd={sendState}
      style={styles.webview}
      containerStyle={styles.webviewContainer}
    />
  </View>;
}

const styles = StyleSheet.create({
  stage: { alignItems: 'center', justifyContent: 'center', overflow: 'visible' },
  webviewContainer: { backgroundColor: 'transparent' },
  webview: { flex: 1, backgroundColor: 'transparent' },
});
