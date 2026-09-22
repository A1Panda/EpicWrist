import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction, router, uiMaterial } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { THEME_FOLLOW, THEME_LIGHT, THEME_DARK, AppPal, appPal, applyModeAndRefreshChrome } from '../common/Theme';
import {
  WORK_ID,
  WORK_ABILITY,
  CHECK_CYCLE_MS,
  REFRESH_GAP_MS,
  GameItem,
  ClaimTask,
  parseFree,
  requestFreeText,
  readSeen,
  saveSeen,
  readNotifyEnabled,
  saveNotifyEnabled,
  readClaimAuto,
  saveClaimAuto,
  readGripAdapt,
  saveGripAdapt,
  readFabRight,
  saveFabRight,
  readClaimed,
  readOwned,
  freshTitles,
  mergeSeen,
  publishFreeNotice,
  readCalOn,
  saveCalOn,
  readGlowLevel,
  saveGlowLevel,
  readLastLists,
  saveLastLists,
  LastLists,
  readLastMobile,
  saveLastMobile,
  addFreeToCalendar
} from '../common/EpicFree';
import { HistItem, recordFreeNow, readHistoryMerged, readHistoryMergedCached, backfillHistCovers, currentMobileFree } from '../common/FreeHistory';
import { appendLog } from '../common/Log';

// ================= 配色（系统沉浸光感适配：近黑冷底 + 官方模糊材质层） =================
// 光效全部走官方方案：设置面板=系统模糊材质（backgroundBlurStyle）、底部栏=系统材质（systemMaterial）；
// 悬浮领取按钮不在沉浸光感生效范围内，改用 backgroundColor+backgroundBlurStyle 模拟玻璃观感；
// 免费/历史等长列表卡片改为不透明纯色底（COLOR_CARD_SOLID），不再逐卡实时模糊与按压点光，避免长列表性能开销。

// 历史页“滑动加载更多”：首次只渲染一页，滑到底部再按此数量追加（避免上千条一次性全部渲染）
const HIST_PAGE: number = 20;
// 缓存新鲜窗口：EPIC 免费档期每周四才更新，6 小时内成功拉取的数据视为“够新”，
// 启动时直接展示缓存不自动联网；只有无缓存或缓存过期才启动自动刷新。
const CACHE_FRESH_MS: number = 6 * 3600 * 1000;
// 历史名单联网刷新的最小间隔：名单每周四才更新一次，回前台不必每次都联网；
// 弱网下这个节流尤其关键——不会每次切回历史页都触发一次联网。
const HIST_REFRESH_GAP_MS: number = 30 * 60 * 1000;
// 免费列表拉取失败后的冷却：弱网/断网时避免每次回前台都重新发起请求（最长十几秒），
// 冷却期内沿用已有缓存/失败态展示；用户点“重试”会手动绕过冷却立刻再试。
const LOAD_FAIL_COOLDOWN_MS: number = 60 * 1000;
// 标题归一化：账号同步回来的标题与历史标题来源不同，写法常有差异
// （如「Down in Bermuda（逃出百慕大）」vs「Down in Bermuda」、全/半角括号、大小写与标点），
// 统一去掉括号补充说明与非字母数字字符后再比对，避免“明明已入库却匹配不上”。
function normTitle(s: string): string {
  let t: string = s.toLowerCase();
  t = t.replace(/[（(][^）)]*[）)]/g, '');
  t = t.replace(/[^a-z0-9\u4e00-\u9fa5]/g, '');
  return t;
}

// ================= “沉浸光效强度”三档（0=柔和 1=标准 2=增强，默认标准） =================
// 档位作用于底部栏的系统材质（style+玻璃着色+触点光）与悬浮按钮的磨砂档位，两者外观保持一致。
// 列表卡片已不使用光效，统一走不透明纯色底以保证长列表性能；数值均取系统材质枚举与官方光效的合法档。
const GLOW_SOFT: number = 0;     // 柔和：轻薄玻璃 + 低亮触点光
const GLOW_NORMAL: number = 1;   // 标准：默认平衡档（保持出厂观感）
const GLOW_STRONG: number = 2;   // 增强：厚重玻璃 + 高亮触点光
// ================= 底部悬浮 TabBar（官方 Tabs 通道）几何 =================
// 结构已从“自绘 Stack 胶囊叠在内容区”改为官方 Tabs(barPosition=End) 悬浮底栏：
// 系统沉浸材质/按压光效只对“底部 TabBar”区域开放，内容区自绘容器永远不会出官方效果。
// 栏体玻璃、触碰发光、按压形变全部交给 barFloatingStyle.systemMaterial，应用不再自绘胶囊容器。
const NAV_W: number = 236;                 // 悬浮栏总宽（原胶囊总宽）
const NAV_H: number = 56;                  // 悬浮栏高（系统默认底栏高 56）
const NAV_BOTTOM_GAP: number = 12;         // 悬浮栏距屏幕底的空隙（手势条距离额外叠加 bottomInset）
const NAV_PILL_W: number = 64;             // 选中高亮块宽（单元格内，不再跨格滑位）
const NAV_PILL_H: number = 38;             // 选中高亮块高

// ================= 历史“按月分组” =================
// 历史列表按开领时刻倒序，天然按“年-月”连续成段；这里负责分组的键/标题，
// 以及把“可见窗口终点”对齐到整月末尾——保证追加加载时不会把某个月份切成两半重复显示标题。

// 历史分组的展示结构：label=月份标题（如 2026年9月），items=该月卡片（保持倒序）
interface HistGroup {
  label: string;
  items: HistItem[];
}

// 分组键：形如 “2026-9”
function histMonthKey(h: HistItem): string {
  const d: Date = new Date(h.startMs);
  return d.getFullYear() + '-' + (d.getMonth() + 1);
}

// 月份标题：形如 “2026年9月”
function histMonthLabel(h: HistItem): string {
  const d: Date = new Date(h.startMs);
  return d.getFullYear() + '年' + (d.getMonth() + 1) + '月';
}

// 把可见条数 target 终点扩展到其所在月份的末尾；target 已是总数则原样返回。
function histAlignMonthEnd(list: HistItem[], target: number): number {
  if (target >= list.length) {
    return list.length;
  }
  const key: string = histMonthKey(list[target - 1]);
  let end: number = target;
  while (end < list.length && histMonthKey(list[end]) === key) {
    end++;
  }
  return end;
}

// ================= 页面 =================

@Entry
@Component
struct Index {
  @State loading: boolean = true;
  @State failed: boolean = false;
  // 静默刷新进行中（已有内容时拉新不遮全屏，仅右上角给“加载中”反馈）
  @State refreshing: boolean = false;
  @State nowList: GameItem[] = [];
  @State soonList: GameItem[] = [];
  // EPIC 送过的免费游戏历史（本地累积 + 第三方补全，最新在前）
  @State histList: HistItem[] = [];
  // 历史页实际渲染的可见子集：始终只保留前若干条，滑到底部再追加（数据总条数见 histList）
  @State histShown: HistItem[] = [];
  @State notifyOn: boolean = false;
  // 自动把“即将免费”加入系统日历：true=拉到新档期就按开领时刻写日程并在开领那一刻提醒
  @State calOn: boolean = false;
  private calSyncing: boolean = false;
  // 领取方式：false=跳转领取（点卡片用系统浏览器打开） true=自动领取（点悬浮按钮批量代领）
  @State claimAuto: boolean = false;
  // 已自动领取成功入库的游戏标题（卡片据此显示“已领取”并跳过重复尝试）
  @State claimedTitles: string[] = [];
  // 从登录的 EPIC 账号「交易→购买」页同步到的“已拥有”标题（与 claimedTitles 一起判定“已入库”）
  @State ownedTitles: string[] = [];
  @State curTab: number = 0;
  // 当前被按住的卡片键（用于克制微动效：按压 0.985 微缩），松手清空
  @State pressedKey: string = '';
  // 外观模式：0=跟随系统 1=固定浅色 2=固定深色（与 common/Theme 保持同一套语义；切换即时全局生效）
  @StorageLink('themeMode') themeMode: number = THEME_FOLLOW;
  @StorageProp('sysDark') sysDark: boolean = false;
  // 智感握持开关：true=悬浮按钮跟随握持手左右换角（默认开启）
  @State gripOn: boolean = true;
  // 关闭智感握持时手动固定的按钮位置：true=右下角，false=左下角
  @State manualRight: boolean = true;
  // 沉浸光效强度档位：0=柔和 1=标准(默认) 2=增强（见顶部 GLOW_* 常量）
  @State glowLevel: number = GLOW_NORMAL;
  // 悬浮按钮所在下角：右手握持默认右下，智感握持检测到左手后自动切到左下
  @State fabAlign: Alignment = Alignment.BottomEnd;
  private holdOn: boolean = false;
  @StorageProp('safeTop') topInset: number = 0;
  @StorageProp('safeBottom') bottomInset: number = 0;
  private inflight: boolean = false;
  private lastLoad: number = 0;
  // 上次免费列表拉取失败时刻：用于失败冷却，避免弱网下每次回前台都重新等一次超时
  private loadFailAt: number = 0;
  // “已入库标题”的归一化集合（claimedTitles + ownedTitles）：isClaimed 一次查表即可，
  // 既避免每次渲染都做 O(n*m) 比对，又能容忍两边来源的写法差异
  private ownedNormSet: Set<string> = new Set<string>();
  private seenFree: string[] = [];
  private prefReady: boolean = false;
  // 上次历史“联网刷新”时刻：回前台/切页按 HIST_REFRESH_GAP_MS 节流，避免弱网下频繁联网
  private histLoadAt: number = 0;
  // 历史联网刷新是否进行中（单飞，避免节流窗口内的并发请求）
  private histNetBusy: boolean = false;
  // 历史列表是否正在后台联网补全：仅在“本地/缓存为空”时用于给占位提示，
  // 避免首次启动（无任何缓存）误显示“还没有历史记录”。
  @State histFetching: boolean = false;
  // 历史页补图是否进行中（只对可见窗口补、单飞，避免并发重复请求）
  private histFillBusy: boolean = false;

  aboutToAppear(): void {
    // 握持手监听在 initState 读完好偏好后再按开关决定是否开启
    this.initState();
  }

  aboutToDisappear(): void {
    this.stopHoldListen();
  }

  // ============ 智感握持：跟随握持手把“开始自动领取”按钮自动落到右下/左下 ============
  // 系统能力在手机边框电容感知握持姿态，本应用无权也无法自己判断；
  // 这里订阅 motion 的握持手事件，LEFT→左下、RIGHT→右下，其余状态保持当前位置避免 UI 抖动。
  private startHoldListen(): void {
    if (this.holdOn) {
      return;
    }
    try {
      motion.on('holdingHandChanged', (data: motion.HoldingHandStatus) => {
        if (data === motion.HoldingHandStatus.LEFT_HAND_HELD) {
          if (this.fabAlign !== Alignment.BottomStart) {
            this.fabAlign = Alignment.BottomStart;
          }
        } else if (data === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
          if (this.fabAlign !== Alignment.BottomEnd) {
            this.fabAlign = Alignment.BottomEnd;
          }
        }
        // NOT_HELD / BOTH_HANDS_HELD / UNKNOWN_STATUS：不改动，沿用当前角
      });
      this.holdOn = true;
    } catch (e) {
      // 系统/设备不支持握持感知或未授予权限：保持默认右下角即可
      this.holdOn = false;
    }
  }

  private stopHoldListen(): void {
    if (!this.holdOn) {
      return;
    }
    try {
      motion.off('holdingHandChanged');
    } catch (e) {
    }
    this.holdOn = false;
  }

  async initState(): Promise<void> {
    // 本次启动读到的缓存存档时刻；-1 表示无可用缓存
    let cacheAt: number = -1;
    try {
      const ctx = getContext(this) as common.Context;
      const seen: string[] = await readSeen(ctx);
      this.seenFree = seen;
      const on: boolean = await readNotifyEnabled(ctx);
      this.notifyOn = on;
      if (on) {
        this.startBgWork();
      }
      const cal: boolean = await readCalOn(ctx);
      this.calOn = cal;
      const auto: boolean = await readClaimAuto(ctx);
      this.claimAuto = auto;
      const grip: boolean = await readGripAdapt(ctx);
      this.gripOn = grip;
      const right: boolean = await readFabRight(ctx);
      this.manualRight = right;
      const gl: number = await readGlowLevel(ctx);
      this.glowLevel = gl;
      const claimed: string[] = await readClaimed(ctx);
      this.claimedTitles = claimed;
      const owned: string[] = await readOwned(ctx);
      this.ownedTitles = owned;
      this.rebuildOwnedSet();
      // 历史“秒开”：只读本地记录 + 已持久化的第三方缓存，完全不联网。
      // 冷启动因此不会被第三方名单下载（弱网下最长可等十几秒）卡住；
      // 联网补全改到 prefReady 之后由后台刷新做，页面先拿缓存把历史铺出来。
      const hist: HistItem[] = await readHistoryMergedCached(ctx);
      this.histList = hist;
      // 首次只展示约一页（终点对齐到整月，月份标题不会被截断），其余滑动到底部按需追加
      this.histShown = hist.slice(0, histAlignMonthEnd(hist, Math.min(HIST_PAGE, hist.length)));
      // 弱网兜底：先读“最近一次成功列表”的本地缓存，有货就先铺出秒开
      const cached: LastLists | null = await readLastLists(ctx);
      if (cached !== null && (cached.nowArr.length > 0 || cached.soonArr.length > 0)) {
        this.nowList = cached.nowArr;
        this.soonList = cached.soonArr;
        this.loading = false;
        cacheAt = cached.at;
      }
    } catch (e) {
    }
    this.prefReady = true;
    // 智感握持关闭时按手动选择落位；开启时保持默认右下，等待握持事件驱动
    if (!this.gripOn && !this.manualRight) {
      this.fabAlign = Alignment.BottomStart;
    }
    if (this.gripOn) {
      this.startHoldListen();
    }
    // 启动联网策略：缓存够新（6 小时内成功拉取）就直接展示、不自动联网——EPIC 每周四才更新，
    // 重启应用无需每次重新加载；只有无缓存或缓存过期才启动静默刷新（弱网失败也不清空列表）。
    if (!this.hasAnyList() || cacheAt < 0 || Date.now() - cacheAt > CACHE_FRESH_MS) {
      this.load();
    }
    // 历史名单后台补全：缓存够新时会被 FreeHistory 内部直接命中，不会真正联网；
    // 缓存过期或首次启动才下载，且失败会进冷却，不阻塞上面的首屏秒开。
    this.refreshHistoryNet();
  }

  onPageShow(): void {
    if (!this.prefReady) {
      return;
    }
    // 页面重新可见（从领取页/浏览器返回）：按开关状态恢复握持手监听
    if (this.gripOn) {
      this.startHoldListen();
    }
    // 从领取页/浏览器返回时刷新“已领取”名单，让卡片状态同步
    this.refreshClaimed();
    this.loadHistory();
    if (Date.now() - this.lastLoad > REFRESH_GAP_MS) {
      this.load();
    }
  }

  onPageHide(): void {
    // 页面被其它页面覆盖/退到后台：停掉握持手监听省电，回到页面时再恢复
    this.stopHoldListen();
  }

  load(manual?: boolean): void {
    if (this.inflight) {
      return;
    }
    // 失败冷却：自动触发（启动/回前台）在冷却期内直接跳过，避免弱网下反复长时间加载；
    // 用户点“重试”传 manual=true 可立刻绕过节流。
    if (!manual && this.loadFailAt > 0 && Date.now() - this.loadFailAt < LOAD_FAIL_COOLDOWN_MS) {
      return;
    }
    this.inflight = true;
    // 已有内容（本地缓存或上次成功结果）时改为“静默刷新”：不遮全屏 Loading、
    // 失败也不清空当前列表，只置 failed 让标题区给出一行状态提示；
    // 只有完全没内容可展示时才进入整页加载转圈。
    if (this.hasAnyList()) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    this.failed = false;
    requestFreeText().then((text: string) => {
      this.fetchMobileAndApply(text);
    }).catch(() => {
      appendLog(getContext(this) as common.Context, '免费列表', 'PC 免费接口请求失败');
      this.inflight = false;
      this.refreshing = false;
      this.loading = false;
      this.failed = true;
      this.loadFailAt = Date.now();
    });
  }

  // PC 免费拉取成功后，再取 Android 手机限免（手机“周免”与 PC 周免是两批不同的游戏）。
  // EPIC 手机接口拦原生 http（Cloudflare 403），改从历史页同源的 josephmate 名单
  // （platform=android 行）取“当前窗口内”的手机限免；名单无进行中条目时读本地缓存兜底。
  private fetchMobileAndApply(text: string): void {
    currentMobileFree(getContext(this) as common.Context).then((mobileArr: GameItem[]) => {
      if (mobileArr.length > 0) {
        appendLog(getContext(this) as common.Context, '手机免费', '历史名单解析到 ' + mobileArr.length + ' 款');
        saveLastMobile(getContext(this) as common.Context, mobileArr);
        this.apply(text, mobileArr);
      } else {
        appendLog(getContext(this) as common.Context, '手机免费', '历史名单无进行中的手机限免，改用本地缓存');
        this.applyCachedMobile(text);
      }
    }).catch(() => {
      appendLog(getContext(this) as common.Context, '手机免费', '历史名单读取失败，改用本地缓存');
      this.applyCachedMobile(text);
    });
  }

  // 本地手机缓存兜底展示（保存自最近一次名单解析成功）
  private applyCachedMobile(text: string): void {
    readLastMobile(getContext(this) as common.Context).then((cached: GameItem[]) => {
      appendLog(getContext(this) as common.Context, '手机免费', '本地缓存 ' + cached.length + ' 款');
      this.apply(text, cached);
    }).catch(() => {
      appendLog(getContext(this) as common.Context, '手机免费', '本地缓存读取失败，仅展示 PC 免费');
      this.apply(text, []);
    });
  }

  apply(text: string, mobileArr: GameItem[]): void {
    const lists = parseFree(text);
    if (lists === null) {
      appendLog(getContext(this) as common.Context, '免费列表', 'PC 接口解析失败');
      this.inflight = false;
      this.refreshing = false;
      this.loading = false;
      this.failed = true;
      this.loadFailAt = Date.now();
      return;
    }
    const pcNowArr: GameItem[] = lists.nowArr;
    const soonArr: GameItem[] = lists.soonArr;
    appendLog(getContext(this) as common.Context, '免费列表', 'PC 现在 ' + pcNowArr.length + ' 款 / 即将 ' + soonArr.length + ' 款 / 手机 ' + mobileArr.length + ' 款');
    // 手机免费游戏并入“现在免费”展示（PC 在前，手机在后；名单无手机限免则仅 PC）
    const nowArr: GameItem[] = pcNowArr.slice(0);
    for (let i = 0; i < mobileArr.length; i++) {
      nowArr.push(mobileArr[i]);
    }
    // 判新通知/已见名单只针对 PC 每周免费，手机免费不参与
    this.checkNewFree(pcNowArr);
    this.nowList = nowArr;
    this.soonList = soonArr;
    this.lastLoad = Date.now();
    // 本次拉取成功：清掉失败冷却，让后续自动/手动刷新恢复正常节奏
    this.loadFailAt = 0;
    this.inflight = false;
    this.refreshing = false;
    this.loading = false;
    // 成功即回写“最近一次成功列表”缓存，供以后弱网/离线时兜底秒开（写失败不影响主流程）
    saveLastLists(getContext(this) as common.Context, nowArr, soonArr);
    // 历史页数据：只把本批 PC“现在免费”并入本地历史（手机免费不入 PC 历史）
    this.recordFreeHistory(pcNowArr);
    // 自动加入日历开启时：新拉到的“即将免费”顺手按开领时刻写成日程并在开领那一刻提醒
    if (this.calOn) {
      this.syncCalToCalendar(true);
    }
  }

  checkNewFree(nowArr: GameItem[]): void {
    if (this.prefReady) {
      const fresh: string[] = freshTitles(nowArr, this.seenFree);
      if (this.notifyOn && fresh.length > 0) {
        publishFreeNotice(fresh, true).catch(() => {
          promptAction.showToast({ message: '新免费游戏已发现，但通知发送失败（可能未授权通知）' });
        });
      }
    }
    const merged: string[] = mergeSeen(this.seenFree, nowArr);
    const changed: boolean = merged.length !== this.seenFree.length;
    this.seenFree = merged;
    if (changed) {
      saveSeen(getContext(this) as common.Context, merged);
    }
  }

  // 该游戏是否已入库：本机自动领取成功，或从登录账号同步到的“已拥有”。
  // 走归一化集合查表，容忍两边标题的写法差异（括号补充说明、标点、大小写）。
  private isClaimed(title: string): boolean {
    const n: string = normTitle(title);
    if (n.length === 0) {
      return false;
    }
    return this.ownedNormSet.has(n);
  }

  // 重建“已入库标题”归一化集合（claimedTitles + ownedTitles 合并去重）
  private rebuildOwnedSet(): void {
    const s: Set<string> = new Set<string>();
    let i: number = 0;
    for (i = 0; i < this.claimedTitles.length; i++) {
      const n: string = normTitle(this.claimedTitles[i]);
      if (n.length > 0) {
        s.add(n);
      }
    }
    for (i = 0; i < this.ownedTitles.length; i++) {
      const n: string = normTitle(this.ownedTitles[i]);
      if (n.length > 0) {
        s.add(n);
      }
    }
    this.ownedNormSet = s;
  }

  // 点击卡片“去领取/自动领取”：按当前领取方式分发
  // 跳转领取 → 系统浏览器打开领取页；自动领取 → 应用内网页会话逐款代领
  // （手机限免与 PC 同为 EPIC 账户领取，一并走自动领取脚本）
  private tapClaim(item: GameItem): void {
    if (this.claimAuto) {
      if (this.isClaimed(item.title)) {
        promptAction.showToast({ message: '该游戏已在库中' });
        return;
      }
      if (item.claim.length === 0) {
        promptAction.showToast({ message: '暂无可用的领取地址' });
        return;
      }
      const one: ClaimTask = { t: item.title, url: item.claim };
      this.pushClaimSession([one]);
      return;
    }
    this.openBrowser(item.claim);
  }

  // 长按“已领取”卡片：强制重新进入自动领取（用于之前被误标为已领取、想重领的情况）
  private forceClaim(item: GameItem): void {
    if (item.claim.length === 0) {
      promptAction.showToast({ message: '暂无可用的领取地址' });
      return;
    }
    const one: ClaimTask = { t: item.title, url: item.claim };
    this.pushClaimSession([one]);
  }
  // 跳转领取：调用系统浏览器打开官方领取页
  private openBrowser(url: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    }).catch(() => {
      promptAction.showToast({ message: '未找到可用浏览器，请手动打开领取页' });
    });
  }

  // 打开设置页里的“EPIC 账户登录”（内置网页登录，登录态保留给自动领取使用）
  private pushClaimLogin(): void {
    router.pushUrl({
      url: 'pages/Claim',
      params: { mode: 'login' }
    }).catch(() => {
      promptAction.showToast({ message: '登录页打开失败，请重试' });
    });
  }

  // 打开“同步已拥有”：用已登录的 Web 会话读取账号「交易 → 购买」页，
  // 结果落盘后返回本页，历史里属于该账号的条目会显示“已领取”
  private pushSyncOwned(): void {
    router.pushUrl({
      url: 'pages/Claim',
      params: { mode: 'sync' }
    }).catch(() => {
      promptAction.showToast({ message: '同步页打开失败，请重试' });
    });
  }

  // 打开设置页里的“运行日志”查看页
  private pushLogs(): void {
    router.pushUrl({
      url: 'pages/Logs'
    }).catch(() => {
      promptAction.showToast({ message: '日志页打开失败，请重试' });
    });
  }

  // 推入自动领取会话页：仅由“开始自动领取”悬浮按钮或卡片“自动领取”按钮手动触发
  private pushClaimSession(tasks: ClaimTask[]): void {
    if (tasks.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/Claim',
      params: { tasks: JSON.stringify(tasks), mode: 'auto' }
    }).catch(() => {
      promptAction.showToast({ message: '领取页打开失败，请重试' });
    });
  }

  // 悬浮按钮“开始自动领取”：把当前所有未领取的免费游戏一次性交给会话页批量代领
  private startAutoClaim(): void {
    const tasks: ClaimTask[] = this.pendingTasks();
    if (tasks.length === 0) {
      promptAction.showToast({ message: '当前没有待领取的免费游戏' });
      return;
    }
    this.pushClaimSession(tasks);
  }

  // 从领取页/系统浏览器/同步页返回时刷新“已领取 + 已拥有”名单，让卡片状态与真实进度同步
  private refreshClaimed(): void {
    const ctx = getContext(this) as common.Context;
    readClaimed(ctx).then((list: string[]) => {
      this.claimedTitles = list;
      this.rebuildOwnedSet();
    }).catch(() => {
    });
    readOwned(ctx).then((list: string[]) => {
      this.ownedTitles = list;
      this.rebuildOwnedSet();
    }).catch(() => {
    });
  }

  // ================= 历史：EPIC 送过的免费游戏 =================

  // 重新读取历史（进入页面/返回前台时调用）：
  // 分两步走——先只用本地 + 已持久化缓存“秒开”（不联网），再按间隔节流地后台联网补全。
  // 这样弱网/断网时历史页不会长时间空窗：有缓存立即有内容，联网慢也不影响已展示的部分。
  private loadHistory(): void {
    const ctx = getContext(this) as common.Context;
    readHistoryMergedCached(ctx).then((list: HistItem[]) => {
      this.applyHistList(list);
    }).catch(() => {
    }).then(() => {
      this.refreshHistoryNet();
    });
  }

  // 后台联网刷新第三方名单并合并历史（按 HIST_REFRESH_GAP_MS 节流、单飞）。
  // 结果有变化才更新已渲染窗口，保留滚动位置；联网失败不改动已展示内容。
  private refreshHistoryNet(): void {
    const now: number = Date.now();
    if (this.histNetBusy || now - this.histLoadAt < HIST_REFRESH_GAP_MS) {
      return;
    }
    this.histNetBusy = true;
    this.histLoadAt = now;
    if (this.histList.length === 0) {
      this.histFetching = true;
    }
    const ctx = getContext(this) as common.Context;
    readHistoryMerged(ctx).then((list: HistItem[]) => {
      this.applyHistList(list);
    }).catch(() => {
    }).then(() => {
      this.histNetBusy = false;
      this.histFetching = false;
    });
  }

  // 把读到的历史列表落到渲染态：内容没变化时不动已渲染窗口（保留滚动位置），
  // 有变化才整体刷新并只渲染首页条数，同时给可见窗口补一次封面。
  private applyHistList(list: HistItem[]): void {
    if (this.sameHist(this.histList, list)) {
      return;
    }
    this.histList = list;
    this.histShown = list.slice(0, histAlignMonthEnd(list, Math.min(HIST_PAGE, list.length)));
    this.fillVisibleHistCovers();
  }

  // 两个历史数组内容是否一致（只比较长度与首尾项，避免回前台时把列表重置到顶部造成跳动）
  private sameHist(a: HistItem[], b: HistItem[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    if (a.length === 0) {
      return true;
    }
    const ha: HistItem = a[0];
    const hb: HistItem = b[0];
    const ta: HistItem = a[a.length - 1];
    const tb: HistItem = b[b.length - 1];
    return ha.t === hb.t && ha.startMs === hb.startMs &&
      ta.t === tb.t && ta.startMs === tb.startMs;
  }

  // 滑到历史列表底部：再追加约一页（终点对齐整月，不会把某月切成两段重复标题；
  // 数据总量见 histList，展示窗口见 histShown）
  private loadMoreHistory(): void {
    if (this.histShown.length >= this.histList.length) {
      return;
    }
    const target: number = Math.min(this.histList.length, this.histShown.length + HIST_PAGE);
    this.histShown = this.histList.slice(0, histAlignMonthEnd(this.histList, target));
    // 窗口变大了：顺手给新进入可见范围的缺图条目补封面
    this.fillVisibleHistCovers();
  }

  // 给历史页“当前可见窗口”里没有封面的条目做运行时两级补图
  // （Steam 商店搜索 → EPIC 兜底，结果进缓存；见 FreeHistory.backfillHistCovers）。
  // 只在进入历史页 / 上滑加载更多时触发；一次进行中则跳过，避免并发重复请求；
  // 补齐后若确有条目变化才重建列表，保持滚动位置与按月分组稳定。
  private fillVisibleHistCovers(): void {
    if (this.histFillBusy) {
      return;
    }
    if (this.curTab !== 1 || this.histShown.length === 0 || this.histList.length === 0) {
      return;
    }
    const base: HistItem[] = this.histList;
    const limit: number = this.histShown.length;
    this.histFillBusy = true;
    const ctx = getContext(this) as common.Context;
    backfillHistCovers(ctx, base, limit).then((list: HistItem[]) => {
      // 等待期间历史被整体重新加载过则放弃本次结果（新列表已自带缓存封面）
      if (this.histList !== base) {
        return;
      }
      // 只比较可见窗口：对象引用变了才认为有封面补齐
      let changed: boolean = false;
      if (list.length === base.length) {
        for (let i = 0; i < limit; i++) {
          if (list[i] !== base[i]) {
            changed = true;
            break;
          }
        }
      }
      if (changed) {
        this.histList = list;
        this.histShown = list.slice(0, limit);
      }
    }).catch(() => {
    }).then(() => {
      this.histFillBusy = false;
    });
  }

  // 深浅色当前有效取色板：由外观模式 + 系统真实明暗共同决定；主题状态变化会触发本页重绘并整体换色
  private pal(): AppPal {
    return appPal(this.themeMode, this.sysDark);
  }

  // 设置页“外观模式”切换：持久化 + 更新 AppStorage（驱动所有页面取色与系统材质重绘）
  private setThemeMode(mode: number): void {
    if (mode === this.themeMode) {
      return;
    }
    applyModeAndRefreshChrome(getContext(this) as common.Context, mode);
  }

  // 设置页当前外观描述
  private themeDesc(): string {
    if (this.themeMode === THEME_LIGHT) {
      return '固定浅色显示';
    }
    if (this.themeMode === THEME_DARK) {
      return '固定深色显示';
    }
    return '跟随系统自动切换明暗';
  }

  // 底部导航切换：立即写状态，让“选中高亮”与“页内容动效”在按下的那一刻就同步起步，
  // 不再等 Tabs 内容滑切动画结束后的 onChange 回调（旧写法会慢一个动画周期，观感是“点完等一下才出来”）。
  // 进入历史页时给可见窗口补一次封面（有 busy 去重，重复调用安全）。
  private switchTab(index: number): void {
    if (this.curTab !== index) {
      this.curTab = index;
    }
    if (index === 1) {
      // 进入历史页：先给可见窗口补封面（有 busy 去重），再按节流窗口后台补一次名单。
      // 二者都不阻塞渲染，历史页先在缓存上秒开。
      this.fillVisibleHistCovers();
      this.refreshHistoryNet();
    }
  }

  // 页内容切换动效（纯属性插值，无需额外定时器）：
  // 每页外层随时按 curTab 计算“静止位”——当前页透明+0 位，非当前页全透明并横向偏离；
  // 切页瞬间 Tabs 换页后，新页从上一帧的静止位(如 +26vp)插值回 0、旧页反向插值离场，
  // 位移方向由 (index-curTab) 决定：从左往右切则新页自右侧滑入，反向切则自左侧滑入。
  private pageAlpha(index: number): number {
    return this.curTab === index ? 1 : 0;
  }

  // 非当前页的横向静止偏离量（vp，按与当前页的间距线性放大，最多 52vp 避免跳跃感）
  private pageOffsetX(index: number): number {
    if (this.curTab === index) {
      return 0;
    }
    const dist: number = index - this.curTab;
    const step: number = 26;
    if (dist > 0) {
      return Math.min(dist, 2) * step;
    }
    return Math.max(dist, -2) * step;
  }

  // ============ 页面内元素“自顶向下”级联入场（淡入 + 轻微上浮） ============
  // 每页内按视觉顺序给元素编号 rank：0=页头 1..N=依次往下的小标题/卡片/设置行。
  // 元素常驻渲染，opacity/y 只按“当前是否在本页”取值；切进本页瞬间各元素从静止位
  // 依次插值回原位，动画 delay=rank×38ms，形成自上而下的入场波次；切走时 delay=0
  // 快速淡出，跟随整页退场不拖尾。所有属性变化都走官方 .animation，无自绘光效。
  private entOpacity(page: number): number {
    return this.curTab === page ? 1 : 0;
  }

  // 静止位：非当前页元素整体下移 18vp（恰好移出后即不可见），入场时上浮归位
  private entRise(page: number): number {
    return this.curTab === page ? 0 : 18;
  }

  // 级联动画参数：进入=延时逐级递增；离开=不延时快速淡出。rank 封顶在 6、步长 24ms，
  // 长列表尾部不再无限加长，最多约 144ms 后整体入场完毕（旧版封顶 8×38≈304ms，是“内容要等一下”的主因之一）。
  private entAnim(page: number, rank: number): AnimateParam {
    if (this.curTab !== page) {
      const out: AnimateParam = { duration: 120, curve: Curve.EaseIn };
      return out;
    }
    const d: number = Math.min(rank, 6) * 24;
    const inn: AnimateParam = { duration: 260, curve: Curve.FastOutSlowIn, delay: d };
    return inn;
  }

  // 卡片按压微缩放：按住 key 匹配时 0.985，其余 1（克制，不位移不改布局）
  private pressScale(key: string): number {
    return this.pressedKey === key ? 0.985 : 1;
  }

  // 设置页切换“沉浸光效强度”档位：写偏好 → 更新状态（build 重算三处系统材质参数）
  private setGlow(level: number): void {
    if (level === this.glowLevel) {
      return;
    }
    this.glowLevel = level;
    try {
      saveGlowLevel(getContext(this) as common.Context, level).catch(() => {
      });
    } catch (e) {
    }
  }

  // 设置页档位副文案：说明当前档位的光感侧重点
  private glowDesc(): string {
    if (this.glowLevel === GLOW_SOFT) {
      return '轻薄玻璃，触点光柔和';
    }
    if (this.glowLevel === GLOW_STRONG) {
      return '厚重玻璃，触点光明亮';
    }
    return '平衡的玻璃厚度与触点光（默认）';
  }

  // 悬浮领取按钮的玻璃观感：目标是与底部工具栏的官方材质外观保持一致——中性磨砂玻璃，不做额外着色
  // （底栏材质未设 materialColor，即系统默认中性玻璃）。该按钮位于内容区、超出官方沉浸光感生效范围
  // （官方仅对 Navigation/NavDestination 标题栏与底部 TabBar 开放，其它区域设置 systemMaterial 恒不生效，
  // 日志：Material inactive: out of scope），故按官方建议用通用属性模拟。
  private fabGlassColor(): string {
    return this.pal().COLOR_CARD;
  }

  // 悬浮按钮磨砂档位：与底部工具栏材质 style 一一对齐（柔和/标准=THIN、增强=REGULAR），观感保持一致。
  private fabGlassBlur(): BlurStyle {
    return this.glowLevel === GLOW_STRONG ? BlurStyle.Regular : BlurStyle.Thin;
  }

  // 底部悬浮 TabBar 的系统材质：标准=THIN 保持出厂通透观感，柔和再降触点光亮度，
  // 增强升到 REGULAR 让玻璃更实、光效层次更明显。
  private tabMaterial(): uiMaterial.ImmersiveMaterial {
    if (this.glowLevel === GLOW_SOFT) {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        interactive: true,
        lightEffect: { color: '#59FFFFFF' }
      });
    }
    if (this.glowLevel === GLOW_STRONG) {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        interactive: true,
        lightEffect: { color: '#FFFFFF' }
      });
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      interactive: true,
      lightEffect: { color: '#FFFFFF' }
    });
  }

  // 悬浮 TabBar 悬浮在内容区之上：滚动内容需能滚入其下，底部预留
  // “手势条 + 栏底空隙 + 栏高 + 呼吸间隙”，让最后一项能滚出栏的可视区。
  private overlayReserve(): number {
    return this.getUIContext().px2vp(this.bottomInset) + NAV_BOTTOM_GAP + NAV_H + 14;
  }

  // 自动领取悬浮按钮抬起到底部悬浮 TabBar 上方的底边距
  private fabLiftPad(): number {
    return this.getUIContext().px2vp(this.bottomInset) + NAV_BOTTOM_GAP + NAV_H + 10;
  }

  // 悬浮 TabBar 的栏底空隙（barFloatingStyle.barBottomMargin，vp）
  private barBottomPad(): number {
    return this.getUIContext().px2vp(this.bottomInset) + NAV_BOTTOM_GAP;
  }

  // 把 histShown 按“年月”聚合成展示分组（histShown 的终点始终对齐整月，
  // 因此同一月份的所有条目必然在同一个分组里，不会出现半个月份标题）
  private histGroups(): HistGroup[] {
    const groups: HistGroup[] = [];
    let lastKey: string = '';
    let cur: HistGroup = { label: '', items: [] };
    for (let i = 0; i < this.histShown.length; i++) {
      const it: HistItem = this.histShown[i];
      const key: string = histMonthKey(it);
      if (groups.length === 0 || key !== lastKey) {
        cur = { label: histMonthLabel(it), items: [] };
        groups.push(cur);
        lastKey = key;
      }
      cur.items.push(it);
    }
    return groups;
  }

  // 把本批“现在免费”并入本地历史，随后刷新页面数据（静默，失败不影响主流程）
  private recordFreeHistory(nowArr: GameItem[]): void {
    if (nowArr.length === 0) {
      return;
    }
    const ctx = getContext(this) as common.Context;
    recordFreeNow(ctx, nowArr).then((added: number) => {
      if (added > 0) {
        this.loadHistory();
      }
    }).catch(() => {
    });
  }

  // 历史条目状态文案（已领取 > 仍在免费 > 已结束）
  private histStatus(h: HistItem): string {
    if (this.isClaimed(h.t)) {
      return '已领取';
    }
    if (h.endMs > Date.now()) {
      return '免费中';
    }
    return '已结束';
  }

  // 历史条目状态颜色
  private histColor(h: HistItem): string {
    if (this.isClaimed(h.t)) {
      return this.pal().COLOR_OK;
    }
    if (h.endMs > Date.now()) {
      return this.pal().COLOR_ACCENT;
    }
    return this.pal().COLOR_SUB;
  }

  // 历史条目展示区间：同一年只显 M月d日，跨年份前缀年份避免歧义
  private histRange(h: HistItem): string {
    const s = new Date(h.startMs);
    const e = new Date(h.endMs);
    const head: string = s.getFullYear() !== new Date().getFullYear() ?
      s.getFullYear() + '年' : '';
    return head + (s.getMonth() + 1) + '月' + s.getDate() + '日 – ' +
      (e.getMonth() + 1) + '月' + e.getDate() + '日';
  }

  // 点击历史卡片：已领取→重新进入官方游戏页浏览；未领取且仍在免费→走领取流程；其余跳官方页面
  private tapHist(h: HistItem): void {
    if (h.url.length === 0) {
      promptAction.showToast({ message: '暂无可用的游戏页面' });
      return;
    }
    if (this.isClaimed(h.t)) {
      this.openBrowser(h.url);
      return;
    }
    if (h.endMs > Date.now() && this.claimAuto) {
      // 还在免费期且处于自动领取模式：直接交给自动领取会话
      const one: ClaimTask = { t: h.t, url: h.url };
      this.pushClaimSession([one]);
      return;
    }
    this.openBrowser(h.url);
  }

  // 收集“现在免费”中尚未领取成功的免费游戏，作为批量领取任务（手机限免同样参与）
  private pendingTasks(): ClaimTask[] {
    const tasks: ClaimTask[] = [];
    for (let i = 0; i < this.nowList.length; i++) {
      const it: GameItem = this.nowList[i];
      if (it.claim.length === 0 || this.isClaimed(it.title)) {
        continue;
      }
      const task: ClaimTask = { t: it.title, url: it.claim };
      tasks.push(task);
    }
    return tasks;
  }

  private makeWork(): workScheduler.WorkInfo {
    const ctx = getContext(this) as common.UIAbilityContext;
    const info: workScheduler.WorkInfo = {
      workId: WORK_ID,
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: WORK_ABILITY,
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isPersisted: true,
      isRepeat: true,
      repeatCycleTime: CHECK_CYCLE_MS
    };
    return info;
  }

  private startBgWork(): void {
    try {
      workScheduler.startWork(this.makeWork());
    } catch (e) {
    }
  }

  private async hasBgWork(): Promise<boolean> {
    try {
      const all: workScheduler.WorkInfo[] = await workScheduler.obtainAllWorks();
      for (let i = 0; i < all.length; i++) {
        if (all[i].workId === WORK_ID) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  private async ensureBgWork(): Promise<boolean> {
    this.startBgWork();
    if (await this.hasBgWork()) {
      return true;
    }
    try {
      workScheduler.startWork(this.makeWork());
      return true;
    } catch (e) {
      return false;
    }
  }

  private cancelBgWork(): void {
    try {
      workScheduler.stopWork(this.makeWork(), true);
    } catch (e) {
    }
  }

  async setNotify(on: boolean): Promise<void> {
    if (on) {
      let enabled: boolean = false;
      try {
        enabled = await notificationManager.isNotificationEnabled();
        if (!enabled) {
          await notificationManager.requestEnableNotification();
          enabled = await notificationManager.isNotificationEnabled();
        }
      } catch (e) {
        enabled = false;
      }
      if (!enabled) {
        this.notifyOn = false;
        promptAction.showToast({ message: '需允许通知才能开启后台提醒' });
        return;
      }
      const ok: boolean = await this.ensureBgWork();
      if (!ok) {
        this.notifyOn = false;
        promptAction.showToast({ message: '后台提醒开启失败，请稍后重试' });
        return;
      }
      this.notifyOn = true;
    } else {
      this.cancelBgWork();
      this.notifyOn = false;
    }
    saveNotifyEnabled(getContext(this) as common.Context, this.notifyOn);
  }

  // 切换领取方式并持久化（只改变交互入口形态，不自动发起领取）
  async setClaimMode(auto: boolean): Promise<void> {
    if (this.claimAuto === auto) {
      return;
    }
    this.claimAuto = auto;
    saveClaimAuto(getContext(this) as common.Context, auto);
    if (auto) {
      promptAction.showToast({ message: '已开启自动领取：回到游戏页点悬浮按钮开始' });
    } else {
      promptAction.showToast({ message: '已切换为跳转领取：点击卡片用浏览器打开' });
    }
  }

  // 切换“智感握持”开关并持久化：开→订阅握持手事件，关→停止订阅并按手动位置落位
  async setGrip(on: boolean): Promise<void> {
    if (this.gripOn === on) {
      return;
    }
    this.gripOn = on;
    saveGripAdapt(getContext(this) as common.Context, on);
    if (on) {
      this.startHoldListen();
      promptAction.showToast({ message: '已开启智感握持：按钮自动跟随握持手换角' });
    } else {
      this.stopHoldListen();
      const target: Alignment = this.manualRight ? Alignment.BottomEnd : Alignment.BottomStart;
      if (this.fabAlign !== target) {
        this.fabAlign = target;
      }
      promptAction.showToast({ message: '已关闭智感握持：按钮位置可手动选择' });
    }
  }

  // 手动固定按钮位置（智感握持关闭时生效），并持久化
  async setFabSide(right: boolean): Promise<void> {
    if (this.manualRight === right) {
      return;
    }
    this.manualRight = right;
    saveFabRight(getContext(this) as common.Context, right);
    if (!this.gripOn) {
      const target: Alignment = right ? Alignment.BottomEnd : Alignment.BottomStart;
      if (this.fabAlign !== target) {
        this.fabAlign = target;
      }
    }
  }

  // ================= 自动加入系统日历 =================

  // 请求日历读写权限；全部授权才算成功（用户拒绝则保持开关关闭）
  private async requestCalPerms(): Promise<boolean> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const need: Permissions[] = [
        'ohos.permission.WRITE_CALENDAR',
        'ohos.permission.READ_CALENDAR'
      ];
      const result = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(ctx, need);
      const rs: number[] = result.authResults;
      for (let i = 0; i < rs.length; i++) {
        if (rs[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // 设置页开关：开启前先申请日历权限，关闭则只停后续写入（已建日程保留）
  async setCal(on: boolean): Promise<void> {
    if (on) {
      const granted: boolean = await this.requestCalPerms();
      if (!granted) {
        this.calOn = false;
        promptAction.showToast({ message: '需允许读写日历才能自动加入日程' });
        return;
      }
      this.calOn = true;
      saveCalOn(getContext(this) as common.Context, true);
      promptAction.showToast({ message: '已开启：按开领时刻写入日历，到点提醒' });
      // 若已拉到过“即将免费”，立刻补写一次并提示数量
      this.syncCalToCalendar(true);
    } else {
      this.calOn = false;
      saveCalOn(getContext(this) as common.Context, false);
      promptAction.showToast({ message: '已关闭：不再自动把免费游戏加入日历' });
    }
  }

  // 把“即将免费”写入系统日历。tip=false（后台刷新自动触发）不弹提示；
  // tip=true（用户刚开启开关）提示本次新增条数。
  private async syncCalToCalendar(tip: boolean): Promise<void> {
    if (!this.calOn || this.calSyncing || this.soonList.length === 0) {
      return;
    }
    this.calSyncing = true;
    try {
      const ctx = getContext(this) as common.Context;
      const copy: GameItem[] = [];
      for (let i = 0; i < this.soonList.length; i++) {
        copy.push(this.soonList[i]);
      }
      const added: number = await addFreeToCalendar(ctx, copy);
      if (tip && added > 0) {
        promptAction.showToast({ message: '已将 ' + added + ' 个即将免费的游戏加入日历' });
      }
    } catch (e) {
      // 权限被收回/系统日历异常：静默跳过，等下次刷新再试
    }
    this.calSyncing = false;
  }

  // ================= 首页头部 =================

  // 当前是否还有可展示的列表内容（本地缓存或上次成功结果）
  private hasAnyList(): boolean {
    return this.nowList.length > 0 || this.soonList.length > 0;
  }

  // 刷新失败但内容仍在：标题区副标题换一行状态提示（文案等长换色，不增加元素、不挤动布局）
  private showStale(): boolean {
    return this.failed && this.hasAnyList();
  }

  @Builder
  Header() {
    Row() {
      Column({ space: 3 }) {
        Text('每周免费游戏')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text(this.showStale() ? '网络异常 · 展示上次内容' : 'EPIC 商店 · 每周更新')
          .fontSize(12)
          .fontColor(this.showStale() ? this.pal().COLOR_STALE : this.pal().COLOR_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      if (this.loading || this.refreshing) {
        // 拉取进行中（整页加载或右上角静默刷新）：给出一致的小转圈反馈，避免点了“没反应”
        Row({ space: 5 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(this.pal().COLOR_ACCENT)
          Text('加载中')
            .fontSize(14)
            .fontColor(this.pal().COLOR_SUB)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      } else {
        Text(this.failed ? '重试' : '刷新')
          .fontSize(14)
          .fontColor(this.pal().COLOR_ACCENT)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            // 手动触发：绕过失败冷却，立刻再试一次
            this.load(true);
          })
      }
    }
    .width('100%')
    .padding({
      left: 16,
      right: 8,
      // topInset 是 px，必须先转 vp；顶部时间栏/挖孔仍显示，标题在其下方避让
      top: this.getUIContext().px2vp(this.topInset) + 10,
      bottom: 10
    })
    .opacity(this.entOpacity(0))
    .translate({ y: this.entRise(0) })
    .animation(this.entAnim(0, 0))
  }

  // ================= 加载 / 结果提示 =================

  @Builder
  LoadingView() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(46)
        .height(46)
        .color(this.pal().COLOR_ACCENT)
      Text('获取免费游戏列表中…')
        .fontSize(14)
        .fontColor(this.pal().COLOR_SUB)
    }
    .width('100%')
    .padding({ top: 140, bottom: 140 })
    .justifyContent(FlexAlign.Center)
    .opacity(this.entOpacity(0))
    .translate({ y: this.entRise(0) })
    .animation(this.entAnim(0, 1))
  }

  @Builder
  TipView(main: string, sub: string) {
    Column({ space: 10 }) {
      Text(main)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().COLOR_TEXT)
      Text(sub)
        .fontSize(13)
        .fontColor(this.pal().COLOR_SUB)
      Text('点击重试')
        .fontSize(13)
        .fontColor(this.pal().COLOR_ACCENT)
        .margin({ top: 6 })
    }
    .width('100%')
    .padding({ top: 140, bottom: 140 })
    .justifyContent(FlexAlign.Center)
    .opacity(this.entOpacity(0))
    .translate({ y: this.entRise(0) })
    .animation(this.entAnim(0, 1))
    .onClick(() => {
      // 手动触发：绕过失败冷却，立刻再试一次
      this.load(true);
    })
  }

  // ================= 游戏列表 =================

  @Builder
  GameCard(item: GameItem, rank: number) {
    Stack() {
      Row() {
        if (item.img.length > 0) {
          Image(item.img)
            .width(100)
            .height(62)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.pal().COLOR_IMG_BG)
            .margin({ right: 12 })
        }

        Column({ space: 4 }) {
          Text(item.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().COLOR_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.sub)
            .fontSize(12)
            .lineHeight(17)
            .fontColor(this.pal().COLOR_SUB)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (item.claim.length > 0) {
          if (this.claimAuto && this.isClaimed(item.title)) {
            // 自动领取模式下已入库：灰底标记，点击重新进入游戏页浏览，长按强制重新领取
            Text('已领取')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().COLOR_SUB)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(this.pal().COLOR_BADGE)
              .borderRadius(16)
              .margin({ left: 10 })
              .onClick(() => {
                this.openBrowser(item.claim);
              })
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction(() => {
                    this.forceClaim(item);
                  })
              )
          } else {
            // 按领取方式显示：跳转=去领取（浏览器），自动=自动领取（应用内脚本）
            Text(this.claimAuto ? '自动领取' : '去领取')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(this.pal().COLOR_ACCENT)
              .borderRadius(16)
              .margin({ left: 10 })
              .onClick(() => {
                this.tapClaim(item);
              })
          }
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(this.pal().COLOR_CARD_SOLID)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .clip(true)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedKey = item.title;
      } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === item.title) {
        this.pressedKey = '';
      }
    })
    .scale({ x: this.pressScale(item.title), y: this.pressScale(item.title) })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    // 级联入场段：与按压微缩的动画分组独立，互不覆盖
    .opacity(this.entOpacity(0))
    .translate({ y: this.entRise(0) })
    .animation(this.entAnim(0, rank))
  }

  @Builder
  ListPanel() {
    Scroll() {
      Column({ space: 24 }) {
        if (this.nowList.length > 0) {
          Column({ space: 10 }) {
            Text('现在免费')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().COLOR_TEXT)
              .opacity(this.entOpacity(0))
              .translate({ y: this.entRise(0) })
              .animation(this.entAnim(0, 1))
            ForEach(this.nowList, (item: GameItem, idx: number) => {
              this.GameCard(item, 2 + idx)
            }, (item: GameItem) => item.title + item.sub)
          }
          .width('100%')
        }

        if (this.soonList.length > 0) {
          Column({ space: 10 }) {
            Text('即将免费')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().COLOR_TEXT)
              .opacity(this.entOpacity(0))
              .translate({ y: this.entRise(0) })
              .animation(this.entAnim(0, this.nowList.length > 0 ? this.nowList.length + 2 : 1))
            ForEach(this.soonList, (item: GameItem, idx: number) => {
              this.GameCard(item, (this.nowList.length > 0 ? this.nowList.length + 3 : 2) + idx)
            }, (item: GameItem) => item.title + item.sub)
          }
          .width('100%')
        }
      }
      .width('100%')
      // 悬浮胶囊与圆形领取按钮盖在内容上：滚动区底部预留两者高度，让最后一项能滚出按钮
      .padding({ left: 16, right: 16, top: 2, bottom: this.claimAuto ? (this.fabLiftPad() + 66) : this.overlayReserve() })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  Content() {
    // 只要已有内容（本地缓存/上次成功结果）就先展示列表，弱网刷新失败也不清空、不遮全屏；
    // 完全没内容时才退回整页加载 / 失败 / 空态。
    if (!this.hasAnyList()) {
      if (this.loading) {
        this.LoadingView()
      } else if (this.failed) {
        this.TipView('获取失败', '请检查网络连接后重试')
      } else {
        this.TipView('暂无可领免费游戏', '可能本周活动已结束，可稍后再来看看')
      }
    } else {
      this.ListPanel()
    }
  }

  // ================= 历史页 =================

  @Builder
  HistoryHeader() {
    Row() {
      Column({ space: 3 }) {
        Text('历史')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text('EPIC 送过的免费游戏 · 共 ' + this.histList.length + ' 期' +
          (this.ownedTitles.length > 0 ? ' · 已同步 ' + this.ownedTitles.length + ' 条' : ''))
          .fontSize(12)
          .fontColor(this.pal().COLOR_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 从登录的 EPIC 账号同步“已拥有”游戏：同步后历史里已入库的条目会显示“已领取”
      Text('同步已拥有')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().COLOR_ACCENT)
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor(this.pal().COLOR_BADGE)
        .borderRadius(15)
        .margin({ left: 10 })
        .onClick(() => {
          this.pushSyncOwned();
        })
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.getUIContext().px2vp(this.topInset) + 10,
      bottom: 8
    })
    .opacity(this.entOpacity(1))
    .translate({ y: this.entRise(1) })
    .animation(this.entAnim(1, 0))
  }

  // 历史单卡：右侧状态用“色字”区分（绿=已领取 蓝=免费中 灰=已结束），不做跳动的标签布局
  @Builder
  HistoryCard(h: HistItem, rank: number) {
    Stack() {
      Row() {
        if (h.img.length > 0) {
          Image(h.img)
            .width(100)
            .height(62)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.pal().COLOR_IMG_BG)
            .margin({ right: 12 })
        } else {
          // 第三方历史源不提供封面图：显示“标题首字母”占位块，保证卡片版式与本地记录一致
          Column() {
            Text(h.t.length > 0 ? h.t.charAt(0).toUpperCase() : '?')
              .fontSize(24)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().COLOR_IMG_FG)
          }
          .width(100)
          .height(62)
          .borderRadius(10)
          .backgroundColor(this.pal().COLOR_IMG_BG)
          .justifyContent(FlexAlign.Center)
          .margin({ right: 12 })
        }

        Column({ space: 4 }) {
          Row() {
            Text(h.t)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().COLOR_TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.histStatus(h))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.histColor(h))
              .margin({ left: 10 })
          }
          .width('100%')

          Text(this.histRange(h))
            .fontSize(12)
            .fontColor(this.pal().COLOR_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(this.pal().COLOR_CARD_SOLID)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .clip(true)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedKey = h.t;
      } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === h.t) {
        this.pressedKey = '';
      }
    })
    .scale({ x: this.pressScale(h.t), y: this.pressScale(h.t) })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      this.tapHist(h);
    })
    // 级联入场段：与按压微缩的动画分组独立，互不覆盖
    .opacity(this.entOpacity(1))
    .translate({ y: this.entRise(1) })
    .animation(this.entAnim(1, rank))
  }

  @Builder
  HistoryView() {
    if (this.histList.length === 0) {
      // 本地/缓存为空且正在后台补全名单：给“同步中”占位，不误报“还没有历史记录”
      if (this.histFetching) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color(this.pal().COLOR_ACCENT)
          Text('正在同步历史…')
            .fontSize(13)
            .fontColor(this.pal().COLOR_SUB)
        }
        .width('100%')
        .padding({ top: 140, bottom: 140 })
        .justifyContent(FlexAlign.Center)
        .opacity(this.entOpacity(1))
        .translate({ y: this.entRise(1) })
        .animation(this.entAnim(1, 1))
      } else {
        Column({ space: 10 }) {
          Text('还没有历史记录')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().COLOR_TEXT)
          Text('本应用检测到的每期免费游戏会自动记录在这里')
            .fontSize(13)
            .fontColor(this.pal().COLOR_SUB)
        }
        .width('100%')
        .padding({ top: 140, bottom: 140 })
        .justifyContent(FlexAlign.Center)
        .opacity(this.entOpacity(1))
        .translate({ y: this.entRise(1) })
        .animation(this.entAnim(1, 1))
      }
    } else {
      Scroll() {
        Column({ space: 12 }) {
          // 按月分组：每组 = 月份小标题 + 该月全部卡片（分组整体原子追加）
          ForEach(this.histGroups(), (g: HistGroup, gi: number) => {
            Column({ space: 10 }) {
              Text(g.label)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.pal().COLOR_SUB)
                .width('100%')
                .opacity(this.entOpacity(1))
                .translate({ y: this.entRise(1) })
                .animation(this.entAnim(1, gi * 2 + 1))
              ForEach(g.items, (h: HistItem, ci: number) => {
                this.HistoryCard(h, gi * 2 + 2 + ci)
              }, (h: HistItem) => h.t + h.seenMs)
            }
            .width('100%')
          }, (g: HistGroup) => g.label)
          // 还有更多未展示时给出提示；滑到此处触发 onReachEnd 追加下一页
          if (this.histShown.length < this.histList.length) {
            Text('上滑加载更多 · 已显示 ' + this.histShown.length + ' / ' + this.histList.length)
              .fontSize(12)
              .fontColor(this.pal().COLOR_SUB)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 10 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 2, bottom: this.overlayReserve() })
      }
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .width('100%')
      .layoutWeight(1)
      .onReachEnd(() => {
        this.loadMoreHistory();
      })
    }
  }

  // ================= 设置页 =================

  @Builder
  SettingsHeader() {
    Column({ space: 3 }) {
      Text('设置')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().COLOR_TEXT)
      Text('管理提醒与领取偏好')
        .fontSize(12)
        .fontColor(this.pal().COLOR_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.getUIContext().px2vp(this.topInset) + 10,
      bottom: 4
    })
    .opacity(this.entOpacity(2))
    .translate({ y: this.entRise(2) })
    .animation(this.entAnim(2, 0))
  }

  // 设置页分组小标题：与“历史页月份标题”同风格（13sp 次要色），把同类设置归成一组
  @Builder
  SettingsGroupTitle(title: string, top: number) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.pal().COLOR_SUB)
      .width('100%')
      .padding({ top: top, bottom: 8 })
  }

  @Builder
  NotifyRow() {
    Row() {
      Column({ space: 4 }) {
        Text('新免费提醒')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text('发现新的免费游戏时推送通知')
          .fontSize(12)
          .fontColor(this.pal().COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.notifyOn })
        .selectedColor(this.pal().COLOR_ACCENT)
        .onChange((isOn: boolean) => {
          this.setNotify(isOn);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedKey = 'SetNotify';
      } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === 'SetNotify') {
        this.pressedKey = '';
      }
    })
    .scale({ x: this.pressScale('SetNotify'), y: this.pressScale('SetNotify') })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
  }

  // “自动加入日历”开关行：把“即将免费”按开领时刻写进系统日历，到点提醒
  @Builder
  CalRow() {
    Row() {
      Column({ space: 4 }) {
        Text('加入日历提醒')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text('按“即将免费”的开领时刻写日程，到点才提醒')
          .fontSize(12)
          .fontColor(this.pal().COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.calOn })
        .selectedColor(this.pal().COLOR_ACCENT)
        .onChange((isOn: boolean) => {
          this.setCal(isOn);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedKey = 'SetCal';
      } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === 'SetCal') {
        this.pressedKey = '';
      }
    })
    .scale({ x: this.pressScale('SetCal'), y: this.pressScale('SetCal') })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
  }

  // 智感握持开关行里的“位置分段”单项（manualRight 选中态由 @Builder 外层传入 right 判断）
  @Builder
  FabSideSegment(label: string, right: boolean) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.manualRight === right ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.manualRight === right ? '#FFFFFF' : this.pal().COLOR_SUB)
      .textAlign(TextAlign.Center)
      .width('50%')
      .height('100%')
      .backgroundColor(this.manualRight === right ? this.pal().COLOR_ACCENT : Color.Transparent)
      .borderRadius(8)
      .onClick(() => {
        this.setFabSide(right);
      })
  }

  // 智感握持：开启=跟随左右手握持自动换角；关闭=显示手动位置选择
  @Builder
  GripRow() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('智感握持')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().COLOR_TEXT)
          Text(this.gripOn ? '“开始自动领取”按钮自动跟随左右手握持换角' : '已关闭自动跟随：手动选择按钮固定位置')
            .fontSize(12)
            .fontColor(this.pal().COLOR_SUB)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.gripOn })
          .selectedColor(this.pal().COLOR_ACCENT)
          .onChange((isOn: boolean) => {
            this.setGrip(isOn);
          })
      }
      .width('100%')

      // 智感握持关闭时：手动固定右下角 / 左下角
      if (!this.gripOn) {
        Row() {
          this.FabSideSegment('右下角', true)
          this.FabSideSegment('左下角', false)
        }
        .width('100%')
        .height(38)
        .padding(3)
        .backgroundColor(this.pal().COLOR_TRACK)
        .borderRadius(10)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedKey = 'SetGrip';
      } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === 'SetGrip') {
        this.pressedKey = '';
      }
    })
    .scale({ x: this.pressScale('SetGrip'), y: this.pressScale('SetGrip') })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
  }

  // 设置页：领取方式切换段。mode=false=跳转领取，true=自动领取
  @Builder
  ModeSegment(label: string, mode: boolean) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.claimAuto === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.claimAuto === mode ? '#FFFFFF' : this.pal().COLOR_SUB)
      .textAlign(TextAlign.Center)
      .width('50%')
      .height('100%')
      .backgroundColor(this.claimAuto === mode ? this.pal().COLOR_ACCENT : Color.Transparent)
      .borderRadius(8)
      .onClick(() => {
        this.setClaimMode(mode);
      })
  }

  @Builder
  ClaimModeCard() {
    Column({ space: 12 }) {
      // 当前领取方式说明（方式名称已由分组标题给出，这里只描述对应行为）
      Text(this.claimAuto ? '开启后回到游戏页，点悬浮按钮批量代领' : '点击卡片用系统浏览器打开领取页')
        .fontSize(12)
        .fontColor(this.pal().COLOR_SUB)
        .width('100%')

      // 跳转领取 / 自动领取 二选一切换
      Row() {
        this.ModeSegment('跳转领取', false)
        this.ModeSegment('自动领取', true)
      }
      .width('100%')
      .height(38)
      .padding(3)
      .backgroundColor(this.pal().COLOR_TRACK)
      .borderRadius(10)

      if (this.claimAuto) {
        // 自动领取依赖应用内登录态：提供一个内置网页登录入口
        Row() {
          Column({ space: 4 }) {
            Text('EPIC 账户登录')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().COLOR_TEXT)
            Text('自动领取需在应用内登录一次，登录态会保留')
              .fontSize(12)
              .fontColor(this.pal().COLOR_SUB)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('去登录')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().COLOR_ACCENT)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.pressedKey = 'SetLogin';
          } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === 'SetLogin') {
            this.pressedKey = '';
          }
        })
        .scale({ x: this.pressScale('SetLogin'), y: this.pressScale('SetLogin') })
        .animation({ duration: 160, curve: Curve.FastOutSlowIn })
        .onClick(() => {
          this.pushClaimLogin();
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  // 设置页“运行日志”入口行：打开日志查看页，可复制全部日志发给开发者调试
  @Builder
  LogRow() {
    Row() {
      Column({ space: 4 }) {
        Text('运行日志')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text('查看领取与列表抓取的运行记录，可复制发给开发者')
          .fontSize(12)
          .fontColor(this.pal().COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('查看')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().COLOR_ACCENT)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedKey = 'SetLogs';
      } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && this.pressedKey === 'SetLogs') {
        this.pressedKey = '';
      }
    })
    .scale({ x: this.pressScale('SetLogs'), y: this.pressScale('SetLogs') })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      this.pushLogs();
    })
  }

  // ================= 底部悬浮 TabBar 的页签单元 =================
  // 结构上使用官方 Tabs(barPosition=End)+barFloatingStyle 悬浮底栏（沉浸光感唯一官方生效区）：
  // 栏体玻璃/触碰发光/按压形变由系统材质统一呈现；这里只画“选中高亮块 + 文字”两个状态，
  // 不写任何按压光/阴影（避免与系统材质叠加串色或遮挡官方光效）。
  @Builder
  NavCell(label: string, index: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.curTab === index) {
        Column()
          .width(NAV_PILL_W)
          .height(NAV_PILL_H)
          .borderRadius(NAV_PILL_H / 2)
          // 选中高亮：系统蓝纯色块。进场=0.86→1 缩放淡入（轻“弹”），离场=纯淡出，
          // 让高亮在页签间“换位”而非生硬闪变（跨格滑位已取消，内容翻页由页面层动效接管）。
          // 时长压到 120/100ms：高亮在按下那一刻立即换位，不再慢半拍。
          .backgroundColor(this.pal().COLOR_ACCENT)
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation({ duration: 120, curve: Curve.FastOutSlowIn })
              .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 })
                .animation({ duration: 120, curve: Curve.FastOutSlowIn })),
            TransitionEffect.OPACITY.animation({ duration: 100, curve: Curve.EaseIn })
          ))
      }
      Text(label)
        .fontSize(13)
        .fontWeight(this.curTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.curTab === index ? '#FFFFFF' : this.pal().COLOR_SUB)
        .animation({ duration: 120, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height('100%')
    // 关键：按下页签的瞬间就同步写 curTab（不等 Tabs 动画结束的 onChange），
    // 让高亮与目标页内容立即起步；不拦截事件，Tabs 仍照常接管内容翻页。
    .onClick(() => {
      this.switchTab(index);
    })
  }

  // ================= 背景与沉浸光感说明 =================
  // 页面背景即最外层 .backgroundColor(this.pal().COLOR_BG) 纯近黑底色，不再绘制任何自绘光晕；
  // 玻璃观感与光感全部由官方能力承担：卡片背景模糊、悬浮控件系统材质、按压官方光效。

  // 设置页“外观模式”：浅色 / 深色 / 跟随系统 三段切换（样式与其他设置卡一致）
  @Builder
  ThemeRow() {
    Column({ space: 10 }) {
      Row() {
        Text('外观模式')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Blank()
        Text(this.themeDesc())
          .fontSize(12)
          .fontColor(this.pal().COLOR_SUB)
          .margin({ left: 10 })
      }
      .width('100%')

      Row({ space: 4 }) {
        this.ThemeSeg('浅色', THEME_LIGHT)
        this.ThemeSeg('深色', THEME_DARK)
        this.ThemeSeg('跟随系统', THEME_FOLLOW)
      }
      .width('100%')
      .height(38)
      .padding(3)
      .backgroundColor(this.pal().COLOR_TRACK)
      .borderRadius(10)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  // “外观模式”分段单项：选中=系统蓝底白字，未选=透明底灰字
  @Builder
  ThemeSeg(label: string, mode: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.themeMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.themeMode === mode ? '#FFFFFF' : this.pal().COLOR_SUB)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(this.themeMode === mode ? this.pal().COLOR_ACCENT : Color.Transparent)
      .borderRadius(8)
      .onClick(() => {
        this.setThemeMode(mode);
      })
  }

  // “沉浸光效强度”分段行：柔和/标准/增强三档，切换即改底栏与悬浮按钮系统材质（含触点光）的取参
  @Builder
  GlowRow() {
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Text('沉浸光效强度')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text(this.glowDesc())
          .fontSize(12)
          .lineHeight(17)
          .fontColor(this.pal().COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row({ space: 4 }) {
        this.GlowSeg('柔和', GLOW_SOFT)
        this.GlowSeg('标准', GLOW_NORMAL)
        this.GlowSeg('增强', GLOW_STRONG)
      }
      .width('100%')
      .height(38)
      .padding(3)
      .backgroundColor(this.pal().COLOR_TRACK)
      .borderRadius(10)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  // “沉浸光效强度”分段单项：选中=系统蓝底白字，未选=透明底灰字
  @Builder
  GlowSeg(label: string, level: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.glowLevel === level ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.glowLevel === level ? '#FFFFFF' : this.pal().COLOR_SUB)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(this.glowLevel === level ? this.pal().COLOR_ACCENT : Color.Transparent)
      .borderRadius(8)
      .onClick(() => {
        this.setGlow(level);
      })
  }

  // 设置页说明卡：光效材质由系统沉浸材质统一呈现，应用内档位只调强度取参。
  @Builder
  ImmersiveInfoRow() {
    Row() {
      Column({ space: 4 }) {
        Text('沉浸光感')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)
        Text('玻璃、按压流光与形变均由系统沉浸材质统一呈现，强度按上方档位生效')
          .fontSize(12)
          .lineHeight(17)
          .fontColor(this.pal().COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('系统材质')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().COLOR_ACCENT)
        .margin({ left: 10 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .backgroundColor(this.pal().COLOR_CARD)
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.pal().COLOR_HAIR })
    .borderRadius(16)
  }

  build() {
    // ================= 沉浸光感 = 官方生效区（结构性关键） =================
    // 系统沉浸材质只对两类位置开放：Navigation/NavDestination 标题栏，以及
    // “横排 Tabs + barPosition=End”的底部 TabBar。内容区里自绘的容器无论参数怎么配
    // 都不会出现官方按压发光/形变——这正是此前“怎么调都没效果”的根因。
    // 本版把导航换成官方 Tabs 悬浮底栏：玻璃/触碰发光/按压形变交给
    // barFloatingStyle.systemMaterial（interactive + lightEffect 白触点光），
    // 应用只保留选中高亮与内容页面，不再自绘胶囊容器。
    Stack() {
      // 三页内容（官方 Tabs 悬浮底栏自带沉浸光感）+ 悬浮领取按钮 overlay
      Stack({ alignContent: this.fabAlign }) {
        Tabs({ barPosition: BarPosition.End, index: this.curTab }) {
          // 页 1：游戏列表（Tabs 保持各页常驻，滚动位置不丢失）
          TabContent() {
            Column() {
              this.Header()
              this.Content()
            }
            .width('100%')
            .height('100%')
            .opacity(this.pageAlpha(0))
            .translate({ x: this.pageOffsetX(0) })
            .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          }
          .tabBar(this.NavCell('游戏', 0))

          // 页 2：历史
          TabContent() {
            Column() {
              this.HistoryHeader()
              this.HistoryView()
            }
            .width('100%')
            .height('100%')
            .opacity(this.pageAlpha(1))
            .translate({ x: this.pageOffsetX(1) })
            .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          }
          .tabBar(this.NavCell('历史', 1))

          // 页 3：设置
          TabContent() {
            Column() {
              this.SettingsHeader()
              Scroll() {
                // 统一内容边距；设置项按“语义分组 + 小标题”排布。
                // 每个条目用透明包装列承载级联入场动画（rank 从上到下递增），不影响布局与点击。
                Column() {
                  Column() {
                    this.SettingsGroupTitle('视觉与光效', 2)
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 1))
                  Column() {
                    this.ThemeRow()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 2))
                  Column() {
                    this.GlowRow()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 3))
                  Column() {
                    this.ImmersiveInfoRow()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 4))

                  Column() {
                    this.SettingsGroupTitle('提醒与通知', 24)
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 5))
                  Column() {
                    this.NotifyRow()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 6))
                  Column() {
                    this.CalRow()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 7))

                  Column() {
                    this.SettingsGroupTitle('领取方式', 24)
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 8))
                  Column() {
                    this.ClaimModeCard()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 9))

                  // 智感握持只作用于自动领取模式的悬浮按钮，自动领取开启时才展示该组
                  if (this.claimAuto) {
                    Column() {
                      this.SettingsGroupTitle('悬浮按钮', 24)
                    }
                    .width('100%')
                    .opacity(this.entOpacity(2))
                    .translate({ y: this.entRise(2) })
                    .animation(this.entAnim(2, 10))
                    Column() {
                      this.GripRow()
                    }
                    .width('100%')
                    .opacity(this.entOpacity(2))
                    .translate({ y: this.entRise(2) })
                    .animation(this.entAnim(2, 11))
                  }

                  Column() {
                    this.SettingsGroupTitle('调试与帮助', 24)
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 12))
                  Column() {
                    this.LogRow()
                  }
                  .width('100%')
                  .opacity(this.entOpacity(2))
                  .translate({ y: this.entRise(2) })
                  .animation(this.entAnim(2, 13))
                }
                .width('100%')
                .padding({ left: 16, right: 16, bottom: this.overlayReserve() })
              }
              .scrollBar(BarState.Off)
              .align(Alignment.Top)
              .width('100%')
              .layoutWeight(1)
            }
            .width('100%')
            .height('100%')
            .opacity(this.pageAlpha(2))
            .translate({ x: this.pageOffsetX(2) })
            .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          }
          .tabBar(this.NavCell('设置', 2))
        }
        .vertical(false)
        .scrollable(false)
        .barMode(BarMode.Fixed)
        .barHeight(NAV_H)
        .barOverlap(true)
        // 点页签/改 index 时由 Tabs 官方通道做内容横向滑切（BottomTabBar 默认 0 需显式开启）；
        // 页面层另有淡入+轻微错位动效叠加，方向一致、互为增强。
        // 时长与页面层对齐（200ms）：两者同时收尾，按下即见效，不再有“滑完才出现”的等待感。
        .animationDuration(200)
        .barFloatingStyle({
          // 收窄成居中悬浮胶囊宽；与旧几何一致
          barWidth: {
            smallBarWidth: NAV_W,
            mediumBarWidth: NAV_W,
            largeBarWidth: NAV_W
          },
          barBottomMargin: this.barBottomPad(),
          adaptToHandedness: false,
          // 官方沉浸材质（API 26）：玻璃=THIN 起步、形变=interactive、触点光=lightEffect；
          // style 与触点光跟随“沉浸光效强度”档位（tabMaterial 取参），标准档即出厂 THIN 观感。
          // 栏体边框/阴影由材质统一管理，不在应用侧手写，避免串色/阴影失效。
          systemMaterial: this.tabMaterial()
        })
        .onChange((index: number) => {
          this.switchTab(index);
        })
        .width('100%')
        .height('100%')

        // 悬浮领取按钮：仅自动领取模式 + 游戏页 + 列表就绪时展示；点击手动开始批量领取
        if (this.curTab === 0 && this.claimAuto && !this.loading && !this.failed &&
          (this.nowList.length > 0 || this.soonList.length > 0)) {
          Stack() {
            Image($r('app.media.ic_gift'))
              .width(30)
              .height(30)
              .objectFit(ImageFit.Contain)
          }
          .width(58)
          .height(58)
          .borderRadius(29)
          // 与底部工具栏保持同一观感：中性磨砂玻璃（不额外着色），磨砂档位随“沉浸光效强度”对齐底栏材质。
          // 该按钮位于内容区、超出官方沉浸光感生效范围，故用通用属性模拟（详见 fabGlassColor 注释）。
          .backgroundColor(this.fabGlassColor())
          .backgroundBlurStyle(this.fabGlassBlur())
          .border({ width: 1, color: this.pal().COLOR_HAIR })
          .shadow({ radius: 18, color: '#40050A14', offsetY: 6 })
          .scale({ x: this.pressScale('__fab__'), y: this.pressScale('__fab__') })
          .animation({ duration: 160, curve: Curve.FastOutSlowIn })
          // 跟手对齐：右下角给右边距、左下角给左边距；整体抬升到底部悬浮 TabBar 之上
          .margin({
            left: this.fabAlign === Alignment.BottomStart ? 20 : 0,
            right: this.fabAlign === Alignment.BottomEnd ? 20 : 0,
            bottom: this.fabLiftPad()
          })
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.pressedKey = '__fab__';
            } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) &&
              this.pressedKey === '__fab__') {
              this.pressedKey = '';
            }
          })
          .onClick(() => {
            this.startAutoClaim();
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().COLOR_BG)
  }
}
