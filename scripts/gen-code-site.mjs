#!/usr/bin/env node
/* gen-code-site.mjs —— 站内示例代码浏览页生成器（💻 示例代码 tab 的数据源）
 *
 * 产物（直接提交，随 Quartz 部署 GitHub Pages）：
 *   quartz/static/code/files.json        —— 全部收录文件的索引（SPA 目录树/路由用）
 *   quartz/static/code/html/<项目ID>/<文件路径>.html —— shiki 双主题高亮片段
 *   quartz/static/code/index.html        —— SPA 入口（路由三形态：#/项目/文件 >
 *                                           slug 化锚点 > ?p=&f= 旧式）
 *
 * 收录范围与过滤规则（AGENTS.md「浏览页收录与更新义务」同款）：
 *   - PROJECT_GLOBS：逐套件显式收录，新套件开工必须在这里加一条；
 *   - 跳过 build*、managed_components 等生成物目录与日志/二进制（按扩展名白名单）；
 *   - 只收文本源码，单文件 ≤256KB；sdkconfig 生成文件跳过（源是 sdkconfig.defaults）。
 *
 * 用法：npm run code-site  （等价 node scripts/gen-code-site.mjs）
 *   环境变量 CODE_SITE_OUT=<dir> 可改输出目录（自检对拍用）。
 */
import { createHighlighter } from "shiki"
import fs from "node:fs"
import path from "node:path"
import { globbySync } from "globby"

const ROOT = path.resolve(import.meta.dirname, "..")
const OUT = process.env.CODE_SITE_OUT
  ? path.resolve(ROOT, process.env.CODE_SITE_OUT)
  : path.join(ROOT, "quartz", "static", "code")
const HTML_OUT = path.join(OUT, "html")
const GH_BASE = "https://github.com/hlwqds/hl-ljj-quartz/blob/v4/"

/** 收录规则：每条 glob 展开出的每个目录是一个「项目」。
 *  顺序即 files.json 顺序（SPA 侧栏顺序），新套件按阅读优先级插队。 */
const PROJECT_GLOBS = [
  "practice/lwip-examples/*", // exNN-slug 示例（含 research/）
  "practice/lwip-ch*", // 根下章节实验 lwip-chNN-*
  "practice/hwbasics", // 硬件基础实验（单项目多子目录）
  "practice/f429-lab/*", // F429 裸机实验室章节工程
  "practice/lwip-labs", // 公约与调研
]

/** 目录名跳过：精确或前缀通配（build* 命中 build/build_d/build-dbg…） */
const SKIP_DIRS = [
  "build*",
  "managed_components",
  "node_modules",
  ".git",
  "__pycache__",
  ".quartz-cache",
  ".mimosa",
]

/** 侧栏显示名覆盖：缺省用目录基名（pd），中文套件名在这里给 */
const PD_OVERRIDE = {
  hwbasics: "嵌入式硬件基础实验",
  "lwip-labs": "lwIP 公约与调研",
}

/** 生成物文件名跳过（源文件 sdkconfig.defaults 及 .ci/.debug 变体保留） */
const SKIP_FILES = new Set(["sdkconfig"])

const MAX_FILE_BYTES = 256 * 1024

/** 扩展名/basename → 逻辑语言（files.json 的 lang 字段；也是 shiki 语法名，
 *  shiki 不认识的语言渲染时回退 text，lang 字段保留逻辑名）。 */
function langOf(rel) {
  const base = path.basename(rel)
  if (base === "CMakeLists.txt" || rel.endsWith(".cmake")) return "cmake"
  if (base === "Makefile" || base.endsWith(".mk")) return "makefile"
  if (base.startsWith("sdkconfig")) return "ini"
  if (base.startsWith("Kconfig")) return "kconfig"
  const ext = path.extname(base)
  return (
    {
      ".c": "c",
      ".h": "c",
      ".cpp": "cpp",
      ".hpp": "cpp",
      ".S": "c", // 汇编启动文件按 C 高亮（legacy 约定，兼容 GNU as 注释与预处理）
      ".md": "markdown",
      ".txt": "plaintext",
      ".py": "python",
      ".sh": "bash",
      ".bash": "bash",
      ".zsh": "bash",
      ".yml": "yaml",
      ".yaml": "yaml",
      ".json": "json",
      ".js": "javascript",
      ".mjs": "javascript",
      ".cjs": "javascript",
      ".ts": "typescript",
      ".tsx": "tsx",
      ".html": "html",
      ".css": "css",
      ".sv": "systemverilog",
      ".v": "verilog",
      ".dts": "devicetree",
      ".ld": "c",
      ".cfg": "ini",
      ".conf": "ini",
      ".log": null, // 日志不入浏览页（复现命令在工程 README 与文章实验节）
    }[ext] ?? null
  )
}

/** shiki 预加载语法集——刻意与既有产物保持同一集合：markdown 围栏的内嵌
 *  高亮只对「已加载」的语言生效（bash/c/cmake/python 有色，yaml/json 纯文本），
 *  多加载会让老文章的 md 片段字节级变化。新语言要上色就在这里加。 */
const SHIKI_LANGS = [
  "c",
  "cmake",
  "ini",
  "bash",
  "python",
  "makefile",
  "markdown",
  "plaintext",
  "text",
]
const renderLangOf = (lang) => (SHIKI_LANGS.includes(lang) ? lang : "text")

const walk = (dir, keep) => {
  const out = []
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      const seg = e.name
      if (SKIP_DIRS.some((p) => (p.endsWith("*") ? seg.startsWith(p.slice(0, -1)) : seg === p)))
        continue
      out.push(...walk(path.join(dir, e.name), keep))
    } else if (e.isFile()) {
      const abs = path.join(dir, e.name)
      if (keep(e.name, abs)) out.push(abs)
    }
  }
  return out
}

const indexTemplate = String.raw`<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>💻 示例代码浏览</title>
<style>
:root{--bg:#ffffff;--fg:#1f2328;--muted:#656d76;--border:#d8dee4;--side:#f6f8fa;--accent:#0969da;}
[data-theme="dark"]{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--border:#30363d;--side:#161b22;--accent:#4493f8;}
*{box-sizing:border-box}
body{margin:0;font-family:"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;align-items:center;gap:12px;padding:8px 16px;border-bottom:1px solid var(--border);position:sticky;top:0;background:var(--bg);z-index:5}
#sitenav{display:flex;gap:4px;align-items:center;flex-wrap:wrap}
#sitenav a,#sitenav .cur{padding:4px 10px;border-radius:6px;font-size:13.5px}
#sitenav a:hover{background:var(--border)}
#sitenav .cur{background:var(--accent);color:#fff}
header .sp{flex:1}
button{background:var(--side);color:var(--fg);border:1px solid var(--border);border-radius:6px;padding:4px 10px;cursor:pointer;font-size:13px}
a{color:var(--accent);text-decoration:none}
#wrap{display:flex;height:calc(100vh - 49px)}
#side{width:320px;min-width:320px;border-right:1px solid var(--border);overflow:auto;background:var(--side);padding:8px}
#filter{width:100%;padding:6px 8px;border:1px solid var(--border);border-radius:6px;background:var(--bg);color:var(--fg);margin-bottom:8px}
details.proj,details.dir{margin:1px 0}
details.proj>summary{cursor:pointer;font-weight:600;padding:3px 6px;border-radius:5px;list-style:none}
details.dir>summary{cursor:pointer;padding:2px 6px;border-radius:5px;list-style:none;color:var(--muted);font-size:13px}
details.proj>summary::before,details.dir>summary::before{content:"▸ ";}
details.proj[open]>summary::before,details.dir[open]>summary::before{content:"▾ ";}
.f{display:block;padding:2px 6px 2px 22px;border-radius:5px;cursor:pointer;color:var(--fg);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-family:ui-monospace,Consolas,monospace}
.f:hover{background:var(--border)}
.f.sel{background:var(--accent);color:#fff}
#main{flex:1;overflow:auto;display:flex;flex-direction:column;min-width:0}
#fhead{display:flex;gap:10px;align-items:center;padding:8px 16px;border-bottom:1px solid var(--border);font-size:13px;color:var(--muted);flex-wrap:wrap}
#fpath{font-family:ui-monospace,monospace;color:var(--fg);font-weight:600;word-break:break-all}
.badge{border:1px solid var(--border);border-radius:10px;padding:0 8px;font-size:12px}
#code{margin:0;padding:12px 0;overflow:auto;flex:1}
/* shiki 双主题：--shiki-light/dark 内联在每个 token span 上，必须按作用域直接引用 */
.shiki, .shiki span{color:var(--shiki-light, inherit);}
[data-theme="dark"] .shiki, [data-theme="dark"] .shiki span{color:var(--shiki-dark, inherit);}
pre.shiki{background:var(--shiki-light-bg, transparent) !important;margin:0;font-size:13.5px;line-height:1.55;}
[data-theme="dark"] pre.shiki{background:var(--shiki-dark-bg, transparent) !important;}
pre.shiki code{display:block;padding:0 16px;counter-reset:ln}
pre.shiki code .line{counter-increment:ln;display:inline-block;width:100%}
pre.shiki code .line::before{content:counter(ln);display:inline-block;width:3.5em;margin-right:16px;text-align:right;color:var(--muted);user-select:none}
pre.shiki code .line:target{background:rgba(9,105,218,.18);border-radius:3px}
#empty{margin:auto;color:var(--muted)}
</style>
</head>
<body>
<header>
<nav id="sitenav">
  <a href="../../">🏠 主页</a>
  <a href="../../series/">📚 系列总览</a>
  <span class="cur">💻 示例代码</span>
  <a href="../../tags/">🏷️ 所有标签</a>
</nav>
<span class="sp"></span>
<button id="theme" onclick="toggleTheme()">🌓 主题</button>
<a href="https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice" target="_blank" rel="noopener">GitHub ↗</a></header>
<div id="wrap">
<div id="side"><input id="filter" placeholder="过滤文件名…"/><div id="tree"></div></div>
<div id="main"><div id="fhead"><span id="fpath">选择左侧文件</span><span id="fmeta"></span>
<span style="flex:1"></span><button id="copy" onclick="copyCode()">复制</button>
<a id="ghlink" href="#">源 ↗</a></div>
<pre id="code"><code id="inner"></code></pre><div id="empty">← 从左侧选择项目与文件</div></div>
</div>
<script>
var FILES=[],SEL=null,CURHTML="",TREE=null;
function $(s){return document.querySelector(s)}
var BASE=new URL(".",location.href);
function initTheme(){var s=localStorage.getItem("code-theme")||(matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light");document.documentElement.dataset.theme=s;}
function toggleTheme(){var d=document.documentElement.dataset.theme==="dark"?"light":"dark";document.documentElement.dataset.theme=d;localStorage.setItem("code-theme",d);}
initTheme();
/* ---- 递归目录树 ---- */
function buildNode(){return {dirs:{},files:[]}}
function insertPath(root,f){
  var parts=f.f.split("/"),n=root;
  for(var i=0;i<parts.length-1;i++){n=n.dirs[parts[i]]||(n.dirs[parts[i]]=buildNode());}
  n.files.push({name:parts[parts.length-1],f:f,el:null});
}
function renderDir(name,node,parent){
  var d=document.createElement("details");d.className="dir";d.open=true;node.el=d;
  var s=document.createElement("summary");s.textContent=name+"/";d.appendChild(s);
  renderNode(node,d);parent.appendChild(d);
}
function renderNode(node,parent){
  Object.keys(node.dirs).sort().forEach(function(k){renderDir(k,node.dirs[k],parent)});
  node.files.sort(function(a,b){return a.name<b.name?-1:1}).forEach(function(fe){
    var a=document.createElement("a");a.className="f";a.textContent=fe.name;
    a.title=fe.f.p+"/"+fe.f.f;a.dataset.path=fe.f.p+"/"+fe.f.f;
    a.onclick=function(){openFile(fe.f,a)};fe.el=a;parent.appendChild(a);
  });
}
function filterNode(node,v){
  var any=false,k,c,show;
  for(k in node.dirs){c=node.dirs[k];show=filterNode(c,v);c.el.style.display=show?"":"none";if(show){any=true;if(v)c.el.open=true;}}
  node.files.forEach(function(fe){show=!v||(fe.f.f.toLowerCase().indexOf(v)>=0);fe.el.style.display=show?"":"none";if(show)any=true;});
  return any;
}
function expandTo(el){
  var e=el;
  while(e&&e.id!=="tree"){if(e.tagName==="DETAILS")e.open=true;e=e.parentElement;}
  el.scrollIntoView({block:"nearest"});
}
(async function(){
  FILES=await (await fetch(new URL("files.json",BASE))).json();
  var groups={};
  FILES.forEach(function(f){(groups[f.p]=groups[f.p]||[]).push(f);});
  TREE=$("#tree");
  var gIds=Object.keys(groups),first=null;
  gIds.forEach(function(pid){
    var fs=groups[pid],root=buildNode();
    fs.forEach(function(f){insertPath(root,f);});
    var d=document.createElement("details");d.className="proj";d.open=(pid===gIds[0]);
    var s=document.createElement("summary");s.textContent=fs[0].pd+" ("+fs.length+")";d.appendChild(s);
    renderNode(root,d);TREE.appendChild(d);d.dataset.pid=pid;
    if(!first)first=d.querySelector(".f");
  });
  var q=new URLSearchParams(location.search),qa=q.get("p"),qf=q.get("f"),target=null;
  /* 路由三形态：#/项目/文件（干净）> slug化锚点（文章链接被站点 slugify 后）> ?p=&f=（旧） */
  var h=location.hash;
  if(!qa&&h.length>1){
    var raw=h.slice(1);
    if(raw.indexOf("/")===0){
      var hp=raw.slice(1).split("/");
      qa=hp[0];qf=hp.slice(1).join("/");
    }else{
      /* slug 化形态：按同样规则（去 / 与 .）反查唯一命中 */
      var want=raw;var hit=null;
      for(var i=0;i<FILES.length;i++){
        var fi=FILES[i];
        /* Quartz slugify 会把锚点转小写：比较两侧都 toLowerCase，否则
           README.md 这类含大写的文件深链永远反查失败，静默回落到首文件 */
        if((fi.p+"/"+fi.f).split("/").join("").split(".").join("").toLowerCase()===want){hit=fi;break;}
      }
      if(hit){qa=hit.p;qf=hit.f;}
    }
  }
  if(qa&&qf){
    target=TREE.querySelector('[data-path="'+CSS.escape(qa+"/"+qf)+'"]');
    if(target){var pd=target.closest("details.proj");if(pd)pd.open=true;}
  }
  if(target){expandTo(target);target.click();}
  else if(first){first.click();}
  if(location.hash){setTimeout(function(){var t=document.getElementById(location.hash.slice(1));if(t)t.scrollIntoView({block:"center"});},400);}
  $("#filter").oninput=function(){
    var v=$("#filter").value.trim().toLowerCase();
    var ps=TREE.querySelectorAll("details.proj");
    Array.prototype.forEach.call(ps,function(pd){
      // 每个 proj 自己持有渲染根：重扫其内部结构
      var any=filterProj(pd,v);
      pd.style.display=any||!v?"":"none";
    });
  };
  /* 对每个项目内部做递归过滤（项目根等价于一个 dir 节点集合） */
  function filterProj(pd,v){
    if(!v)return true;
    var any=false;
    Array.prototype.forEach.call(pd.children,function(ch){
      if(ch.tagName==="DETAILS"){var s=filterDirEl(ch,v);ch.style.display=s?"":"none";if(s){any=true;ch.open=true;}}
      else if(ch.classList&&ch.classList.contains("f")){var show=ch.title.toLowerCase().indexOf(v)>=0;ch.style.display=show?"":"none";if(show)any=true;}
    });
    return any;
  }
  function filterDirEl(d,v){
    var any=false;
    Array.prototype.forEach.call(d.children,function(ch){
      if(ch.tagName==="DETAILS"){var s=filterDirEl(ch,v);ch.style.display=s?"":"none";if(s){any=true;ch.open=true;}}
      else if(ch.classList&&ch.classList.contains("f")){var show=ch.title.toLowerCase().indexOf(v)>=0;ch.style.display=show?"":"none";if(show)any=true;}
    });
    return any;
  }
})();
async function openFile(f,el){
  Array.prototype.forEach.call(document.querySelectorAll(".f.sel"),function(a){a.classList.remove("sel")});
  el.classList.add("sel");SEL=f;
  $("#fpath").textContent=f.p+"/"+f.f;
  $("#fmeta").textContent="";
  var b=document.createElement("span");b.className="badge";b.textContent=f.lang;
  var m=document.createElement("span");m.textContent=f.lines+" 行";
  $("#fmeta").appendChild(b);$("#fmeta").appendChild(m);
  $("#ghlink").href="https://github.com/hlwqds/hl-ljj-quartz/blob/v4/"+f.gh;
  $("#empty").style.display="none";
  var h=await (await fetch(new URL("html/"+f.p+"/"+f.f+".html",BASE))).text();
  var doc=new DOMParser().parseFromString(h,"text/html");
  var pre=doc.querySelector("pre");
  var codeEl=$("#code");
  /* 关键：把片段 pre 的 shiki 类与背景变量搬到容器，token 颜色才能生效 */
  codeEl.className=pre.className;
  var st=pre.getAttribute("style");
  if(st)codeEl.setAttribute("style",st);else codeEl.removeAttribute("style");
  $("#inner").replaceChildren.apply($("#inner"),Array.from(pre.firstChild.childNodes));
  var i=0;
  Array.prototype.forEach.call($("#inner").children,function(ln){i++;if(!ln.id)ln.id="L"+i;});
  CURHTML=$("#inner").textContent;
  history.replaceState(null,"","#"+f.p+"/"+f.f);
  $("#code").scrollTop=0;
  codeEl.scrollIntoView({block:"start"});
}
async function copyCode(){if(CURHTML){await navigator.clipboard.writeText(CURHTML);var b=$("#copy");b.textContent="已复制";setTimeout(function(){b.textContent="复制"},1200);}}
</script>
</body></html>`

const main = async () => {
  // 1) 展开项目并收集文件：按 PROJECT_GLOBS 顺序（即 SPA 侧栏顺序），
  //    glob 内部目录名升序；跨 glob 去重。
  const seen = new Set()
  const projects = []
  for (const g of PROJECT_GLOBS) {
    // 无通配符的叶子目录直接收录（globby 对指向目录的纯路径会返回其子目录，
    // 语义不对）；带通配符的走 globby，目录名升序。
    const dirs = /[*?[]/.test(g)
      ? globbySync(g, { cwd: ROOT, onlyDirectories: true }).sort()
      : fs.existsSync(path.join(ROOT, g))
        ? [g]
        : []
    for (const d of dirs) {
      if (!seen.has(d)) {
        seen.add(d)
        projects.push(d)
      }
    }
  }
  const files = []
  for (const pdir of projects) {
    const rel = path.relative(ROOT, pdir)
    const pid = path.relative("practice", rel).split(path.sep).join("/")
    const pd = PD_OVERRIDE[pid] ?? path.basename(pdir)
    const abs = walk(pdir, (name, p) => {
      if (SKIP_FILES.has(name)) return false
      if (fs.statSync(p).size > MAX_FILE_BYTES) return false
      return langOf(path.relative(pdir, p).split(path.sep).join("/")) !== null
    }).sort()
    for (const f of abs) {
      const frel = path.relative(pdir, f).split(path.sep).join("/")
      files.push({
        p: pid,
        pd,
        f: frel,
        lang: langOf(frel),
        lines: fs.readFileSync(f, "utf8").split("\n").length,
        gh: `${rel}/${frel}`,
      })
    }
  }

  // 2) shiki 高亮：双主题（SPA 按作用域变量切明暗）。
  //    预加载集按本版 shiki 实际捆绑的语言过滤；缺失的（如 systemverilog）
  //    在 renderLangOf 里已回退 text，只影响语法配色不影响收录。
  const { bundledLanguages } = await import("shiki")
  const available = SHIKI_LANGS.filter((l) => l === "text" || l in bundledLanguages)
  const highlighter = await createHighlighter({
    themes: ["github-light", "github-dark"],
    langs: available,
  })
  fs.rmSync(HTML_OUT, { recursive: true, force: true })
  let n = 0
  for (const f of files) {
    const src = fs.readFileSync(path.join(ROOT, f.gh), "utf8")
    const html = highlighter.codeToHtml(src, {
      lang: renderLangOf(f.lang),
      themes: { light: "github-light", dark: "github-dark" },
      defaultColor: false, // 全 CSS 变量格式（--shiki-light/dark），SPA 按作用域切明暗
    })
    const dst = path.join(HTML_OUT, f.p, `${f.f}.html`)
    fs.mkdirSync(path.dirname(dst), { recursive: true })
    fs.writeFileSync(dst, html)
    n++
    if (n % 50 === 0) console.log(`  highlighted ${n}/${files.length}`)
  }

  // 3) 索引与 SPA 入口（files.json 紧凑无尾换行，与既有产物一致）
  fs.mkdirSync(OUT, { recursive: true })
  fs.writeFileSync(path.join(OUT, "files.json"), JSON.stringify(files))
  fs.writeFileSync(path.join(OUT, "index.html"), indexTemplate)
  console.log(`code-site: ${projects.length} projects, ${n} files -> ${path.relative(ROOT, OUT)}`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
