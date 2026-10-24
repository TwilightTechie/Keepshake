import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as k from './vendor/anatomy/iso-kit.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const W = 900, H = 560;
const strapLeft = { x: -154, y: -15, w: 128, d: 30, r: 6 };
const strapRight = { x: 26, y: -15, w: 128, d: 30, r: 6 };
const casePlan = { x: -28, y: -22, w: 56, d: 44, r: 8 };
const projection = (top) => k.fitProjection([...k.boxCorners({ x:-158,y:-26,w:316,d:52 },0,top)], W,H,{pad:48,azimuth:47,elevation:34});
let P = projection(30);
const S=(paths,cls,tone='mid')=>k.solidSvg(paths,{className:cls,tone,crease:'none'});
const L=(path,tone='lo',cls='')=>k.lineSvg(path,{tone,className:cls});
const D=(points,size=.55,tone='mid')=>k.dotsSvg(points,{size,tone});
const at=(x,y,z)=>k.iso([x,y,z],P);

// One band, two honest views: the second lifts the planned P0 layers for inspection.
function strap(){
  const out=[];
  out.push(`<path class="iso-halo" d="${k.haloOf({x:-155,y:-15,w:310,d:30,r:5},-4,3,P)}"/>`);
  for(const plan of [strapLeft,strapRight]){
    out.push(S(k.slabOf(plan,0,3,P,8,.5),'strap','hi'));
    out.push(L(k.planOutline(k.insetPlan(plan,2),3,P),'mid','strap-outline'));
    let rib = 0;
    for(let x=plan.x+7;x<plan.x+plan.w-6;x+=4.2){
      // Raised threads make the woven strap read as fabric at close range.
      out.push(S(k.slabOf({x,y:plan.y+3,w:.9,d:24,r:.3},3,.45,P,3),rib++ % 7 === 0 ? 'weave accent-weave' : 'weave','faint'));
    }
    const stitch=[];
    for(let x=plan.x+9;x<plan.x+plan.w-8;x+=5.5){stitch.push(at(x,plan.y+3,3.5),at(x,plan.y+plan.d-3,3.5));}
    out.push(D(stitch,.45,'lo'));
  }
  // Strap keepers and the adjustable tail, rooted in the same band.
  out.push(S(k.slabOf({x:-143,y:-16,w:5,d:32,r:1},3,2.2,P,4),'keeper','mid'));
  out.push(S(k.slabOf({x:-132,y:-16,w:3,d:32,r:1},3,1.5,P,4),'keeper','mid'));
  out.push(S(k.slabOf({x:137,y:-16,w:5,d:32,r:1},3,2.2,P,4),'keeper','mid'));
  out.push(S(k.slabOf({x:-31,y:-16,w:5,d:32,r:1},3,1.5,P,4),'lug','lo'));
  out.push(S(k.slabOf({x:26,y:-16,w:5,d:32,r:1},3,1.5,P,4),'lug','lo'));
  return out.join('');
}
function shellBase(){
  const out=[];
  out.push(S(k.slabOf({x:-29,y:-23,w:58,d:46,r:9},3,4,P,10,1),'case-base','hi'));
  out.push(L(k.sideSeam({x:-29,y:-23,w:58,d:46,r:9},6.2,P,10),'lo'));
  for(const [x,y] of [[-22,-16],[22,-16],[-22,16],[22,16]]){
    out.push(S(k.cylinder(x,y,2,7,1.1,P,20,.2),'mount','lo'));
    out.push(D([at(x,y,8.1)],.55,'hi'));
  }
  return out.join('');
}
function outside(){
  const out=[strap(),shellBase()];
  out.push(S(k.slabOf(casePlan,7,13,P,12,1.4),'case-body','hi'));
  out.push(L(k.sideSeam(casePlan,16.8,P,12),'faint'));
  // USB-C housing is integrated in the forward-facing side wall.
  out.push(S(k.slabOf({x:-10,y:21,w:20,d:3.5,r:1.8},9.2,4.8,P,6,.5),'port-rim','mid'));
  out.push(S(k.slabOf({x:-6.5,y:23.7,w:13,d:1.2,r:.6},10.6,1.6,P,4),'port-hole','lo'));
  out.push(S(k.slabOf({x:22,y:1,w:7.5,d:13,r:1.5},11,4.8,P,5,.5),'switch-track','lo'));
  out.push(S(k.slabOf({x:27,y:5,w:3,d:5,r:.8},12.8,2.8,P,4,.3),'switch-thumb','hi'));
  // Rounded top shell, a quiet microphone port and recording indicator.
  out.push(S(k.slabOf(k.insetPlan(casePlan,.9),20,2.5,P,12,1.1),'lid','hi'));
  out.push(L(k.planOutline(k.insetPlan(casePlan,3.1),22.5,P,12),'faint'));
  out.push(S(k.cylinder(-12,-7,2.8,22.5,.6,P,24),'mic-rim','mid'));
  out.push(S(k.cylinder(-12,-7,1.15,23.1,.2,P,20),'mic-hole','lo'));
  out.push(S(k.cylinder(13,-7,1.7,22.5,.45,P,20),'led-ring','lo'));
  out.push(D([at(13,-7,22.95)],.85,'green'));
  out.push(k.faceTextSvg(k.topMatrix([0,8],22.5,P,'x'),'k.',{size:4,tone:'lo',anchor:'middle'}));
  const screws=[[-21,-15],[21,-15],[-21,15],[21,15]];
  out.push(D(screws.map(([x,y])=>at(x,y,22.7)),.45,'lo'));
  return out.join('');
}
function inside(){
  const out=[strap(),shellBase()];
  // Planned prototype electronics, separated to make the stack legible.
  out.push(S(k.slabOf({x:-24,y:-18,w:48,d:36,r:4},9,3,P,7,.6),'tray','hi'));
  out.push(S(k.slabOf({x:-18,y:-15,w:36,d:30,r:2},22,4,P,5,.3),'battery','hi'));
  out.push(L(k.planOutline({x:-14,y:-11,w:28,d:22,r:1.2},26,P,5),'mid'));
  out.push(S(k.slabOf({x:-20,y:-13,w:40,d:26,r:2},39,2.5,P,5,.4),'pcb','hi'));
  for(const [x,y] of [[-16,-9],[16,-9],[-16,9],[16,9]])out.push(D([at(x,y,41.6)],.65,'lo'));
  out.push(S(k.slabOf({x:-13,y:-9,w:18,d:15,r:1.5},41.5,3,P,5,.3),'chip','hi'));
  out.push(S(k.slabOf({x:9,y:-8,w:7,d:6,r:.8},41.5,2.5,P,4,.2),'component','mid'));
  out.push(S(k.slabOf({x:9,y:2,w:7,d:6,r:.8},41.5,2.5,P,4,.2),'component','mid'));
  out.push(S(k.slabOf({x:-18,y:9,w:9,d:3,r:.5},41.5,2,P,4,.2),'component','mid'));
  out.push(S(k.slabOf({x:-8,y:9,w:9,d:3,r:.5},41.5,2,P,4,.2),'component','mid'));
  out.push(S(k.slabOf({x:-27,y:-21,w:54,d:42,r:7},61,5,P,10,.9),'case-body','hi'));
  out.push(S(k.slabOf({x:-27,y:-21,w:54,d:42,r:7},66,2.5,P,10,1),'lid','hi'));
  out.push(S(k.cylinder(-12,-7,1.2,68.5,.2,P,18),'mic-hole','lo'));
  out.push(D([at(13,-7,68.7)],.8,'green'));
  return out.join('');
}

const extraCSS=`
.iso{--anatomy-paper:#f5f7f2;--anatomy-face:#f5f7f2;--anatomy-halo:#a8baaa;--anatomy-halo-opacity:.24;--anatomy-hi:#262e2b;--anatomy-mid:#63746a;--anatomy-lo:#9dab9e;--anatomy-faint:#c0cac0;--anatomy-dot:#e2eadc;--anatomy-green:#9ec9a1;--anatomy-weight:.7px}
.strap .iso-top,.weave .iso-top{fill:#303934}.strap .iso-shade,.weave .iso-shade{fill:#202925}.strap .iso-edge,.weave .iso-edge{stroke:#47534b}.weave{opacity:.65}.weave .iso-top{fill:#455147}
.keeper .iso-top,.lug .iso-top{fill:#404b42}.keeper .iso-shade,.lug .iso-shade{fill:#232c26}
.case-base .iso-top,.case-body .iso-top,.tray .iso-top{fill:#313a36}.case-base .iso-shade,.case-body .iso-shade,.tray .iso-shade{fill:#202824}.case-base .iso-edge,.case-body .iso-edge{stroke:#151d18}
.lid .iso-top{fill:#3d4541}.lid .iso-shade{fill:#282f2c}.lid .iso-edge{stroke:#171e1a}
.port-rim .iso-top,.switch-track .iso-top{fill:#7c857e}.port-rim .iso-shade,.switch-track .iso-shade{fill:#3e4841}.port-hole .iso-top,.mic-hole .iso-top{fill:#111a15}.port-hole .iso-shade,.mic-hole .iso-shade{fill:#101713}.switch-thumb .iso-top{fill:#b2bdb1}.switch-thumb .iso-shade{fill:#707c70}
.mic-rim .iso-top,.led-ring .iso-top,.mount .iso-top{fill:#69756c}.mic-rim .iso-shade,.led-ring .iso-shade,.mount .iso-shade{fill:#39473b}
.battery .iso-top{fill:#d4d0bc}.battery .iso-shade{fill:#aea992}.battery .iso-edge{stroke:#7a7e6f}.pcb .iso-top{fill:#60856c}.pcb .iso-shade{fill:#335c40}.pcb .iso-edge{stroke:#284a32}.chip .iso-top{fill:#25302c}.chip .iso-shade{fill:#17211d}.component .iso-top{fill:#c6d0b9}.component .iso-shade{fill:#809682}
.accent-weave .iso-top{fill:#a5d750}.accent-weave .iso-shade{fill:#678d39}.accent-weave .iso-edge{stroke:#789b43}
.lid .iso-top{fill:#303935}.lid .iso-edge{stroke:#a5d750;stroke-width:1.15}.mic-rim .iso-top,.led-ring .iso-top{fill:#a5d750}.switch-thumb .iso-top{fill:#c9f46a}.switch-thumb .iso-shade{fill:#8eb748}.iso-face-text{fill:#a2bd7a}
`;
function svg(body,label){return `<svg xmlns="http://www.w3.org/2000/svg" class="iso iso-svg" data-theme="light" viewBox="0 0 ${W} ${H}" role="img" aria-label="${label}"><style>${k.ISO_CSS}${extraCSS}</style>${body}</svg>`;}
writeFileSync(join(here,'assets/keepshake-device.svg'),svg(outside(),'Isometric concept of the Keepshake screenless wristband'));
P = projection(72);
writeFileSync(join(here,'assets/keepshake-device-exploded.svg'),svg(inside(),'Exploded concept of the Keepshake wristband hardware stack'));
console.log('Built Anatomy wristband figures.');
