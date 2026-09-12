/* ==========================================================
   学生时代模组编辑器 — 官网脚本（无依赖，ES5 兼容，可 defer）
   结构：工具 → 主题 → 导航 → 平台感知下载 → 渐显/数字 → 复制 → Releases 动态补充
   约定：下载地址只维护在 index.html 的链接里；带 data-hero="<平台>"
        的链接是"该平台首选资产"，Hero 主按钮按访问者平台借用其 href。
   ========================================================== */
(function(){
'use strict';

/* ---------- 工具 ---------- */
function $(s){return document.querySelector(s)}
function $$(s){return Array.prototype.slice.call(document.querySelectorAll(s))}
var reduced=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}

/* ---------- 主题切换 ---------- */
var metaTheme=$('#metaTheme');
var THEME_BG={light:'#f6f3ec',dark:'#0a0814'};
var storedTheme=null;
try{storedTheme=localStorage.getItem('same-theme')}catch(e){}
function applyTheme(t){document.documentElement.setAttribute('data-theme',t);if(metaTheme)metaTheme.setAttribute('content',THEME_BG[t])}
var themeBtn=$('#themeBtn');
if(themeBtn)themeBtn.addEventListener('click',function(){
  var next=document.documentElement.getAttribute('data-theme')==='light'?'dark':'light';
  try{localStorage.setItem('same-theme',next)}catch(e){}
  storedTheme=next;applyTheme(next);
});
if(matchMedia&&matchMedia('(prefers-color-scheme: dark)').addEventListener){
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change',function(e){
    if(!storedTheme)applyTheme(e.matches?'dark':'light');
  });
}

/* ---------- 导航（滚动态 + 移动端抽屉） ---------- */
var nav=$('#nav'),burger=$('#burger');
if(nav){
  window.addEventListener('scroll',function(){nav.classList.toggle('scrolled',window.scrollY>8)},{passive:true});
  if(burger)burger.addEventListener('click',function(){
    var open=nav.classList.toggle('open');
    burger.setAttribute('aria-expanded',open?'true':'false');
  });
  $$('#nav .m-panel a').forEach(function(a){a.addEventListener('click',function(){
    nav.classList.remove('open');if(burger)burger.setAttribute('aria-expanded','false');
  })});
  document.addEventListener('keydown',function(e){
    if(e.key==='Escape'&&nav.classList.contains('open')){nav.classList.remove('open');if(burger)burger.setAttribute('aria-expanded','false')}
  });
}

/* ---------- 平台检测 + Hero 下载按钮 ----------
   Hero 按钮静态 href 默认指向 Windows（无 JS 时兜底）；
   有 JS 时按访问者平台改指向对应下载卡的 data-hero 链接。 */
var PLAT_INFO={
  windows:{label:'下载 Windows 版',sub:'exe 安装包 · 便携 zip'},
  macos:{label:'下载 macOS 版',sub:'dmg · pkg · zip'},
  linux:{label:'下载 Linux 版',sub:'AppImage · deb · zip'},
  android:{label:'下载 Android 版',sub:'apk · 通用（arm64 + x86_64）'},
  ios:{label:'获取 iOS 版',sub:'敬请期待'}
};
function detectPlatform(){
  var ua=navigator.userAgent;
  if(/Android/i.test(ua))return'android';
  if(/iPhone|iPad|iPod/i.test(ua))return'ios';
  if(/Macintosh|Mac OS X/i.test(ua))return'macos';
  if(/Linux/i.test(ua))return'linux';
  return'windows';
}
(function(){
  var p=detectPlatform(),info=PLAT_INFO[p]||PLAT_INFO.windows;
  var btn=$('#dlBtn'),lbl=$('#dlLabel'),sub=$('#dlSub');
  if(lbl)lbl.textContent=info.label;
  if(sub)sub.textContent=info.sub;
  if(!btn)return;
  if(p==='ios'){btn.setAttribute('href','#download');return}
  var src=document.querySelector('[data-hero="'+p+'"]');
  if(src&&src.getAttribute('href'))btn.setAttribute('href',src.getAttribute('href'));
})();

/* ---------- 滚动渐显 ---------- */
var reveals=$$('.reveal');
if('IntersectionObserver'in window&&!reduced){
  var io=new IntersectionObserver(function(es){es.forEach(function(en){
    if(en.isIntersecting){en.target.classList.add('in');io.unobserve(en.target)}
  })},{threshold:.12,rootMargin:'0px 0px -40px 0px'});
  reveals.forEach(function(el){io.observe(el)});
}else{reveals.forEach(function(el){el.classList.add('in')})}

/* ---------- 数字滚动 ---------- */
function animateCount(el){
  var target=parseInt(el.getAttribute('data-count'),10)||0;
  if(reduced||document.hidden){el.textContent=String(target);return} /* 弱化动效或后台标签页：直接落到终值 */
  var t0=null,dur=1300;
  var timer=setInterval(function(){
    if(!t0)t0=Date.now();
    var p=Math.min((Date.now()-t0)/dur,1),e=1-Math.pow(1-p,3);
    el.textContent=String(Math.round(target*e));
    if(p>=1)clearInterval(timer);
  },16);
}
var counters=$$('[data-count]');
if('IntersectionObserver'in window){
  var cio=new IntersectionObserver(function(es){es.forEach(function(en){
    if(en.isIntersecting){animateCount(en.target);cio.unobserve(en.target)}
  })},{threshold:.4});
  counters.forEach(function(el){cio.observe(el)});
}else{counters.forEach(animateCount)}

/* IO 兜底：极少数环境（后台 WebView / 被节流的标签页）回调不触发，
   保证滚动渐显最终一定可见、数字一定到达终值；正常浏览器不会走到这里 */
setTimeout(function(){
  reveals.forEach(function(el){el.classList.add('in')});
  counters.forEach(function(el){
    if(el.textContent==='0'||el.textContent==='')el.textContent=el.getAttribute('data-count')||'0';
  });
},3500);

/* ---------- 复制按钮 ---------- */
function legacyCopy(v){
  var ta=document.createElement('textarea');
  ta.value=v;
  ta.setAttribute('readonly','');
  ta.style.position='fixed';ta.style.opacity='0';
  document.body.appendChild(ta);
  ta.select();
  try{document.execCommand('copy')}catch(e){}
  document.body.removeChild(ta);
}
$$('.copy-btn').forEach(function(b){
  b.addEventListener('click',function(){
    var v=b.getAttribute('data-copy')||'';
    var done=function(){
      var o=b.textContent;
      b.textContent='已复制 ✓';
      b.classList.add('ok');
      setTimeout(function(){b.textContent=o;b.classList.remove('ok')},1300);
    };
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(v).then(done,function(){legacyCopy(v);done()});
    }else{legacyCopy(v);done()}
  });
});

/* ---------- 更新日志：GitHub Releases 动态补充（失败静默回退） ---------- */
function relBody(md){
  return String(md||'').split(/\r?\n/).map(function(l){
    l=l.replace(/^#{1,4}\s*/,'').replace(/^\s*[-*+]\s+?/,'').replace(/\[([^\]]+)\]\([^)]*\)/g,'$1').replace(/[`*_~]/g,'').trim();
    return l;
  }).filter(Boolean).slice(0,8).map(function(l){return '<li>'+esc(l)+'</li>'}).join('');
}
var clBox=$('#changelogList');
if(clBox){
  fetch('https://api.github.com/repos/yier12121212yie/student-age-editor/releases?per_page=10',{headers:{'Accept':'application/vnd.github+json'}})
  .then(function(r){if(!r.ok)throw new Error('bad');return r.json()})
  .then(function(data){
    if(!Array.isArray(data)||!data.length)return;
    var known={},base=clBox.querySelectorAll('.rel');
    for(var i=0;i<base.length;i++){var t=base[i].getAttribute('data-tag');if(t)known[t]=1}
    var html=data.filter(function(rel){
      if(known[rel.tag_name||''])return false;           /* 静态基础条目已收录，避免重复 */
      if(!rel.body||!String(rel.body).trim())return false; /* 空正文的发行版不占位 */
      return true;
    }).map(function(rel){
      var date=(rel.published_at||rel.created_at||'').slice(0,10);
      var tag=rel.tag_name||'';
      var body=rel.body?'<ul>'+relBody(rel.body)+'</ul>':'';
      return '<article class="rel" data-tag="'+esc(tag)+'"><h4>'+esc(tag)+' <span>'+esc(date)+'</span></h4>'+body+'</article>';
    }).join('');
    if(html)clBox.innerHTML=html+clBox.innerHTML;         /* 新版本置顶，静态条目保留作地基 */
  })
  .catch(function(){/* 静默回退静态条目 */});
}
})();
