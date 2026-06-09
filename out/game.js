// Jianglin Game Engine v2
const CANVAS_W=1280, CANVAS_H=720;
const canvas=document.getElementById('game');
const ctx=canvas.getContext('2d');
canvas.width=CANVAS_W; canvas.height=CANVAS_H;

// Camera
let cam={x:0,y:0,zoom:0.55};
// Game state
let gameHour=6, timeSpeed=0.3;
let npcs=[], schedules={}, buildingPositions=[];
let loadedAssets=0, totalAssets=0;

// Asset loader
const images={};
function loadImg(key,path){
  totalAssets++;
  const img=new Image();
  img.onload=()=>{loadedAssets++;updateLoadBar();if(loadedAssets===totalAssets)startGame();};
  img.src=path+'?v=5';
  images[key]=img;
}

// Load all assets
loadImg('ground','ground-tiles.png');
for(let i=0;i<5;i++) loadImg('b'+i,'buildings/b'+i+'.png');
for(let i=0;i<3;i++) loadImg('c'+i,'characters/c'+i+'.png');

function updateLoadBar(){
  const pct=Math.round(loadedAssets/totalAssets*100);
  document.getElementById('loadBar').style.width=pct+'%';
  document.getElementById('loadText').textContent='加载中 '+pct+'%';
}

function startGame(){
  document.getElementById('loading').style.display='none';
  fetch('schedule.json').then(r=>r.json()).then(d=>{
    schedules=d;
    initNPCs(d);
  }).catch(()=>initNPCs(null));
  requestAnimationFrame(gameLoop);
}

function initNPCs(data){
  const chars=data?data.characters:{};
  const names=['engineer_wang','scientist_li','scavenger_zhang'];
  const labels=['老王','小李','老张'];
  const roles=['工程师','科学家','拾荒者'];
  const starts=[[380,280],[520,320],[450,420]];
  names.forEach((key,i)=>{
    const c=chars[key];
    npcs.push({
      name:c?c.name:labels[i],
      role:c?c.role:roles[i],
      x:starts[i][0],y:starts[i][1],
      tx:starts[i][0],ty:starts[i][1],
      sprite:images['c'+i],
      schedule:c?c.schedule:[],
      memory:c?c.memory||[]:[],
      lastText:'',lastHour:-1
    });
  });
  // Building positions
  buildingPositions=[
    {x:100,y:100,img:'b0',label:'广播塔'},
    {x:550,y:80,img:'b1',label:'温室'},
    {x:450,y:380,img:'b2',label:'掩体'},
    {x:700,y:300,img:'b3',label:'瞭望塔'},
    {x:250,y:450,img:'b4',label:'厨房'},
  ];
}

let timeAcc=0;
function gameLoop(ts){
  timeAcc+=0.016;
  if(timeAcc>timeSpeed){gameHour+=0.5;timeAcc=0;if(gameHour>=24)gameHour=6;}
  updateNPCs();
  render();
  requestAnimationFrame(gameLoop);
}

function updateNPCs(){
  const h=Math.floor(gameHour);
  npcs.forEach(npc=>{
    const acts=npc.schedule||[];
    const act=acts.find(a=>a.time===h)||[...acts].reverse().find(a=>a.time<=h);
    if(!act)return;
    if(act.location){npc.tx=act.location[0];npc.ty=act.location[1];}
    const dx=npc.tx-npc.x,dy=npc.ty-npc.y,dist=Math.sqrt(dx*dx+dy*dy);
    if(dist>1){npc.x+=dx*0.05;npc.y+=dy*0.05;}
    if(act.text&&h!==npc.lastHour){npc.lastHour=h;showBubble(act.text);}
  });
}

function render(){
  ctx.fillStyle='#1a1a2e';ctx.fillRect(0,0,CANVAS_W,CANVAS_H);
  ctx.save();
  ctx.translate(CANVAS_W/2+cam.x,CANVAS_H/2+cam.y);
  ctx.scale(cam.zoom,cam.zoom);

  // Tiled ground
  if(images.ground){
    const gs=1024;
    for(let x=-gs;x<gs*2;x+=gs)
      for(let y=-gs;y<gs*2;y+=gs)
        ctx.drawImage(images.ground,x,y,gs,gs);
  }

  // Buildings
  buildingPositions.forEach(b=>{
    const img=images[b.img];
    if(img){
      const s=0.35;
      ctx.drawImage(img,b.x,b.y,img.width*s,img.height*s);
      ctx.fillStyle='rgba(0,0,0,0.5)';
      ctx.fillRect(b.x+img.width*s/2-30,b.y+img.height*s-10,60,16);
      ctx.fillStyle='#f5d78c';ctx.font='11px "Microsoft YaHei"';ctx.textAlign='center';
      ctx.fillText(b.label,b.x+img.width*s/2,b.y+img.height*s+3);
    }
  });

  // NPCs
  npcs.forEach((npc,i)=>{
    const img=npc.sprite;
    if(img){
      const s=0.22;
      ctx.drawImage(img,npc.x-img.width*s/2,npc.y-img.height*s,img.width*s,img.height*s);
      // Name badge
      ctx.fillStyle='rgba(0,0,0,0.6)';
      ctx.fillRect(npc.x-32,npc.y+15,64,16);
      ctx.fillStyle='#f5d78c';ctx.font='11px "Microsoft YaHei"';ctx.textAlign='center';
      ctx.fillText(npc.name,npc.x,npc.y+28);
    }
  });

  ctx.restore();

  // HUD
  const h=Math.floor(gameHour),m=Math.floor((gameHour%1)*60);
  document.getElementById('clock').textContent='第1天 '+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0');
}

let bubbleTimer;
function showBubble(text){
  const el=document.getElementById('speech');
  el.textContent=text;el.style.opacity='1';
  clearTimeout(bubbleTimer);
  bubbleTimer=setTimeout(()=>{el.style.opacity='0';},4000);
}

// Controls
canvas.addEventListener('wheel',e=>{e.preventDefault();cam.zoom=Math.max(0.2,Math.min(1.5,cam.zoom*(e.deltaY>0?0.9:1.1)));});
let drag=false,lx,ly;
canvas.addEventListener('mousedown',e=>{if(e.button===1){drag=true;lx=e.clientX;ly=e.clientY;}});
canvas.addEventListener('mousemove',e=>{if(drag){cam.x+=e.clientX-lx;cam.y+=e.clientY-ly;lx=e.clientX;ly=e.clientY;}});
canvas.addEventListener('mouseup',()=>{drag=false;});
window.addEventListener('keydown',e=>{
  if(e.key==='r')gameHour=6;
  if(e.key==='+'||e.key==='=')timeSpeed=Math.min(2,timeSpeed+0.1);
  if(e.key==='-')timeSpeed=Math.max(0.1,timeSpeed-0.1);
});
