// FreeHistory.ets —— “EPIC 送过的免费游戏”历史存档。
// 每当解析到“现在免费”列表（前台刷新或后台检测），就把本批合并进本地历史；
// 同一游戏按 “标题|开领日期” 去重。官方接口只给“当前 + 即将”，没有历年赠送历史，
// 因此历年全量记录来自第三方源 josephmate/EpicFreeGamesList（GitHub Action 每周四自动更新）。
// 页面展示 = 本地记录优先 + 第三方补全历史，按开领时刻倒序合并（同周次去重，本地保留）。

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { FREE_STORE, GameItem, MOBILE_STORE_URL, PLATFORM_MOBILE } from './EpicFree';

// preferences 里的历史存档键
const HIST_KEY: string = 'freeHistory';

// 第三方历史源：josephmate/EpicFreeGamesList 的原始 JSON（每周四由 GitHub Action 自动更新）
// https://github.com/josephmate/EpicFreeGamesList
const EXT_URL: string =
  'https://raw.githubusercontent.com/josephmate/EpicFreeGamesList/main/epic_free_games.json';

// 一周毫秒。该数据源每条只有开领日（freeDate）没有截止日期，
// 按 EPIC“周四到周四”惯例推一周作为展示区间；精确档期仍以本地记录为准。
const WEEK_MS: number = 7 * 24 * 3600 * 1000;
// 进程内缓存刷新间隔：数据每周才变，半天重拉一次足够（失败同样冷却，避免反复重试）
const EXT_TTL_MS: number = 12 * 3600 * 1000;
// 第三方全量历史的持久化缓存键：杀后台不丢，半天内冷启动直接用缓存不联网
const EXT_CACHE_KEY: string = 'extHistory';
// 第三方原始行（含 platform 字段）的持久化缓存键：供“手机限免”冷启动时直接取，无需重新下载名单
const EXT_RAW_KEY: string = 'extRawRows';

// josephmate JSON 条目（只用到的字段；platform 取值 'pc' / 'android' / 'ios'，老条目为空串）
interface ExtRow {
  gameTitle?: string;
  freeDate?: string;
  epicStoreLink?: string;
  urlSlug?: string;
  steamUrl?: string;
  steamDBUrl?: string;
  platform?: string;
}

// 第三方全量历史的进程内缓存
interface ExtState {
  list: HistItem[];
  at: number;
}
const extState: ExtState = { list: [], at: 0 };

// 第三方原始行（含 platform 字段）的进程内共享缓存：历史页与“手机限免”共用同一份下载结果
interface RawRows {
  rows: ExtRow[];
  at: number;
}
const extRaw: RawRows = { rows: [], at: 0 };

// 记录一次成功的原始行下载（fetchExternalHistory 解析成功后调用，避免手机限免重复联网）
function rememberRows(rows: ExtRow[]): void {
  extRaw.rows = rows;
  extRaw.at = Date.now();
}

// 历史条目：t=游戏名，img=封面 URL，url=官方商店页（可跳转看游戏介绍），
// startMs/endMs=该期免费开放时段，seenMs=首次被本应用检测到的时刻，
// source=数据来源（缺省为本地检测记录；接入第三方历史源后标记 'ext'）
// slug=EPIC 商品标识（第三方行自带 urlSlug，或从商店链接反推），仅作补图兜底用
export interface HistItem {
  t: string;
  img: string;
  url: string;
  startMs: number;
  endMs: number;
  seenMs: number;
  source?: string;
  slug?: string;
}

// josephmate 条目没有封面字段，但多数行带 Steam 商店/SteamDB 链接；
// 从链接里抠出 appid 即可直接拼 Steam CDN 封面（header.jpg，无需 API key）。
// 解析不到（EPIC 独占等未上 Steam 的作品）返回空串，由卡片降级为首字母占位块。
function steamCover(row: ExtRow): string {
  const candidates: string[] = [row.steamDBUrl ? row.steamDBUrl : '', row.steamUrl ? row.steamUrl : ''];
  for (let i = 0; i < candidates.length; i++) {
    const u: string = candidates[i];
    const at: number = u.indexOf('/app/');
    if (at < 0) {
      continue;
    }
    let appid: string = '';
    for (let j = at + 5; j < u.length; j++) {
      const ch: string = u.charAt(j);
      if (ch < '0' || ch > '9') {
        break;
      }
      appid += ch;
    }
    if (appid.length > 0) {
      return 'https://cdn.cloudflare.steamstatic.com/steam/apps/' + appid + '/header.jpg';
    }
  }
  return '';
}

// ================= 封面缓存 + 运行时两级补图 =================
// josephmate 源里约一成历史条目没登记 Steam/SteamDB 链接，解析不到 appid，
// 封面只能“卡片进入可见窗口”时再运行时补。策略分两级（结果按标题写封面缓存，避免重复联网）：
//   1) Steam 商店搜索：标题带“冒号前主标题 / 去版本后缀”等多个候选词查 appid → CDN header 封面；
//   2) EPIC 兜底：有 slug 时按内容产品接口找横版 keyImage（多数老商品没有，仅作保险）。
// 缓存条目同时记查询时刻：成功→长期有效；查无→一周后才允许重查，不会每次进历史都打网络。

const COVER_KEY: string = 'histCovers';
// “某标题查无封面”后，距下次允许重查的间隔（成功的封面长期使用，不过期）
const COVER_RETRY_MS: number = 7 * 24 * 3600 * 1000;
// Steam 商店搜索最小请求间隔：补图按可见窗口串行排队，避免批量查询触发限流
const SEARCH_GAP_MS: number = 450;

interface CoverEnt {
  key: string;
  img: string;
  ts: number;
}

interface CoverState {
  loaded: boolean;
  rows: CoverEnt[];
}

// 缓存行按标题去重保存（成功/查无都记，数量级最多百余条，线性查找足够）
const coverState: CoverState = { loaded: false, rows: [] };
// 本进程封面缓存是否有新增（一次补图批量结束后统一写回 preferences）
let coverDirty: boolean = false;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

// 请求一次返回文本；网络错误/非 200 一律 reject（与 EpicFree 抓取接口同风格）
function httpGetText(url: string, timeoutMs: number): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const req = http.createHttp();
    req.request(
      url,
      {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      },
      (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (!err && data.responseCode === 200) {
          resolve(String(data.result));
        } else {
          reject(err);
        }
      }
    );
  });
}

// Steam 商店搜索接口的最小响应结构（其余字段用不到）
interface SteamItem {
  id: number;
  name: string;
  type: string;
}

interface SteamSearchResp {
  total?: number;
  items?: SteamItem[];
}

// EPIC 内容产品接口的最小响应结构
interface EpicImg {
  type?: string;
  url?: string;
  width?: number;
  height?: number;
}

interface EpicProduct {
  keyImages?: EpicImg[];
}

// 读取封面缓存（整个进程只读一次；之后补图/回填都走内存）
async function ensureCoversLoaded(context: common.Context): Promise<void> {
  if (coverState.loaded) {
    return;
  }
  coverState.loaded = true;
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw: string = p.getSync(COVER_KEY, '[]') as string;
    const arr = JSON.parse(raw) as CoverEnt[];
    if (arr instanceof Array) {
      coverState.rows = arr;
    }
  } catch (e) {
  }
}

// 写回封面缓存（由补图批量结束处统一调用，避免逐条 IO）
async function saveCovers(context: common.Context): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(COVER_KEY, JSON.stringify(coverState.rows));
    await p.flush();
  } catch (e) {
  }
}

// 按标题找缓存行；没有返回 null
function coverFind(title: string): CoverEnt | null {
  const rows: CoverEnt[] = coverState.rows;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].key === title) {
      return rows[i];
    }
  }
  return null;
}

// 写入/覆盖某标题的封面缓存（成功与“查无”都记录）
function coverPut(title: string, img: string, ts: number): void {
  const rows: CoverEnt[] = coverState.rows;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].key === title) {
      rows.splice(i, 1);
      break;
    }
  }
  const row: CoverEnt = { key: title, img: img, ts: ts };
  rows.push(row);
  coverDirty = true;
}

// 复制条目并替换封面（ArkTS 无对象展开，逐字段拷贝；保留 source/slug）
function cloneWithImg(it: HistItem, img: string): HistItem {
  const cp: HistItem = {
    t: it.t,
    img: img,
    url: it.url,
    startMs: it.startMs,
    endMs: it.endMs,
    seenMs: it.seenMs
  };
  if (it.source && it.source.length > 0) {
    cp.source = it.source;
  }
  if (it.slug && it.slug.length > 0) {
    cp.slug = it.slug;
  }
  return cp;
}

// 从 EPIC 商店链接里提取 slug（形如 .../p/<slug> 或 .../product/<slug>）
function slugFromUrl(url: string): string {
  const markers: string[] = ['/p/', '/product/'];
  for (let i = 0; i < markers.length; i++) {
    const mk: string = markers[i];
    const at: number = url.indexOf(mk);
    if (at < 0) {
      continue;
    }
    let slug: string = '';
    for (let j = at + mk.length; j < url.length; j++) {
      const ch: string = url.charAt(j);
      if (ch === '/' || ch === '?' || ch === '#') {
        break;
      }
      slug += ch;
    }
    return slug;
  }
  return '';
}

// 去掉标题里的商标/注册符号与智能引号，避免干扰 Steam 搜索
function cleanTitle(title: string): string {
  let out: string = '';
  for (let i = 0; i < title.length; i++) {
    const c: string = title.charAt(i);
    const code: number = title.charCodeAt(i);
    if (code === 0x2122 || code === 0x00ae || code === 0x2019) { // ™ ® ’
      continue;
    }
    out += c;
  }
  return out;
}

// 常见“版本/合集”类副标题关键词：命中说明副标题只是版本描述，不必单独去搜
const EDITION_WORDS: string[] = [
  'edition', 'collection', 'soundtrack', 'remastered', 'remaster', 'definitive',
  'ultimate', 'deluxe', 'complete', 'game of the year', 'goty', 'day one', 'standard'
];

function isEditionSub(s: string): boolean {
  const low: string = s.toLowerCase();
  for (let i = 0; i < EDITION_WORDS.length; i++) {
    if (low.indexOf(EDITION_WORDS[i]) >= 0) {
      return true;
    }
  }
  return false;
}

// 生成 Steam 搜索候选词：主标题优先，副标题若是版本描述则跳过，全标题兜底
function steamCandidates(title: string): string[] {
  const out: string[] = [];
  const clean: string = cleanTitle(title);
  if (clean.length === 0) {
    return out;
  }
  const at: number = clean.indexOf(':');
  if (at <= 0) {
    out.push(clean);
    return out;
  }
  const main: string = clean.substring(0, at).trim();
  const sub: string = clean.substring(at + 1).trim();
  if (main.length > 0) {
    out.push(main); // 如 “theHunter: Call of the Wild” 用 theHunter 更好命中
  }
  if (sub.length > 0 && !isEditionSub(sub)) {
    out.push(sub);
  }
  out.push(clean);
  return out;
}

// 单次 Steam 商店搜索：返回首个 app 的应用 id；无匹配返回 0；网络错误向上抛由调用方重试
async function steamSearchAppId(term: string): Promise<number> {
  await sleep(SEARCH_GAP_MS); // 串行节流，避免批量查询被限流
  const url: string = 'https://store.steampowered.com/api/storesearch/?term=' +
    encodeURIComponent(term) + '&l=en&cc=US';
  const text: string = await httpGetText(url, 12000);
  const resp: SteamSearchResp = JSON.parse(text) as SteamSearchResp;
  const items = resp.items;
  if (!(items instanceof Array)) {
    return 0;
  }
  for (let i = 0; i < items.length; i++) {
    if (items[i].type === 'app' && items[i].id > 0) {
      return items[i].id;
    }
  }
  return 0;
}

// 按标题在 Steam 商店搜索补封面；返回空串表示没找到
async function resolveSteamCover(title: string): Promise<string> {
  const cands: string[] = steamCandidates(title);
  for (let c = 0; c < cands.length; c++) {
    // 每个候选最多两遍尝试（偶发限流/网络抖动：等待后重试一次）
    for (let t = 0; t < 2; t++) {
      try {
        const appid: number = await steamSearchAppId(cands[c]);
        if (appid > 0) {
          return 'https://cdn.cloudflare.steamstatic.com/steam/apps/' + appid + '/header.jpg';
        }
        break; // 搜索本身成功但没匹配：换下一个候选词
      } catch (e) {
        if (t === 0) {
          await sleep(1500);
        } else {
          break; // 两遍都失败：放弃该候选词
        }
      }
    }
  }
  return '';
}

// EPIC 兜底：内容产品接口按 slug 找横版 keyImage（多数老赠品接口无图/404，属保险手段）
async function resolveEpicCover(slug: string): Promise<string> {
  if (slug.length === 0) {
    return '';
  }
  const url: string = 'https://store-content.ak.epicgames.com/api/en-US/content/products/' + slug;
  let text: string = '';
  try {
    text = await httpGetText(url, 10000);
  } catch (e) {
    return '';
  }
  try {
    const prod: EpicProduct = JSON.parse(text) as EpicProduct;
    const ks = prod.keyImages;
    if (!(ks instanceof Array)) {
      return '';
    }
    let fallback: string = '';
    for (let i = 0; i < ks.length; i++) {
      const k: EpicImg = ks[i];
      const u: string = k.url ? k.url : '';
      if (u.length === 0) {
        continue;
      }
      const ty: string = k.type ? k.type : '';
      // 跳过 logo/图标类，优先横版封面；没有横版时退回第一张非 logo 图
      if (ty.indexOf('Logo') >= 0) {
        continue;
      }
      if (ty.indexOf('Wide') >= 0 || ty.indexOf('wide') >= 0) {
        return u;
      }
      if (fallback.length === 0) {
        fallback = u;
      }
    }
    return fallback;
  } catch (e) {
    return '';
  }
}

// 把封面缓存里已解析到的图回填进列表（只替换“当前无图且缓存命中”的条目；
// 无命中时原样返回，方便上层判断是否有变化）
function fillCoversFromCache(list: HistItem[]): HistItem[] {
  let out: HistItem[] = list;
  let changed: boolean = false;
  for (let i = 0; i < list.length; i++) {
    const it: HistItem = list[i];
    if (it.img.length > 0) {
      continue;
    }
    const ent: CoverEnt | null = coverFind(it.t.trim());
    if (!ent || ent.img.length === 0) {
      continue;
    }
    if (!changed) {
      out = list.slice(0);
      changed = true;
    }
    out[i] = cloneWithImg(it, ent.img);
  }
  return out;
}

// 对 list 前 limit 条（= 页面可见窗口）里“无封面”的条目做运行时两级补图：
// 结果写入封面缓存并返回新的完整列表（无命中时返回同一引用，便于上层判断变化）。
// 调用方应在可见窗口变化（进入历史页 / 上滑加载更多）后触发，且不应并发调用。
export async function backfillHistCovers(context: common.Context, list: HistItem[], limit: number): Promise<HistItem[]> {
  if (list.length === 0 || limit <= 0) {
    return list;
  }
  await ensureCoversLoaded(context);
  const end: number = Math.min(limit, list.length);
  const hitIdx: number[] = [];
  const hitImg: string[] = [];
  for (let i = 0; i < end; i++) {
    const it: HistItem = list[i];
    if (it.img.length > 0) {
      continue;
    }
    const title: string = it.t.trim();
    if (title.length === 0) {
      continue;
    }
    const ent: CoverEnt | null = coverFind(title);
    if (ent) {
      if (ent.img.length > 0) {
        // 缓存里有封面：直接回填（一般由读历史时的 fillCoversFromCache 提前做了）
        hitIdx.push(i);
        hitImg.push(ent.img);
        continue;
      }
      if (Date.now() - ent.ts < COVER_RETRY_MS) {
        continue; // 最近才查过且无结果：不重复打扰网络
      }
    }
    // 需要联网解析：Steam 商店搜索优先，EPIC 内容接口兜底
    let img: string = '';
    try {
      img = await resolveSteamCover(title);
    } catch (e) {
      img = '';
    }
    if (img.length === 0 && it.slug && it.slug.length > 0) {
      try {
        img = await resolveEpicCover(it.slug);
      } catch (e) {
        img = '';
      }
    }
    coverPut(title, img, Date.now());
    if (img.length > 0) {
      hitIdx.push(i);
      hitImg.push(img);
    }
  }
  if (coverDirty) {
    await saveCovers(context);
    coverDirty = false;
  }
  if (hitIdx.length === 0) {
    return list;
  }
  const out: HistItem[] = list.slice(0);
  for (let k = 0; k < hitIdx.length; k++) {
    out[hitIdx[k]] = cloneWithImg(list[hitIdx[k]], hitImg[k]);
  }
  return out;
}

// 去重键：标题 + 开领日期（同一游戏不同周次的免费档不会互相覆盖）
function dayKey(ms: number): string {
  const d = new Date(ms);
  return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
}

// 判定两条记录是否属于“同一免费期”：同名游戏且免费区间有重叠。
// 背景：同一款游戏的一次赠送常连续免费好几天，旧版把“检测时刻”当 startMs，
// 跨天检测会生成不同的“标题|日期”键，把同一期拆成多条重复入库。
// 规则：同一游戏的两期不可能同时免费，因此只要时间窗相交就是同一期；
// 官方偶尔顺延截止日期（结束日变化）时也能据此归并，不会另起一条。
function sameRound(a: HistItem, b: HistItem): boolean {
  if (a.t !== b.t) {
    return false;
  }
  const ae: number = a.endMs > a.startMs ? a.endMs : a.startMs + WEEK_MS;
  const be: number = b.endMs > b.startMs ? b.endMs : b.startMs + WEEK_MS;
  return be > a.startMs && ae > b.startMs;
}

// 把同一“免费期”的重复记录折叠为一条：取“开领更早”的为代表
// （新版记录用真实开领日，通常早于旧版“检测时刻”，能自然顶替旧条目），
// 封面/链接取其有值者，seenMs 取两者更早的检测时刻。
function compactLocal(list: HistItem[]): HistItem[] {
  const out: HistItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const cur: HistItem = list[i];
    let hit: number = -1;
    for (let j = 0; j < out.length; j++) {
      if (sameRound(out[j], cur)) {
        hit = j;
        break;
      }
    }
    if (hit < 0) {
      out.push(cur);
      continue;
    }
    const old: HistItem = out[hit];
    const better: HistItem = old.startMs <= cur.startMs ? old : cur;
    const other: HistItem = better === old ? cur : old;
    const rep: HistItem = {
      t: better.t,
      img: better.img.length > 0 ? better.img : other.img,
      url: better.url.length > 0 ? better.url : other.url,
      startMs: better.startMs,
      endMs: better.endMs > better.startMs ? better.endMs : other.endMs,
      seenMs: old.seenMs < cur.seenMs ? old.seenMs : cur.seenMs
    };
    const slug: string = better.slug ? better.slug : (other.slug ? other.slug : '');
    if (slug.length > 0) {
      rep.slug = slug;
    }
    out[hit] = rep;
  }
  return out;
}

// 读取本地历史（存时即按最新在前）。顺带做一次“同一期去重”自愈：
// 旧版本留下的跨天重复会在读取时折叠回单条并回写，不会一直留在存档里。
export async function readHistory(context: common.Context): Promise<HistItem[]> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(HIST_KEY, '[]') as string;
    const arr = JSON.parse(raw) as HistItem[];
    let list: HistItem[] = arr instanceof Array ? arr : [];
    if (list.length > 1) {
      const comp: HistItem[] = compactLocal(list);
      if (comp.length !== list.length) {
        p.putSync(HIST_KEY, JSON.stringify(comp));
        await p.flush();
        list = comp;
      }
    }
    return list;
  } catch (e) {
    return [];
  }
}

// 把“现在免费”这批合并进本地历史，返回本次新增条数（0=本批之前都记录过了）
export async function recordFreeNow(context: common.Context, nowArr: GameItem[]): Promise<number> {
  if (nowArr.length === 0) {
    return 0;
  }
  let added: number = 0;
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(HIST_KEY, '[]') as string;
    const list: HistItem[] = JSON.parse(raw) as HistItem[];
    const pool: HistItem[] = list instanceof Array ? list : [];
    const now: number = Date.now();
    for (let i = 0; i < nowArr.length; i++) {
      const it: GameItem = nowArr[i];
      const item: HistItem = {
        t: it.title,
        img: it.img,
        url: it.claim,
        startMs: it.startMs,
        endMs: typeof it.endMs === 'number' && it.endMs > now ? it.endMs : now,
        seenMs: now
      };
      // 与已有记录按“同名 + 档期重叠”去重：同一款游戏连续免费期间反复检测到只算一期
      let dup: boolean = false;
      for (let j = 0; j < pool.length; j++) {
        if (sameRound(pool[j], item)) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      // 本地检测条目通常已带官方封面，slug 仅留作极端缺图时的 EPIC 兜底
      const slug: string = slugFromUrl(it.claim);
      if (slug.length > 0) {
        item.slug = slug;
      }
      pool.unshift(item); // 最新检测到的排最前
      added++;
    }
    if (added > 0) {
      p.putSync(HIST_KEY, JSON.stringify(pool));
      await p.flush();
    }
  } catch (e) {
    added = 0;
  }
  return added;
}

// ================= 第三方历史源（补全历年全量记录） =================
// josephmate 的 JSON 是社区整理、机器可读的 EPIC 历年赠送清单，
// 覆盖从 2018-12 首个喜加一起的每一期。每条只有开领日与商店页链接、
// 无截止日期（展示区间按一周推定）；封面图由行内 Steam 链接解析出 appid 后
// 用 Steam CDN header 补全（未上 Steam 的作品则降级为首字母占位块）。
// 读第三方全量历史的持久化缓存（杀后台不丢）；无缓存/损坏返回 null
async function readExtCache(context: common.Context): Promise<ExtState | null> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(EXT_CACHE_KEY, '') as string;
    if (raw.length === 0) {
      return null;
    }
    const obj = JSON.parse(raw) as ExtState;
    if (!(obj.list instanceof Array) || typeof obj.at !== 'number') {
      return null;
    }
    return obj;
  } catch (e) {
    return null;
  }
}

// 写第三方全量历史的持久化缓存（联网成功后更新，供下次冷启动秒开）
async function saveExtCache(context: common.Context, list: HistItem[], at: number): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(EXT_CACHE_KEY, JSON.stringify({ list: list, at: at }));
    await p.flush();
  } catch (e) {
  }
}

export async function fetchExternalHistory(context: common.Context): Promise<HistItem[]> {
  const now: number = Date.now();
  // 进程内缓存命中（半天内拉取过/冷却过）：直接返回
  if (extState.list.length > 0 && now - extState.at < EXT_TTL_MS) {
    return extState.list;
  }
  // 冷启动：先读持久化缓存，新鲜则秒开不联网
  let cached: ExtState | null = null;
  try {
    cached = await readExtCache(context);
  } catch (e) {
    cached = null;
  }
  if (cached !== null && cached.list.length > 0 && now - cached.at < EXT_TTL_MS) {
    extState.list = cached.list;
    extState.at = cached.at;
    return extState.list;
  }
  try {
    const text: string = await new Promise<string>((resolve, reject) => {
      const req = http.createHttp();
      req.request(
        EXT_URL,
        {
          method: http.RequestMethod.GET,
          connectTimeout: 10000,
          readTimeout: 20000,
          expectDataType: http.HttpDataType.STRING
        },
        (err: BusinessError, data: http.HttpResponse) => {
          req.destroy();
          if (!err && data.responseCode === 200) {
            resolve(String(data.result));
          } else {
            reject(err);
          }
        }
      );
    });
    const rows: ExtRow[] = JSON.parse(text) as ExtRow[];
    if (!(rows instanceof Array)) {
      extState.at = now;
      return [];
    }
    // 同一次下载结果顺手共享给“手机限免”，避免其再打一次网络
    rememberRows(rows);
    await saveRawRowsCache(context, rows);
    const list: HistItem[] = [];
    for (const r of rows) {
      const title: string = r.gameTitle ? r.gameTitle : '';
      const date: string = r.freeDate ? r.freeDate : '';
      if (title.length === 0 || date.length === 0) {
        continue;
      }
      // freeDate 形如 “2018-12-14”，按本地时间当天 0 点作为开领时刻
      const parts: string[] = date.split('-');
      if (parts.length !== 3) {
        continue;
      }
      const y: number = parseInt(parts[0]);
      const m: number = parseInt(parts[1]);
      const d: number = parseInt(parts[2]);
      if (isNaN(y) || isNaN(m) || isNaN(d)) {
        continue;
      }
      const start: number = new Date(y, m - 1, d).getTime();
      let url: string = r.epicStoreLink ? r.epicStoreLink : '';
      if (url.length === 0 && r.urlSlug && r.urlSlug.length > 0) {
        url = 'https://store.epicgames.com/en-US/p/' + r.urlSlug;
      }
      const item: HistItem = {
        t: title,
        img: steamCover(r), // 源不带封面字段：用 Steam CDN 封面补全；解析不到则留空降级占位块
        url: url,
        startMs: start,
        endMs: start + WEEK_MS,
        seenMs: start
      };
      // 记录商品 slug：若行内仍解析不到封面，可凭 slug 走 EPIC 内容接口做最后一搏
      const slug: string = (r.urlSlug && r.urlSlug.length > 0) ? r.urlSlug : slugFromUrl(url);
      if (slug.length > 0) {
        item.slug = slug;
      }
      list.push(item);
    }
    extState.list = list;
    extState.at = now;
    await saveExtCache(context, list, now);
    return list;
  } catch (e) {
    // 联网失败：有持久化缓存（哪怕过期）先兜底展示，避免弱网时历史页空窗；
    // 无缓存才返回空。两种情况都把 at 置 now 冷却，避免本进程内反复重试。
    if (cached !== null && cached.list.length > 0) {
      extState.list = cached.list;
      extState.at = now;
      return extState.list;
    }
    extState.at = now;
    return [];
  }
}

// ================= 手机限免（复用 josephmate 名单的 platform=android 行） =================
// EPIC 手机商店的“周免”是独立于 PC 周免的一批游戏（如 Evan's Remains 只在手机免费）。
// josephmate 名单对每款免费都按 pc/android/ios 分行，且托管在 raw.githubusercontent（原生 http 可直连），
// 因此手机限免不再请求会被 Cloudflare 403 拦掉的 EPIC 手机接口，改从这里取“当前窗口内”的 android 行。

async function readRawRowsCache(context: common.Context): Promise<RawRows | null> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw: string = p.getSync(EXT_RAW_KEY, '') as string;
    if (raw.length === 0) {
      return null;
    }
    const obj = JSON.parse(raw) as RawRows;
    if (!(obj.rows instanceof Array)) {
      return null;
    }
    return obj;
  } catch (e) {
    return null;
  }
}

async function saveRawRowsCache(context: common.Context, rows: ExtRow[]): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const save: RawRows = { rows: rows, at: Date.now() };
    p.putSync(EXT_RAW_KEY, JSON.stringify(save));
    await p.flush();
  } catch (e) {
  }
}

// 取得第三方原始行：进程内 12h → 本地缓存 12h → 联网；联网失败用过期缓存兜底
async function fetchExtRows(context: common.Context): Promise<ExtRow[]> {
  const now: number = Date.now();
  if (extRaw.rows.length > 0 && now - extRaw.at < EXT_TTL_MS) {
    return extRaw.rows;
  }
  let cached: RawRows | null = null;
  try {
    cached = await readRawRowsCache(context);
  } catch (e) {
    cached = null;
  }
  if (cached !== null && cached.rows.length > 0 && now - cached.at < EXT_TTL_MS) {
    extRaw.rows = cached.rows;
    extRaw.at = cached.at;
    return extRaw.rows;
  }
  try {
    const text: string = await httpGetText(EXT_URL, 20000);
    const rows = JSON.parse(text) as ExtRow[];
    if (rows instanceof Array && rows.length > 0) {
      rememberRows(rows);
      await saveRawRowsCache(context, rows);
      return rows;
    }
    extRaw.at = now;
    return [];
  } catch (e) {
    if (cached !== null && cached.rows.length > 0) {
      extRaw.rows = cached.rows;
      extRaw.at = cached.at;
      return extRaw.rows;
    }
    extRaw.at = now;
    return [];
  }
}

// 当前仍在免费窗口内的 Android 手机限免（freeDate 为开领日，EPIC 惯例“周四起免费一周”）
export async function currentMobileFree(context: common.Context): Promise<GameItem[]> {
  const rows: ExtRow[] = await fetchExtRows(context);
  if (rows.length === 0) {
    return [];
  }
  const now: number = Date.now();
  const hit: GameItem[] = [];
  const used: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    const r: ExtRow = rows[i];
    if (r.platform !== 'android' || !r.gameTitle || !r.freeDate) {
      continue;
    }
    const parts: string[] = r.freeDate.split('-');
    if (parts.length !== 3) {
      continue;
    }
    const y: number = parseInt(parts[0]);
    const m: number = parseInt(parts[1]);
    const d: number = parseInt(parts[2]);
    if (isNaN(y) || isNaN(m) || isNaN(d)) {
      continue;
    }
    const start: number = new Date(y, m - 1, d).getTime();
    if (now < start || now >= start + WEEK_MS) {
      continue;
    }
    if (used.indexOf(r.gameTitle) >= 0) {
      continue;
    }
    used.push(r.gameTitle);
    let claim: string = r.epicStoreLink ? r.epicStoreLink : '';
    if (claim.length === 0 && r.urlSlug && r.urlSlug.length > 0) {
      claim = 'https://store.epicgames.com/en-US/p/' + r.urlSlug;
    }
    if (claim.length === 0) {
      claim = MOBILE_STORE_URL;
    }
    const item: GameItem = {
      title: r.gameTitle,
      sub: 'Android 手机免费',
      img: steamCover(r),
      claim: claim,
      startMs: start,
      platform: PLATFORM_MOBILE
    };
    hit.push(item);
  }
  return hit;
}

// 页面读历史：本地记录 + 第三方全量历史去重合并，按开领时刻新→旧排序。
// 去重规则：同键（同标题同日）跳过；同一游戏若与已收记录的起始时刻相差不足一周，
// 视为同一免费周，第三方那条不加入 —— 本地记录（含真实封面/截止日）始终优先保留。
export async function readHistoryMerged(context: common.Context): Promise<HistItem[]> {
  const local: HistItem[] = await readHistory(context);
  let ext: HistItem[] = [];
  try {
    ext = await fetchExternalHistory(context);
  } catch (e) {
    ext = [];
  }
  const merged: HistItem[] = [];
  const keys: string[] = [];
  const nearWeek = (h: HistItem, list: HistItem[]): boolean => {
    for (let i = 0; i < list.length; i++) {
      const m: HistItem = list[i];
      if (m.t === h.t) {
        const diff: number = m.startMs - h.startMs;
        if (diff < WEEK_MS && diff > -WEEK_MS) {
          return true;
        }
      }
    }
    return false;
  };
  const addOne = (h: HistItem): void => {
    const k: string = h.t + '|' + dayKey(h.startMs);
    if (keys.indexOf(k) >= 0) {
      return;
    }
    keys.push(k);
    merged.push(h);
  };
  for (let i = 0; i < local.length; i++) {
    addOne(local[i]);
  }
  for (let i = 0; i < ext.length; i++) {
    if (!nearWeek(ext[i], merged)) {
      addOne(ext[i]);
    }
  }
  merged.sort((a: HistItem, b: HistItem): number => b.startMs - a.startMs);
  // 已解析过的封面（含上次会话写入缓存的结果）直接回填，减少进入历史时的联网补图
  await ensureCoversLoaded(context);
  return fillCoversFromCache(merged);
}
