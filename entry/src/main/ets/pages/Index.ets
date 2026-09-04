import { common } from '@kit.AbilityKit';
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
  publishFreeNotice
} from '../common/EpicFree';

// ================= 配色（参考 HarmonyOS 系统应用：黑底 + 深灰卡片 + 系统蓝） =================

const COLOR_BG: string = '#000000';
const COLOR_CARD: string = '#1C1C1E';
const COLOR_IMG_BG: string = '#2C2C2E';
const COLOR_TEXT: string = '#FFFFFF';
const COLOR_SUB: string = '#8E8E93';
const COLOR_LINE: string = '#2C2C2E';
const COLOR_ACCENT: string = '#0A59F7';

// ================= 页面 =================

@Entry
@Component
struct Index {
  @State loading: boolean = true;
  @State failed: boolean = false;
  @State nowList: GameItem[] = [];
  @State soonList: GameItem[] = [];
  @State notifyOn: boolean = false;
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
      const auto: boolean = await readClaimAuto(ctx);
      this.claimAuto = auto;
      const grip: boolean = await readGripAdapt(ctx);
      this.gripOn = grip;
      const right: boolean = await readFabRight(ctx);
      this.manualRight = right;
      const claimed: string[] = await readClaimed(ctx);
      this.claimedTitles = claimed;
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
          // 自动领取模式下已入库：灰底标记，点击仅提示
          Text('已领取')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_SUB)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(COLOR_IMG_BG)
            .borderRadius(16)
            .margin({ left: 10 })
            .onClick(() => {
              promptAction.showToast({ message: '该游戏已在库中' });
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
      this.curTab = index;
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
        this.TabItem('设置', 1)
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

        // 页 2：设置
        Column() {
          this.SettingsHeader()
          Scroll() {
            Column({ space: 0 }) {
              this.NotifyRow()
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
        .visibility(this.curTab === 1 ? Visibility.Visible : Visibility.None)

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
