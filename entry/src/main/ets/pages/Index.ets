import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { motion } from '@kit.MultimodalAwarenessKit';
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
  freshTitles,
  mergeSeen,
  publishFreeNotice,
  readCalOn,
  saveCalOn,
  addFreeToCalendar
} from '../common/EpicFree';
import { HistItem, recordFreeNow, readHistoryMerged, backfillHistCovers } from '../common/FreeHistory';

// ================= 配色（参考 HarmonyOS 系统应用：黑底 + 深灰卡片 + 系统蓝） =================

const COLOR_BG: string = '#000000';
const COLOR_CARD: string = '#1C1C1E';
const COLOR_IMG_BG: string = '#2C2C2E';
const COLOR_TEXT: string = '#FFFFFF';
const COLOR_SUB: string = '#8E8E93';
const COLOR_LINE: string = '#2C2C2E';
const COLOR_ACCENT: string = '#0A59F7';
const COLOR_OK: string = '#34C759';
// 历史页“滑动加载更多”：首次只渲染一页，滑到底部再按此数量追加（避免上千条一次性全部渲染）
const HIST_PAGE: number = 20;

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
  @State nowList: GameItem[] = [];
  @State soonList: GameItem[] = [];
  // EPIC 送过的免费游戏历史（本地累积 + 第三方补全，最新在前）
  @State histList: HistItem[] = [];
  // 历史页实际渲染的可见子集：始终只保留前若干条，滑到底部再追加（数据总条数见 histList）
  @State histShown: HistItem[] = [];
  @State notifyOn: boolean = false;
  // 自动把“即将免费”加入系统日历：true=拉到新档期就写全天日程并提醒
  @State calOn: boolean = false;
  private calSyncing: boolean = false;
  // 领取方式：false=跳转领取（点卡片用系统浏览器打开） true=自动领取（点悬浮按钮批量代领）
  @State claimAuto: boolean = false;
  // 已自动领取成功入库的游戏标题（卡片据此显示“已领取”并跳过重复尝试）
  @State claimedTitles: string[] = [];
  @State curTab: number = 0;
  // 智感握持开关：true=悬浮按钮跟随握持手左右换角（默认开启）
  @State gripOn: boolean = true;
  // 关闭智感握持时手动固定的按钮位置：true=右下角，false=左下角
  @State manualRight: boolean = true;
  // 悬浮按钮所在下角：右手握持默认右下，智感握持检测到左手后自动切到左下
  @State fabAlign: Alignment = Alignment.BottomEnd;
  private holdOn: boolean = false;
  @StorageProp('safeTop') topInset: number = 0;
  @StorageProp('safeBottom') bottomInset: number = 0;
  private inflight: boolean = false;
  private lastLoad: number = 0;
  private seenFree: string[] = [];
  private prefReady: boolean = false;
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
      const claimed: string[] = await readClaimed(ctx);
      this.claimedTitles = claimed;
      const hist: HistItem[] = await readHistoryMerged(ctx);
      this.histList = hist;
      // 首次只展示约一页（终点对齐到整月，月份标题不会被截断），其余滑动到底部按需追加
      this.histShown = hist.slice(0, histAlignMonthEnd(hist, Math.min(HIST_PAGE, hist.length)));
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
    this.load();
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

  load(): void {
    if (this.inflight) {
      return;
    }
    this.inflight = true;
    this.loading = true;
    this.failed = false;
    requestFreeText().then((text: string) => {
      this.inflight = false;
      this.apply(text);
      this.loading = false;
    }).catch(() => {
      this.inflight = false;
      this.failed = true;
      this.loading = false;
    });
  }

  apply(text: string): void {
    const lists = parseFree(text);
    if (lists === null) {
      this.failed = true;
      return;
    }
    const nowArr: GameItem[] = lists.nowArr;
    const soonArr: GameItem[] = lists.soonArr;
    this.checkNewFree(nowArr);
    this.nowList = nowArr;
    this.soonList = soonArr;
    this.lastLoad = Date.now();
    // 历史页数据：把本批“现在免费”并入本地历史（已记录过会自动跳过）
    this.recordFreeHistory(nowArr);
    // 自动加入日历开启时：新拉到的“即将免费”顺手写成开领当天的全天日程
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

  // 该游戏是否已记录为“自动领取成功入库”
  private isClaimed(title: string): boolean {
    return this.claimedTitles.indexOf(title) > -1;
  }

  // 点击卡片“去领取/自动领取”：按当前领取方式分发
  // 跳转领取 → 系统浏览器打开领取页；自动领取 → 应用内网页会话逐款代领
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

  // 从领取页/系统浏览器返回时刷新“已领取”名单，让卡片状态与真实进度同步
  private refreshClaimed(): void {
    const ctx = getContext(this) as common.Context;
    readClaimed(ctx).then((list: string[]) => {
      this.claimedTitles = list;
    }).catch(() => {
    });
  }

  // ================= 历史：EPIC 送过的免费游戏 =================

  // 重新读取历史（进入页面/返回前台时调用）：
  // 内容没变化时不动已渲染窗口、保留滚动位置；有变化才整体刷新，并只渲染首页条数。
  private loadHistory(): void {
    const ctx = getContext(this) as common.Context;
    readHistoryMerged(ctx).then((list: HistItem[]) => {
      if (this.sameHist(this.histList, list)) {
        return;
      }
      this.histList = list;
      // 有变化才整体刷新；同样只展示约一页、终点对齐整月
      this.histShown = list.slice(0, histAlignMonthEnd(list, Math.min(HIST_PAGE, list.length)));
      this.fillVisibleHistCovers();
    }).catch(() => {
    });
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

  // 底部导航切换：进入历史页时给可见窗口补一次封面
  private switchTab(index: number): void {
    this.curTab = index;
    if (index === 1) {
      this.fillVisibleHistCovers();
    }
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
      return COLOR_OK;
    }
    if (h.endMs > Date.now()) {
      return COLOR_ACCENT;
    }
    return COLOR_SUB;
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

  // 收集“现在免费”中尚未领取成功的游戏，作为批量领取任务
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
      promptAction.showToast({ message: '已开启：即将免费的游戏会自动加入系统日历' });
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

  @Builder
  Header() {
    Row() {
      Column({ space: 3 }) {
        Text('每周免费游戏')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Text('EPIC 商店 · 每周更新')
          .fontSize(12)
          .fontColor(COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      if (!this.loading) {
        Text(this.failed ? '重试' : '刷新')
          .fontSize(14)
          .fontColor(COLOR_ACCENT)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.load();
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
  }

  // ================= 加载 / 结果提示 =================

  @Builder
  LoadingView() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(46)
        .height(46)
        .color(COLOR_ACCENT)
      Text('获取免费游戏列表中…')
        .fontSize(14)
        .fontColor(COLOR_SUB)
    }
    .width('100%')
    .padding({ top: 140, bottom: 140 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  TipView(main: string, sub: string) {
    Column({ space: 10 }) {
      Text(main)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TEXT)
      Text(sub)
        .fontSize(13)
        .fontColor(COLOR_SUB)
      Text('点击重试')
        .fontSize(13)
        .fontColor(COLOR_ACCENT)
        .margin({ top: 6 })
    }
    .width('100%')
    .padding({ top: 140, bottom: 140 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.load();
    })
  }

  // ================= 游戏列表 =================

  @Builder
  GameCard(item: GameItem) {
    Row() {
      if (item.img.length > 0) {
        Image(item.img)
          .width(100)
          .height(62)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .backgroundColor(COLOR_IMG_BG)
          .margin({ right: 12 })
      }

      Column({ space: 4 }) {
        Text(item.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.sub)
          .fontSize(12)
          .lineHeight(17)
          .fontColor(COLOR_SUB)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (item.claim.length > 0) {
        if (this.claimAuto && this.isClaimed(item.title)) {
          // 自动领取模式下已入库：灰底标记，点击重新进入游戏页浏览
          Text('已领取')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_SUB)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(COLOR_IMG_BG)
            .borderRadius(16)
            .margin({ left: 10 })
            .onClick(() => {
              this.openBrowser(item.claim);
            })
        } else {
          // 按领取方式显示：跳转=去领取（浏览器），自动=自动领取（应用内脚本）
          Text(this.claimAuto ? '自动领取' : '去领取')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(COLOR_ACCENT)
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
    .backgroundColor(COLOR_CARD)
    .borderRadius(14)
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
              .fontColor(COLOR_TEXT)
            ForEach(this.nowList, (item: GameItem) => {
              this.GameCard(item)
            }, (item: GameItem) => item.title + item.sub)
          }
          .width('100%')
        }

        if (this.soonList.length > 0) {
          Column({ space: 10 }) {
            Text('即将免费')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_TEXT)
            ForEach(this.soonList, (item: GameItem) => {
              this.GameCard(item)
            }, (item: GameItem) => item.title + item.sub)
          }
          .width('100%')
        }
      }
      .width('100%')
      // 自动领取模式下悬浮按钮会盖住滚动区底部，预留避让空间
      .padding({ left: 16, right: 16, top: 2, bottom: this.claimAuto ? 96 : 24 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  Content() {
    if (this.loading) {
      this.LoadingView()
    } else if (this.failed) {
      this.TipView('获取失败', '请检查网络连接后重试')
    } else if (this.nowList.length === 0 && this.soonList.length === 0) {
      this.TipView('暂无可领免费游戏', '可能本周活动已结束，可稍后再来看看')
    } else {
      this.ListPanel()
    }
  }

  // ================= 历史页 =================

  @Builder
  HistoryHeader() {
    Column({ space: 3 }) {
      Text('历史')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TEXT)
      Text('EPIC 送过的免费游戏 · 共 ' + this.histList.length + ' 期')
        .fontSize(12)
        .fontColor(COLOR_SUB)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.getUIContext().px2vp(this.topInset) + 10,
      bottom: 8
    })
  }

  // 历史单卡：右侧状态用“色字”区分（绿=已领取 蓝=免费中 灰=已结束），不做跳动的标签布局
  @Builder
  HistoryCard(h: HistItem) {
    Row() {
      if (h.img.length > 0) {
        Image(h.img)
          .width(100)
          .height(62)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .backgroundColor(COLOR_IMG_BG)
          .margin({ right: 12 })
      } else {
        // 第三方历史源不提供封面图：显示“标题首字母”占位块，保证卡片版式与本地记录一致
        Column() {
          Text(h.t.length > 0 ? h.t.charAt(0).toUpperCase() : '?')
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .fontColor('#48484A')
        }
        .width(100)
        .height(62)
        .borderRadius(10)
        .backgroundColor(COLOR_IMG_BG)
        .justifyContent(FlexAlign.Center)
        .margin({ right: 12 })
      }

      Column({ space: 4 }) {
        Row() {
          Text(h.t)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
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
          .fontColor(COLOR_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(14)
    .onClick(() => {
      this.tapHist(h);
    })
  }

  @Builder
  HistoryView() {
    if (this.histList.length === 0) {
      Column({ space: 10 }) {
        Text('还没有历史记录')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Text('本应用检测到的每期免费游戏会自动记录在这里')
          .fontSize(13)
          .fontColor(COLOR_SUB)
      }
      .width('100%')
      .padding({ top: 140, bottom: 140 })
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: 12 }) {
          // 按月分组：每组 = 月份小标题 + 该月全部卡片（分组整体原子追加）
          ForEach(this.histGroups(), (g: HistGroup) => {
            Column({ space: 10 }) {
              Text(g.label)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(COLOR_SUB)
                .width('100%')
              ForEach(g.items, (h: HistItem) => {
                this.HistoryCard(h)
              }, (h: HistItem) => h.t + h.seenMs)
            }
            .width('100%')
          }, (g: HistGroup) => g.label)
          // 还有更多未展示时给出提示；滑到此处触发 onReachEnd 追加下一页
          if (this.histShown.length < this.histList.length) {
            Text('上滑加载更多 · 已显示 ' + this.histShown.length + ' / ' + this.histList.length)
              .fontSize(12)
              .fontColor(COLOR_SUB)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 10 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 2, bottom: 24 })
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
        .fontColor(COLOR_TEXT)
      Text('通知与提醒')
        .fontSize(12)
        .fontColor(COLOR_SUB)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.getUIContext().px2vp(this.topInset) + 10,
      bottom: 8
    })
  }

  @Builder
  NotifyRow() {
    Row() {
      Column({ space: 4 }) {
        Text('新免费提醒')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Text('发现新的免费游戏时推送通知')
          .fontSize(12)
          .fontColor(COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.notifyOn })
        .selectedColor(COLOR_ACCENT)
        .onChange((isOn: boolean) => {
          this.setNotify(isOn);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ left: 16, right: 16, top: 8 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(14)
  }

  // “自动加入日历”开关行：把“即将免费”的开领日自动写成系统日历全天日程
  @Builder
  CalRow() {
    Row() {
      Column({ space: 4 }) {
        Text('加入日历提醒')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Text('把“即将免费”的开领日写为当天全天日程并提醒')
          .fontSize(12)
          .fontColor(COLOR_SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.calOn })
        .selectedColor(COLOR_ACCENT)
        .onChange((isOn: boolean) => {
          this.setCal(isOn);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ left: 16, right: 16, top: 8 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(14)
  }

  // 智感握持开关行里的“位置分段”单项（manualRight 选中态由 @Builder 外层传入 right 判断）
  @Builder
  FabSideSegment(label: string, right: boolean) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.manualRight === right ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.manualRight === right ? '#FFFFFF' : COLOR_SUB)
      .textAlign(TextAlign.Center)
      .width('50%')
      .height('100%')
      .backgroundColor(this.manualRight === right ? COLOR_ACCENT : Color.Transparent)
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
            .fontColor(COLOR_TEXT)
          Text(this.gripOn ? '“开始自动领取”按钮自动跟随左右手握持换角' : '已关闭自动跟随：手动选择按钮固定位置')
            .fontSize(12)
            .fontColor(COLOR_SUB)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.gripOn })
          .selectedColor(COLOR_ACCENT)
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
        .backgroundColor('#111114')
        .borderRadius(10)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .margin({ left: 16, right: 16, top: 8 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // 设置页：领取方式切换段。mode=false=跳转领取，true=自动领取
  @Builder
  ModeSegment(label: string, mode: boolean) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.claimAuto === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.claimAuto === mode ? '#FFFFFF' : COLOR_SUB)
      .textAlign(TextAlign.Center)
      .width('50%')
      .height('100%')
      .backgroundColor(this.claimAuto === mode ? COLOR_ACCENT : Color.Transparent)
      .borderRadius(8)
      .onClick(() => {
        this.setClaimMode(mode);
      })
  }

  @Builder
  ClaimModeCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('领取方式')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
          Text(this.claimAuto ? '不自动开始：点游戏页下角悬浮按钮批量领取' : '点击卡片用系统浏览器打开领取页')
            .fontSize(12)
            .fontColor(COLOR_SUB)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 跳转领取 / 自动领取 二选一切换
      Row() {
        this.ModeSegment('跳转领取', false)
        this.ModeSegment('自动领取', true)
      }
      .width('100%')
      .height(38)
      .padding(3)
      .backgroundColor('#111114')
      .borderRadius(10)

      if (this.claimAuto) {
        // 自动领取依赖应用内登录态：提供一个内置网页登录入口
        Row() {
          Column({ space: 4 }) {
            Text('EPIC 账户登录')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_TEXT)
            Text('自动领取需在应用内登录一次，登录态会保留')
              .fontSize(12)
              .fontColor(COLOR_SUB)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('去登录')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ACCENT)
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          this.pushClaimLogin();
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .margin({ left: 16, right: 16, top: 8 })
    .backgroundColor(COLOR_CARD)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // ================= 底部导航栏 =================

  @Builder
  TabItem(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.curTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.curTab === index ? COLOR_TEXT : COLOR_SUB)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(index);
    })
  }

  @Builder
  BottomBar() {
    Column() {
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(COLOR_LINE)
      Row() {
        this.TabItem('游戏', 0)
        this.TabItem('历史', 1)
        this.TabItem('设置', 2)
      }
      .width('100%')
      .height(52)
    }
    .width('100%')
    .padding({ bottom: this.getUIContext().px2vp(this.bottomInset) })
  }

  build() {
    Column() {
      // 悬浮按钮需贴在“游戏页内容区”的下角，而底部的导航栏在其下方；
      // fabAlign 由智感握姿驱动：右手→右下，左手→左下
      Stack({ alignContent: this.fabAlign }) {
        // 页 1：游戏列表（常驻组件树，仅切换显隐，保留滚动位置）
        Column() {
          this.Header()
          this.Content()
        }
        .width('100%')
        .height('100%')
        .visibility(this.curTab === 0 ? Visibility.Visible : Visibility.None)

        // 页 2：历史（常驻组件树，仅切换显隐）
        Column() {
          this.HistoryHeader()
          this.HistoryView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.curTab === 1 ? Visibility.Visible : Visibility.None)

        // 页 3：设置
        Column() {
          this.SettingsHeader()
          Scroll() {
            Column({ space: 0 }) {
              this.NotifyRow()
              this.CalRow()
              this.ClaimModeCard()
              // 智感握持只作用于自动领取模式的悬浮按钮，自动领取开启时才展示开关
              if (this.claimAuto) {
                this.GripRow()
              }
            }
            .width('100%')
            .padding({ bottom: 24 })
          }
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .visibility(this.curTab === 2 ? Visibility.Visible : Visibility.None)

        // 悬浮按钮：仅自动领取模式 + 游戏页 + 列表就绪时展示；点击手动开始批量领取
        if (this.curTab === 0 && this.claimAuto && !this.loading && !this.failed &&
          (this.nowList.length > 0 || this.soonList.length > 0)) {
          Text('开始自动领取')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .padding({ left: 18, right: 18, top: 11, bottom: 11 })
            .backgroundColor(COLOR_ACCENT)
            .borderRadius(22)
            .shadow({ radius: 14, color: '#660A59F7', offsetY: 5 })
            // 跟手对齐：贴在右下给右边距，贴在左下给左边距
            .margin({
              left: this.fabAlign === Alignment.BottomStart ? 16 : 0,
              right: this.fabAlign === Alignment.BottomEnd ? 16 : 0,
              bottom: 14
            })
            .onClick(() => {
              this.startAutoClaim();
            })
        }
      }
      .width('100%')
      .layoutWeight(1)

      this.BottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG)
  }
}
