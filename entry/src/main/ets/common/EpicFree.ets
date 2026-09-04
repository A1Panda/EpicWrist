// EpicFree.ets —— EPIC“每周免费游戏”抓取/解析/判新/通知的公共实现。
// Index.ets（页面）与 EpicCheckWorkAbility（WorkScheduler 后台任务）共用本模块，
// 保证“已见名单 + 新增判定 + 通知文案/ID”行为一致。

import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';

// ================= 常量 =================

// EPIC 官方免 key 免费促销接口（返回纯 JSON，约 30KB）
export const API_URL: string = 'https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions';
// 商店区域/语言。全球免费赠送基本同步，用美国区数据源即可。
export const API_LOCALE: string = 'en-US';
export const API_COUNTRY: string = 'US';
// 各分区最多展示条数
export const MAX_NOW: number = 3;
export const MAX_SOON: number = 5;
// 回到前台超过该间隔才自动重新拉取（毫秒）
export const REFRESH_GAP_MS: number = 5 * 60 * 1000;

// preferences 存档名与键（页面与后台任务共用同一份数据）
export const FREE_STORE: string = 'epic_free_state';
export const SEEN_KEY: string = 'seenFree';        // 已见/已提醒过的免费游戏标题数组
export const NOTIFY_KEY: string = 'notifyEnabled'; // “新免费提醒”开关偏好
export const CLAIM_MODE_KEY: string = 'claimAuto';  // 领取方式：true=自动领取 false=跳转领取
export const GRIP_KEY: string = 'gripAdapt';        // 智感握持开关：true=按钮跟随握持手换角
export const FAB_RIGHT_KEY: string = 'fabSideRight'; // 智感握持关闭时手动固定按钮：true=右下角 false=左下角
export const CLAIMED_KEY: string = 'claimedTitles'; // 自动领取已成功入库的游戏标题

// EPIC 登录/领取页地址（自动领取=内置网页模拟用户点“获取”，需保持 EPIC 登录态）
export const CLAIM_LOGIN_URL: string = 'https://accounts.epicgames.com/login';
export const CLAIM_STORE_URL: string = 'https://store.epicgames.com/free-games';

// 通知 ID 与 WorkScheduler 任务 ID（同应用内不与其他任务冲突即可）
export const NOTICE_ID: number = 1001;
export const WORK_ID: number = 201;
// 后台检测 Extension 注册名（必须与 module.json5 extensionAbilities 里的 name 一致）
export const WORK_ABILITY: string = 'EpicCheckWorkAbility';
// 周期任务建议间隔（毫秒）。系统还会按应用活跃分组进一步限制实际触发频率。
export const CHECK_CYCLE_MS: number = 12 * 60 * 60 * 1000;

// ================= 数据模型 =================

// 列表条目：title=游戏名，sub=副标题，img=封面图 URL，claim=官方领取页 URL（空则不可领取），
// startMs=（即将免费按此排序）
export interface GameItem {
  title: string;
  sub: string;
  img: string;
  claim: string;
  startMs: number;
}

export interface FreeLists {
  nowArr: GameItem[];
  soonArr: GameItem[];
}

// 自动领取任务项：t=游戏名，url=官方领取页
export interface ClaimTask {
  t: string;
  url: string;
}

// EPIC 返回 JSON 结构（只声明用到的字段）
interface DiscountSetting {
  discountPercentage: number;
}

interface KeyImage {
  type?: string;
  url?: string;
}

interface PromoOffer {
  startDate: string;
  endDate: string;
  discountSetting?: DiscountSetting;
}

interface PromoGroup {
  promotionalOffers?: PromoOffer[];
}

interface Promotions {
  promotionalOffers?: PromoGroup[];
  upcomingPromotionalOffers?: PromoGroup[];
}

// 商店页地址映射（catalogNs.mappings 里的 productHome slug 可直接拼成 /p/<slug>）
interface NsMapping {
  pageSlug?: string;
  pageType?: string;
}

interface CatalogNs {
  mappings?: NsMapping[];
}

interface ElementItem {
  title?: string;
  offerType?: string;
  promotions?: Promotions;
  keyImages?: KeyImage[];
  catalogNs?: CatalogNs;
}

interface SearchStore {
  elements?: ElementItem[];
}

interface Catalog {
  searchStore?: SearchStore;
}

interface EpicData {
  Catalog?: Catalog;
}

interface EpicResponse {
  data?: EpicData;
}

// 没有产品页映射时的兜底：EPIC 免费游戏专区（已登录状态下列出本期可领取）
const CLAIM_FALLBACK: string = 'https://store.epicgames.com/free-games';
// 封面图类型优先级（横版宣传图优先，其次竖版封面，找不到再退回任意图）
const IMG_PREF: string[] = [
  'DieselStoreFrontWide',
  'OfferImageWide',
  'VaultOpened',
  'DieselGameBoxTall',
  'OfferImageTall',
  'Thumbnail'
];

// ================= 工具函数 =================

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

// 是否算“可领取主体”（排除皮肤/DLC/附加内容）
function isGameType(type?: string): boolean {
  return type === 'BASE_GAME' || type === 'EDITION' || type === 'BUNDLE';
}

// 从 keyImages 里按优先级挑一张适合列表的封面
function pickGameImage(images: KeyImage[] | undefined): string {
  if (!images) {
    return '';
  }
  for (let i = 0; i < IMG_PREF.length; i++) {
    const pref = IMG_PREF[i];
    for (let j = 0; j < images.length; j++) {
      const u = images[j].url;
      if (u && images[j].type === pref) {
        return u;
      }
    }
  }
  // 没有命中优先类型则退回第一张有地址的图
  for (let j = 0; j < images.length; j++) {
    const u = images[j].url;
    if (u) {
      return u;
    }
  }
  return '';
}

// 拼出官方商店领取/详情页地址（登录后点“获取”即入库）
function claimUrlOf(el: ElementItem): string {
  const ns = el.catalogNs;
  if (ns && ns.mappings) {
    for (let i = 0; i < ns.mappings.length; i++) {
      const mp = ns.mappings[i];
      const slug = mp.pageSlug;
      if (slug && mp.pageType === 'productHome') {
        return 'https://store.epicgames.com/p/' + slug;
      }
    }
  }
  return CLAIM_FALLBACK;
}

// 毫秒时间格式化为本地时间 "M-d HH:mm"
function fmtMdHm(ms: number): string {
  if (!isFinite(ms)) {
    return '';
  }
  const d = new Date(ms);
  return (d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' +
    pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

// 从一组促销档位里挑选折扣 100% 的那一档
// wantNow=true 选“正在进行”，false 选“即将开始（最早的）”
function pickFree(groups: PromoGroup[] | undefined, now: number, wantNow: boolean): PromoOffer | null {
  if (!groups) {
    return null;
  }
  let best: PromoOffer | null = null;
  for (const g of groups) {
    const list = g.promotionalOffers;
    if (!list) {
      continue;
    }
    for (const offer of list) {
      const setting = offer.discountSetting;
      if (!setting || setting.discountPercentage !== 0) {
        continue;
      }
      const start: number = Date.parse(offer.startDate);
      const end: number = Date.parse(offer.endDate);
      if (wantNow) {
        // 正在进行的免费领取，选最早结束的
        if (start <= now && end > now) {
          if (best === null || end < Date.parse(best.endDate)) {
            best = offer;
          }
        }
      } else if (start > now) {
        // 即将开始的免费领取，选最早开始的
        if (best === null || start < Date.parse(best.startDate)) {
          best = offer;
        }
      }
    }
  }
  return best;
}

// ================= 抓取与解析 =================

// 请求一次接口；拿到文本 resolve；网络/非 200 一律 reject
export function requestFreeText(): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const req = http.createHttp();
    req.request(
      API_URL + '?locale=' + API_LOCALE + '&country=' + API_COUNTRY + '&allowCountries=' + API_COUNTRY,
      {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 15000,
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

// 解析接口文本，分类出“现在免费”与“即将免费”
// 返回 null 表示数据格式异常（页面应显示失败；后台任务应静默跳过本次）
export function parseFree(text: string): FreeLists | null {
  try {
    const resp: EpicResponse = JSON.parse(text) as EpicResponse;
    const data = resp.data;
    const catalog = data ? data.Catalog : undefined;
    const store = catalog ? catalog.searchStore : undefined;
    const elements = store ? store.elements : undefined;
    if (!elements) {
      return null;
    }

    const nowMs: number = Date.now();
    const nowArr: GameItem[] = [];
    const soonArr: GameItem[] = [];
    for (const el of elements) {
      if (!el.title || !isGameType(el.offerType)) {
        continue;
      }
      const promo = el.promotions;
      if (!promo) {
        continue;
      }
      // 正在免费领取
      const cur = pickFree(promo.promotionalOffers, nowMs, true);
      if (cur) {
        if (nowArr.length < MAX_NOW) {
          const item: GameItem = {
            title: el.title,
            sub: '免费至 ' + fmtMdHm(Date.parse(cur.endDate)),
            img: pickGameImage(el.keyImages),
            claim: claimUrlOf(el),
            startMs: nowMs
          };
          nowArr.push(item);
        }
        continue;
      }
      // 即将开始免费领取
      const up = pickFree(promo.upcomingPromotionalOffers, nowMs, false);
      if (up && soonArr.length < MAX_SOON) {
        const start: number = Date.parse(up.startDate);
        const item: GameItem = {
          title: el.title,
          sub: fmtMdHm(start) + ' 起免费',
          img: pickGameImage(el.keyImages),
          claim: '',
          startMs: start
        };
        soonArr.push(item);
      }
    }
    soonArr.sort((a: GameItem, b: GameItem): number => a.startMs - b.startMs);
    const lists: FreeLists = { nowArr: nowArr, soonArr: soonArr };
    return lists;
  } catch (e) {
    return null;
  }
}

// ================= 已见名单（本地持久化） =================

// 读取“已见免费游戏标题”，异常时返回空数组
export async function readSeen(context: common.Context): Promise<string[]> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(SEEN_KEY, '[]') as string;
    const arr = JSON.parse(raw) as string[];
    return arr instanceof Array ? arr : [];
  } catch (e) {
    return [];
  }
}

// 覆盖写入“已见名单”（拉取成功后调用，避免同一游戏反复提醒）
export async function saveSeen(context: common.Context, list: string[]): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(SEEN_KEY, JSON.stringify(list));
    await p.flush();
  } catch (e) {
    // 存档失败不阻断主流程
  }
}

// 读取“新免费提醒”开关偏好
export async function readNotifyEnabled(context: common.Context): Promise<boolean> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const v = p.getSync(NOTIFY_KEY, false);
    return v === true;
  } catch (e) {
    return false;
  }
}

// 写入“新免费提醒”开关偏好
export async function saveNotifyEnabled(context: common.Context, on: boolean): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(NOTIFY_KEY, on);
    await p.flush();
  } catch (e) {
    // 存档失败不阻断主流程
  }
}

// 读取“领取方式”偏好（true=自动领取，false=跳转领取）
export async function readClaimAuto(context: common.Context): Promise<boolean> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const v = p.getSync(CLAIM_MODE_KEY, false);
    return v === true;
  } catch (e) {
    return false;
  }
}

// 写入“领取方式”偏好
export async function saveClaimAuto(context: common.Context, on: boolean): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(CLAIM_MODE_KEY, on);
    await p.flush();
  } catch (e) {
    // 存档失败不阻断主流程
  }
}

// 读取“智感握持”开关偏好（默认开启：悬浮按钮跟随左右手握持自动换角）
export async function readGripAdapt(context: common.Context): Promise<boolean> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const v = p.getSync(GRIP_KEY, true);
    return v !== false;
  } catch (e) {
    return true;
  }
}

// 写入“智感握持”开关偏好
export async function saveGripAdapt(context: common.Context, on: boolean): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(GRIP_KEY, on);
    await p.flush();
  } catch (e) {
    // 存档失败不阻断主流程
  }
}

// 读取“智感握持”手动固定角偏好（默认右下角，仅智感握持关闭时生效）
export async function readFabRight(context: common.Context): Promise<boolean> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const v = p.getSync(FAB_RIGHT_KEY, true);
    return v !== false;
  } catch (e) {
    return true;
  }
}

// 写入“智感握持”手动固定角偏好
export async function saveFabRight(context: common.Context, right: boolean): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(FAB_RIGHT_KEY, right);
    await p.flush();
  } catch (e) {
    // 存档失败不阻断主流程
  }
}

// 读取“已自动领取成功”的游戏标题数组
export async function readClaimed(context: common.Context): Promise<string[]> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(CLAIMED_KEY, '[]') as string;
    const arr = JSON.parse(raw) as string[];
    return arr instanceof Array ? arr : [];
  } catch (e) {
    return [];
  }
}

// 将若干游戏标记为“已成功领取”（去重后覆盖写入）
export async function markClaimed(context: common.Context, titles: string[]): Promise<void> {
  try {
    const cur: string[] = await readClaimed(context);
    for (let i = 0; i < titles.length; i++) {
      const t: string = titles[i];
      if (t.length > 0 && cur.indexOf(t) < 0) {
        cur.push(t);
      }
    }
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(CLAIMED_KEY, JSON.stringify(cur));
    await p.flush();
  } catch (e) {
    // 存档失败不阻断主流程
  }
}

// ================= 判新与合并 =================

// 本次“现在免费”里、尚未见过的标题（最多取前 5 个）
export function freshTitles(nowArr: GameItem[], seen: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < nowArr.length; i++) {
    if (out.length >= 5) {
      break;
    }
    const t = nowArr[i].title;
    if (t.length > 0 && seen.indexOf(t) < 0 && out.indexOf(t) < 0) {
      out.push(t);
    }
  }
  return out;
}

// 将本次“现在免费”全部并入已见名单（返回新数组）
export function mergeSeen(seen: string[], nowArr: GameItem[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < seen.length; i++) {
    out.push(seen[i]);
  }
  for (let i = 0; i < nowArr.length; i++) {
    const t = nowArr[i].title;
    if (t.length > 0 && out.indexOf(t) < 0) {
      out.push(t);
    }
  }
  return out;
}

// ================= 系统通知 =================

// 发布“EPIC 有新免费游戏”通知。
// requestPermission=true（前台页面调用）：通知未开启时主动请求授权；
// requestPermission=false（后台任务调用）：未开启则静默跳过，避免后台弹窗。
export async function publishFreeNotice(titles: string[], requestPermission: boolean): Promise<void> {
  const enabled: boolean = await notificationManager.isNotificationEnabled();
  if (!enabled) {
    if (!requestPermission) {
      return;
    }
    await notificationManager.requestEnableNotification();
  }
  const req: notificationManager.NotificationRequest = {
    id: NOTICE_ID,
    content: {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: {
        title: 'EPIC 有新免费游戏啦',
        text: '本周新增免费：' + titles.join('、') + '，快去领取',
        additionalText: '打开应用可一键跳转领取'
      }
    }
  };
  await notificationManager.publish(req);
}
