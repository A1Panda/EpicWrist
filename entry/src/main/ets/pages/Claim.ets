// Claim.ets —— 内置领取/登录会话页。
// 承载一个持久的 Web 实例：
//  - mode=login：打开 EPIC 登录页，登录完成后 Cookie 保留在应用 Web 内，供后续自动领取复用；
//  - mode=auto：按路由传入的 tasks 逐款跳转官方领取页，注入脚本寻找“获取/Get”按钮并模拟点击，
//    成功后把标题写入 preferences(epic_free_state) 的 claimedTitles，返回首页时卡片即显示“已领取”。
// 说明：后台任务（WorkScheduler）无 UI 无法模拟网页点击，因此自动领取必须在应用前台本页面内完成。

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import {
  CLAIM_HISTORY_URL,
  CLAIM_LOGIN_URL,
  CLAIM_STORE_URL,
  ClaimTask,
  markClaimed,
  saveOwned
} from '../common/EpicFree';
import { appendLog } from '../common/Log';
import { THEME_FOLLOW, AppPal, appPal } from '../common/Theme';

// 账号「交易→购买」页抓取结果：titles=本轮读到的条目标题，more=页面是否还有“显示更多”可展开
interface SyncScrape {
  titles: string[];
  more: boolean;
  note?: string;
  probe?: string;
}

@Entry
@Component
struct Claim {
  @State urlInit: string = 'about:blank';
  @State curInfo: string = '';
  @State busy: boolean = false;          // 自动领取运行中
  @State loginPaused: boolean = false;   // 自动领取时遇到登录要求，等待用户手动登录
  @State okTitles: string[] = [];
  @State failTitles: string[] = [];
  @State skipOwned: number = 0;          // 判定为“已在库”而直接跳过的数量（只有真检测到入库文案才算）
  @State diagText: string = '';          // 最近一次判失败时页面上识别到的按钮文字快照，便于排查
  @State diagLog: string[] = [];         // 每款游戏的判定轨迹日志，便于排查“被跳过/被记为失败”的真实原因
  @State syncCount: number = 0;          // 同步“已拥有”模式下已读到的记录条数
  @State syncNote: string = '';          // 同步模式下的页面诊断信息（host/按钮文案/文本取样），读不到数据时用于排查
  @State syncPreview: string = '';       // 同步模式下抓到的条目预览（前几条），便于核对抓到的是否是游戏条目
  @State syncProbe: string = '';         // 同步模式下的结构取样（状态行所在 DOM 路径 + 该行文本），用于确认游戏名是否在列表中
  // 外观模式：0=跟随系统 1=固定浅色 2=固定深色；页面取色统一走 pal()（浅/深共用一套键名）
  @StorageLink('themeMode') themeMode: number = THEME_FOLLOW;
  @StorageProp('sysDark') sysDark: boolean = false;
  @StorageProp('safeTop') topInset: number = 0;
  @StorageProp('safeBottom') bottomInset: number = 0;

  private controller: webview.WebviewController = new webview.WebviewController();
  private mode: string = 'auto';         // login | auto | sync
  private tasks: ClaimTask[] = [];
  private index: number = 0;             // 当前处理到第几个任务
  private firstLoad: boolean = true;     // 首款页面直接由 Web src 加载，无需 loadUrl
  private navResolve: (() => void) | null = null;
  private timers: number[] = [];
  private stopped: boolean = false;      // 页面离开后停止一切流程
  private lastUrl: string = '';

  // 深浅色当前有效取色板：由外观模式 + 系统真实明暗共同决定
  private pal(): AppPal {
    return appPal(this.themeMode, this.sysDark);
  }

  aboutToAppear(): void {
    // 解析路由参数
    const p = router.getParams() as Record<string, string>;
    const m: string = p['mode'] !== undefined ? p['mode'] : 'auto';
    this.mode = m === 'login' ? 'login' : (m === 'sync' ? 'sync' : 'auto');
    if (this.mode === 'login') {
      this.urlInit = CLAIM_LOGIN_URL;
      this.lastUrl = CLAIM_LOGIN_URL;
      return;
    }
    if (this.mode === 'sync') {
      // 用已登录的 Web 会话打开账号「交易 → 购买」页，读取本人领取/购买记录，供历史页标出已入库
      this.urlInit = CLAIM_HISTORY_URL;
      this.lastUrl = CLAIM_HISTORY_URL;
      this.curInfo = '正在读取账号购买记录…';
      this.busy = true;
      this.stopped = false;
      this.runSync();
      return;
    }
    const raw: string = p['tasks'] !== undefined ? p['tasks'] : '';
    if (raw.length > 0) {
      try {
        const arr = JSON.parse(raw) as ClaimTask[];
        if (arr instanceof Array) {
          this.tasks = arr;
        }
      } catch (e) {
        this.tasks = [];
      }
    }
    if (this.tasks.length === 0) {
      // 没有可领取任务时也能进入商店专区手动浏览
      this.urlInit = CLAIM_STORE_URL;
      this.lastUrl = CLAIM_STORE_URL;
      this.curInfo = '当前没有待领取的免费游戏';
      return;
    }
    this.urlInit = this.tasks[0].url;
    this.lastUrl = this.tasks[0].url;
    this.curInfo = '准备领取…';
    // 首款由 Web 的 src 自动加载，onPageEnd 后流程接管
    this.busy = true;
    this.stopped = false;
    this.runAuto();
  }

  aboutToDisappear(): void {
    this.stopped = true;
    if (this.navResolve) {
      const r = this.navResolve;
      this.navResolve = null;
      r();
    }
    for (let i = 0; i < this.timers.length; i++) {
      clearTimeout(this.timers[i]);
    }
    this.timers = [];
  }

  // ================= 网页加载事件 =================

  // onPageEnd / onErrorReceive：仅当正在等待一次主动导航时推进流程，
  // 领取过程中网站自身产生的跳转不触发新任务（navResolve 为空则忽略）
  private webEvent(): void {
    if (this.navResolve) {
      const r = this.navResolve;
      this.navResolve = null;
      r();
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      if (this.stopped) {
        resolve();
        return;
      }
      const id: number = setTimeout(() => {
        resolve();
      }, ms);
      this.timers.push(id);
    });
  }

  // 等待一次主动导航完成（带超时，防止网络错误卡死流程）
  private waitNav(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      this.navResolve = resolve;
      const id: number = setTimeout(() => {
        if (this.navResolve === resolve) {
          this.navResolve = null;
        }
        resolve();
      }, ms);
      this.timers.push(id);
    });
  }

  // 在页面中执行脚本，返回其字符串结果；异常一律返回 'NONE'
  private inject(js: string): Promise<string> {
    return this.controller.runJavaScript(js).then((r: string) => {
      if (r === null || r === undefined) {
        return 'NONE';
      }
      let s: string = String(r);
      // runJavaScript 对字符串返回值会做 JSON 序列化（自带双引号），例如返回 '"CLICKED"'；
      // 这里统一剥掉这层引号，保证后续 === 'CLICKED' / 'OWNED' 等比较成立。
      if (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') {
        try {
          const parsed = JSON.parse(s) as string;
          if (typeof parsed === 'string') {
            s = parsed;
          }
        } catch (e) {
          // 不是合法 JSON 字符串就保留原样
        }
      }
      return s;
    }).catch(() => {
      return 'NONE';
    });
  }

  // ================= 自动领取主流程 =================

  private async runAuto(): Promise<void> {
    while (!this.stopped && this.index < this.tasks.length) {
      const idx: number = this.index;
      const task: ClaimTask = this.tasks[idx];
      const slug: string = this.slugOf(task.url);
      this.diagText = '';

      this.curInfo = (idx + 1) + '/' + this.tasks.length + '  加载领取页：' + task.t;
      const navWait: Promise<void> = this.waitNav(25000);
      if (this.firstLoad) {
        // 首款：页面已由 Web src 加载，等待其 onPageEnd 即可
        this.firstLoad = false;
      } else {
        this.lastUrl = task.url;
        try {
          this.controller.loadUrl(task.url);
        } catch (e) {
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：页面加载异常');
          await this.failPush(task.t);
          this.index = idx + 1;
          continue;
        }
      }
      await navWait;
      if (this.stopped) {
        return;
      }
      await this.sleep(2200);
      if (this.stopped) {
        return;
      }

      // 1) 探测并点击“获取”
      this.curInfo = (idx + 1) + '/' + this.tasks.length + '  尝试获取：' + task.t;
      const r1: string = await this.inject(this.jsProbe(task.t, slug));
      if (this.stopped) {
        return;
      }
      if (r1 === 'OWNED') {
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：检测到已在库，跳过');
        this.skipOwned = this.skipOwned + 1;
        this.okPush(task.t);
        this.index = idx + 1;
        continue;
      }
      if (r1 === 'LOGIN') {
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：需要登录，暂停');
        this.pauseLogin(task);
        return;
      }
      if (r1 !== 'CLICKED') {
        // 没有可点的“获取”按钮：先确认是不是“已在库”，不是则重载后再探一次。
        // 只有真正检测到入库文案（OWNED）才算“已在库”跳过；否则记为失败，不误标“已领取”。
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：未找到“获取”按钮（返回 ' + r1 + '），复核是否在库');
        const v: string = await this.inject(this.jsVerify());
        if (v === 'LOGIN') {
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：复核时需登录，暂停');
          this.pauseLogin(task);
          return;
        }
        let owned: boolean = v === 'OWNED';
        if (!owned) {
          const r: string = await this.reloadProbe(task);
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：复核结果 verify=' + v + '，重载探针=' + r);
          if (r === 'LOGIN') {
            this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：重载后需登录，暂停');
            this.pauseLogin(task);
            return;
          }
          if (r === 'OWNED') {
            owned = true;
          }
        } else {
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：复核结果 verify=' + v);
        }
        if (owned) {
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：复核确认已在库，跳过');
          this.skipOwned = this.skipOwned + 1;
          this.okPush(task.t);
        } else {
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：未识别到领取入口，也未检测到在库，记为未成功');
          await this.failPush(task.t);
        }
        this.index = idx + 1;
        continue;
      }

      // 2) 点击后可能出现下单确认弹层：勾选条款并点“下单/确认”
      await this.sleep(3200);
      if (this.stopped) {
        return;
      }
      await this.inject(this.jsConfirm());
      await this.sleep(2400);
      if (this.stopped) {
        return;
      }

      // 3) 核对是否已入库（两次快速重试，给网站写库留时间）
      let r3: string = await this.inject(this.jsVerify());
      if (r3 === 'LOGIN') {
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：核对时需登录，暂停');
        this.pauseLogin(task);
        return;
      }
      if (r3 !== 'OWNED') {
        await this.sleep(2600);
        if (this.stopped) {
          return;
        }
        r3 = await this.inject(this.jsVerify());
      }
      if (r3 !== 'OWNED') {
        const rv: string = await this.reloadProbe(task);
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：重载核对 verify=' + r3 + '，重载探针=' + rv);
        if (rv === 'LOGIN') {
          this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：重载核对时需登录，暂停');
          this.pauseLogin(task);
          return;
        }
        if (rv === 'OWNED') {
          r3 = 'OWNED';
        }
      }
      if (r3 === 'OWNED') {
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：领取成功（已入库）');
        this.okPush(task.t);
      } else {
        // 已点过“获取”却始终检测不到“在库中”文案：可能是识别盲区，也可能真的没领到。
        // 如实记为“未成功”，不误标“已领取”，让用户可核对或手动补领。
        this.log('[' + (idx + 1) + '/' + this.tasks.length + '] ' + task.t + '：已点“获取”但未确认入库，记为未成功');
        await this.failPush(task.t);
      }
      this.index = idx + 1;
    }

    this.busy = false;
    if (this.stopped) {
      return;
    }
    let done: string = '完成：成功 ' + this.okTitles.length + ' 款';
    if (this.skipOwned > 0) {
      done = done + '（含已在库自动跳过 ' + this.skipOwned + ' 款）';
    }
    if (this.failTitles.length > 0) {
      done = done + '，未成功 ' + this.failTitles.length + ' 款（可在库中手动补领）';
    }
    this.curInfo = done;
  }

  // 追加一条判定轨迹日志（最多保留 40 条，滚动丢弃最早的）
  private log(line: string): void {
    const arr: string[] = this.diagLog.slice();
    arr.push(line);
    if (arr.length > 40) {
      arr.splice(0, arr.length - 40);
    }
    this.diagLog = arr;
    // 同步写入持久化运行日志，供设置页“运行日志”查看、复制发给开发者调试
    appendLog(getContext(this) as common.Context, '自动领取', line).catch(() => {
    });
  }

  // 成功一款：记入本地名单并持久化
  private okPush(title: string): void {
    const arr: string[] = this.okTitles.slice();
    if (arr.indexOf(title) < 0) {
      arr.push(title);
    }
    this.okTitles = arr;
    const one: string[] = [title];
    markClaimed(getContext(this) as common.Context, one).catch(() => {
    });
  }

  // 记失败一款，并抓取当前页面的按钮文字快照，供界面提示“是否其实已在库中”
  private async failPush(title: string): Promise<void> {
    const d: string = await this.inject(this.jsDiag());
    this.diagText = d.length > 0 ? d : '';
    const arr: string[] = this.failTitles.slice();
    if (arr.indexOf(title) < 0) {
      arr.push(title);
    }
    this.failTitles = arr;
  }

  // 重载产品页后多轮复核：
  //  - 页面是 React 水合，加载完成后再轮询几次，容忍渲染慢；
  //  - 已显示“在库中/成功入库” → OWNED；
  //  - 重新出现“获取”按钮（此前只是没渲染出来）→ 点掉并走完下单确认，成功 → OWNED；
  //  - 全程都看不到任何领取/入库入口 → NONE（调用方据此按“已在库”跳过，不误报失败）。
  // 返回：OWNED / LOGIN / NONE
  private async reloadProbe(task: ClaimTask): Promise<string> {
    if (this.stopped) {
      return 'NONE';
    }
    const slug: string = this.slugOf(task.url);
    const navWait: Promise<void> = this.waitNav(20000);
    this.lastUrl = task.url;
    try {
      this.controller.loadUrl(task.url);
    } catch (e) {
      return 'NONE';
    }
    await navWait;
    if (this.stopped) {
      return 'NONE';
    }
    for (let i = 0; i < 4; i++) {
      await this.sleep(2000);
      if (this.stopped) {
        return 'NONE';
      }
      const v: string = await this.inject(this.jsVerify());
      if (v === 'LOGIN') {
        return 'LOGIN';
      }
      if (v === 'OWNED') {
        return 'OWNED';
      }
      // 没有“在库中”文案：看看这次有没有渲染出“获取”按钮
      const p: string = await this.inject(this.jsProbe(task.t, slug));
      if (p === 'LOGIN') {
        return 'LOGIN';
      }
      if (p === 'OWNED') {
        return 'OWNED';
      }
      if (p !== 'CLICKED') {
        continue;
      }
      // 点到了“获取”：走下单确认 + 入库核对
      await this.sleep(3200);
      if (this.stopped) {
        return 'NONE';
      }
      await this.inject(this.jsConfirm());
      await this.sleep(2400);
      if (this.stopped) {
        return 'NONE';
      }
      let v2: string = await this.inject(this.jsVerify());
      if (v2 === 'LOGIN') {
        return 'LOGIN';
      }
      if (v2 !== 'OWNED') {
        await this.sleep(2600);
        if (this.stopped) {
          return 'NONE';
        }
        v2 = await this.inject(this.jsVerify());
      }
      if (v2 === 'OWNED') {
        return 'OWNED';
      }
      // 点了但仍未见入库文案：再等下一轮（可能还在结算/水合）
    }
    return 'NONE';
  }

  // 遇到登录要求：暂停自动流程，把网页交还给用户完成登录
  private pauseLogin(task: ClaimTask): void {
    this.busy = false;
    this.loginPaused = true;
    this.curInfo = '需要登录 EPIC。请在下方网页中完成登录，再点“继续自动领取”（第 '
      + (this.index + 1) + '/' + this.tasks.length + ' 款：' + task.t + '）';
  }

  // 用户登录完成后继续自动领取（从当前这款重新开始）
  private resumeAuto(): void {
    if (this.tasks.length === 0) {
      this.loginPaused = false;
      return;
    }
    this.loginPaused = false;
    this.busy = true;
    this.stopped = false;
    this.curInfo = '登录完成，继续领取…';
    this.runAuto();
  }

  // 离开页面（停止所有流程后返回）
  private leave(): void {
    this.stopped = true;
    if (this.navResolve) {
      const r = this.navResolve;
      this.navResolve = null;
      r();
    }
    router.back();
  }

  // ================= 注入脚本 =================

  private slugOf(url: string): string {
    try {
      const cut: number = url.indexOf('/p/');
      if (cut < 0) {
        return '';
      }
      let s: string = url.substring(cut + 3);
      const q: number = s.indexOf('?');
      if (q >= 0) {
        s = s.substring(0, q);
      }
      const h: number = s.indexOf('#');
      if (h >= 0) {
        s = s.substring(0, h);
      }
      return s.replace(/\/+$/g, '');
    } catch (e) {
      return '';
    }
  }

  // 探测并点击“获取”。若页面已显示“在库中/已拥有”等文案，直接判 OWNED（不再尝试领取）。
  // 返回：OWNED / CLICKED / LOGIN / NONE / ERR
  private jsProbe(title: string, slug: string): string {
    const tt: string = JSON.stringify(title);
    const ss: string = JSON.stringify(slug);
    const js: string =
      `(function(){
  try{
    function norm(x){ return (x==null?'':String(x)).replace(/[\\n\\r\\t\\u00a0\\u200b\\u2060]+/g,' ').replace(/ +/g,' ').trim().toLowerCase(); }
    var TITLE=${tt};
    var SLUG=${ss};
    // 已在库中判定：遍历可见小元素（含非按钮的 span/div），命中入库文案即认为已拥有。
    // 限制文本长度以避免把整页大段文字误判；带英文空格做单词边界，减少误伤。
    function ownedHit(){
      var OWNED=[' in library ',' in your library ',' already own ',' you own ',' owned ','已拥有','已添加至库','在库中','已入库','已在库中','已成功添加至库','购买成功','下单成功','已成功购买','已添加到您的库中','已添加到你的库中','added to your library','successfully claimed','thank you for your purchase','thank you for purchasing','thanks for your purchase','purchase complete','order complete'];
      var ns=document.querySelectorAll('body *');
      for(var i=0;i<ns.length;i++){
        var e=ns[i];
        if(e.offsetParent===null){ continue; }
        var j=' '+norm(e.textContent)+' '+norm(e.getAttribute&&e.getAttribute('aria-label'));
        if(j.length>92){ continue; }
        for(var w=0;w<OWNED.length;w++){ if(j.indexOf(OWNED[w])>=0){ return true; } }
      }
      return false;
    }
    // 登录页判定：EPIC 登录页已从 accounts.epicgames.com 迁到 www.epicgames.com/id/login，
    // 只认旧域名会漏判“需要登录”，导致登录失效时静默记为失败（jsVerify 同处同步修改）。
    if(location.hostname.indexOf('accounts.')>=0 || location.pathname.indexOf('/id/login')>=0){ return 'LOGIN'; }
    // 优先用官方 CTA（data-testid=purchase-cta-button）精确定位领取按钮：
    // 避免 'get' 之类子串把 “No, get launcher” 等无关链接误当领取入口（误点，或把已拥有误判成可领取）。
    var cta=null;
    var ctas=document.querySelectorAll('[data-testid="purchase-cta-button"]');
    for(var c=0;c<ctas.length;c++){ if(ctas[c].offsetParent!==null){ cta=ctas[c]; break; } }
    if(cta){
      var ctaTxt=norm(cta.textContent);
      var OWNED_CTA=['已在库中','在库中','已拥有','已入库','已添加','in library','already own','owned'];
      for(var oc=0;oc<OWNED_CTA.length;oc++){ if(ctaTxt.indexOf(OWNED_CTA[oc])>=0){ return 'OWNED'; } }
      var CLAIM_CTA=['获取','领取','免费','get','claim','free'];
      for(var gc=0;gc<CLAIM_CTA.length;gc++){ if(ctaTxt.indexOf(CLAIM_CTA[gc])>=0){ cta.click(); return 'CLICKED'; } }
      // CTA 文案既非“已拥有”也非“可领取”（如“即将推出/预购”）：不点击，交由下方兜底扫描判断
    }
    // 兜底：页面没有官方 CTA 时，仍按可见文字扫描“获取/get/领取”等
    // （部分语言/卡片按钮没有 data-testid，纯靠可见文字）
    var GET=['get','获取','领取','claim','免费'];
    var nodes=document.querySelectorAll('button,a,[role="button"]');
    var items=[];
    for(var i=0;i<nodes.length;i++){
      var e=nodes[i];
      if(e.offsetParent===null){ continue; }
      var testid=norm(e.getAttribute&&e.getAttribute('data-testid'));
      var txt=norm(e.textContent);
      var aria=norm(e.getAttribute&&e.getAttribute('aria-label'));
      var lower=testid+' '+txt+' '+aria;
      if(lower.length<2||lower.length>120){ continue; }
      for(var w=0;w<GET.length;w++){ if(lower.indexOf(GET[w])>=0){ items.push(e); break; } }
    }
    // 没有“获取”类按钮时才判“已在库”，避免页面上其他游戏卡片带 owned 字样导致误跳过
    if(items.length===0){ if(ownedHit()){ return 'OWNED'; } return 'NONE'; }
    function inSlug(e){
      var n=e;
      while(n&&n!==document.body){
        if(n.tagName==='A'&&SLUG){ var h=norm(n.getAttribute('href')); if(h.indexOf(SLUG)>=0){ return true; } }
        n=n.parentNode;
      }
      return false;
    }
    var pick=null;
    for(var i=0;i<items.length;i++){ if(inSlug(items[i])){ pick=items[i]; break; } }
    if(!pick){ pick=items[0]; }
    pick.click();
    return 'CLICKED';
  }catch(err){ return 'ERR'; }
})()`;
    return js;
  }

  // 确认下单：勾选可见条款框，再点“下单/确认”类按钮
  private jsConfirm(): string {
    const js: string =
      `(function(){
  try{
    function norm(x){ return (x==null?'':String(x)).replace(/[\\n\\r\\t\\u00a0\\u200b\\u2060]+/g,' ').replace(/ +/g,' ').trim().toLowerCase(); }
    var boxes=document.querySelectorAll('input[type=checkbox]');
    for(var i=0;i<boxes.length;i++){
      var b=boxes[i];
      if(b.offsetParent===null){ continue; }
      try{ if(!b.checked){ b.click(); } }catch(e){}
    }
    var words=['place order','下单','order now','立即购买','确认订单','提交订单','完成购买','购买','确认'];
    var nodes=document.querySelectorAll('button,a,[role="button"]');
    var best=null;
    for(var i=0;i<nodes.length;i++){
      var e=nodes[i];
      if(e.offsetParent===null){ continue; }
      var t=norm(e.textContent)+' '+norm(e.getAttribute&&e.getAttribute('aria-label'));
      for(var w=0;w<words.length;w++){ if(t.indexOf(words[w])>=0){ best=e; break; } }
      if(best){ break; }
    }
    if(best){ best.click(); return 'CONFIRMED'; }
    return 'NONE';
  }catch(err){ return 'ERR'; }
})()`;
    return js;
  }

  // 校验是否已入库（不点击）。扫描范围不限按钮：任意可见小元素出现入库/下单成功文案即判 OWNED，
  // 避免“游戏已在库中却因文案未被按钮识别而误报失败”。
  // 返回：OWNED / LOGIN / NONE
  private jsVerify(): string {
    const js: string =
      `(function(){
  try{
    function norm(x){ return (x==null?'':String(x)).replace(/[\\n\\r\\t\\u00a0\\u200b\\u2060]+/g,' ').replace(/ +/g,' ').trim().toLowerCase(); }
    // 登录页判定与 jsProbe 保持一致：兼容 EPIC 新登录页 www.epicgames.com/id/login
    if(location.hostname.indexOf('accounts.')>=0 || location.pathname.indexOf('/id/login')>=0){ return 'LOGIN'; }
    var OWNED=[' in library ',' in your library ',' already own ',' you own ',' owned ','已拥有','已添加至库','在库中','已入库','已在库中','已成功添加至库','购买成功','下单成功','已成功购买','已添加到您的库中','已添加到你的库中','added to your library','successfully claimed','thank you for your purchase','thank you for purchasing','thanks for your purchase','purchase complete','order complete'];
    var nodes=document.querySelectorAll('body *');
    for(var i=0;i<nodes.length;i++){
      var e=nodes[i];
      if(e.offsetParent===null){ continue; }
      var j=' '+norm(e.textContent)+' '+norm(e.getAttribute&&e.getAttribute('aria-label'));
      if(j.length>92){ continue; }
      for(var w=0;w<OWNED.length;w++){ if(j.indexOf(OWNED[w])>=0){ return 'OWNED'; } }
    }
    return 'NONE';
  }catch(err){ return 'ERR'; }
})()`;
    return js;
  }

  // 失败时抓取页面状态快照，供界面展示与人工核对页面“到底处于什么状态”：
  // 1) 整页文字命中领取/入库/异常关键词 → [xxx]；2) 主要按钮文字（领取类优先，排除导航词）；
  // 3) 页面主标题取样。这样快照能区分“获取按钮在但没点上”“页面是 404/验证/地区限制”等不同情况。
  private jsDiag(): string {
    const js: string =
      `(function(){
  try{
    function norm(x){ return (x==null?'':String(x)).replace(/[\\n\\r\\t\\u00a0\\u200b\\u2060]+/g,' ').replace(/ +/g,' ').trim().toLowerCase(); }
    var out=[];
    var whole=' '+norm(document.body.innerText)+' ';
    var keys=['获取','在库中','已拥有','已添加到','领取','免费游戏','立即购买','加入购物车','登录','sign in','in library','get it','add to cart','place order','下单','购买','not found','404','页面未找到','请稍候','安全检查','验证','不可用','unavailable','已过期','expired'];
    for(var k=0;k<keys.length;k++){ if(whole.indexOf(keys[k])>=0){ out.push('['+keys[k]+']'); } }
    var cta=['获取','领取','在库中','已拥有','下载','立即购买','加入购物车','下单','购买','get','claim','in library','buy','add to cart','place order','sign in','登录'];
    var skip=['搜索','商城','探索','愿望清单','礼物','购物车','主页','浏览','支持','返回','语言','登录于'];
    var ctaOut=[], otherOut=[];
    var ns=document.querySelectorAll('button,a[href],[role="button"],[data-testid]');
    for(var i=0;i<ns.length;i++){
      var e=ns[i];
      if(e.offsetParent===null){ continue; }
      var t=norm(e.textContent);
      if(!t){ t=norm(e.getAttribute&&e.getAttribute('aria-label')); }
      if(!t||t.length>60){ continue; }
      var isCta=false, isSkip=false;
      for(var c=0;c<cta.length;c++){ if(t.indexOf(cta[c])>=0){ isCta=true; break; } }
      if(!isCta){ for(var s=0;s<skip.length;s++){ if(t.indexOf(skip[s])>=0){ isSkip=true; break; } } }
      if(isSkip){ continue; }
      if(ctaOut.indexOf(t)<0&&otherOut.indexOf(t)<0){ if(isCta){ ctaOut.push(t); } else { otherOut.push(t); } }
    }
    out=out.concat(ctaOut.slice(0,6)).concat(otherOut.slice(0,8));
    var h1=document.querySelector('h1');
    var head=h1?norm(h1.textContent):'';
    if(head&&head.length<60){ out.push('标题:'+head); }
    if(out.length===0){ return ''; }
    var tail=out.join(' / ');
    if(tail.length>200){ tail=tail.substring(0,200); }
    return tail;
  }catch(err){ return 'ERR'; }
})()`;
    return js;
  }

  // ================= 同步“已拥有”主流程 =================
  // 打开账号「交易 → 购买」页，注入脚本抓取记录条目标题。
  // 该页是分页列表（底部“显示更多/Show More”），逐轮点开并把标题累积去重，最后整体落盘。
  // 说明：页面是按语言本地化渲染的表格，脚本按「状态词 … 价格/Price」的可见文本抽游戏名；
  // 标题的一致性由 CLAIM_HISTORY_URL 的 lang=en-US 保证（与应用内 en-US 标题对齐）。
  private async runSync(): Promise<void> {
    const navWait: Promise<void> = this.waitNav(25000);
    if (this.firstLoad) {
      // 首次进入：页面已由 Web src 加载，等待其 onPageEnd 即可
      this.firstLoad = false;
    } else {
      // 重新同步：重新加载一次，确保取到最新的登录态与记录
      this.lastUrl = CLAIM_HISTORY_URL;
      try {
        this.controller.loadUrl(CLAIM_HISTORY_URL);
      } catch (e) {
      }
    }
    await navWait;
    if (this.stopped) {
      return;
    }
    await this.sleep(3000);
    if (this.stopped) {
      return;
    }

    const all: string[] = [];
    let rounds: number = 0;
    let stable: number = 0;
    let lastCount: number = -1;
    this.syncNote = '';
    this.syncPreview = '';
    this.syncProbe = '';
    // 轮询抓取：既要等 React 水合把列表渲染出来，也要把“显示更多 / 滚动加载”的分页逐页展开。
    // 收尾判据用“条目数连续三轮不变”而不是“有没有更多按钮”——按钮式分页和滚动式无限加载都能覆盖。
    while (!this.stopped && rounds < 50) {
      rounds++;
      const raw: string = await this.inject(this.jsScrapeOwned());
      let titles: string[] = [];
      let hasMore: boolean = false;
      let note: string = '';
      let probe: string = '';
      try {
        const obj = JSON.parse(raw) as SyncScrape;
        if (obj.titles instanceof Array) {
          titles = obj.titles;
        }
        hasMore = obj.more === true;
        note = obj.note !== undefined ? obj.note : '';
        probe = obj.probe !== undefined ? obj.probe : '';
      } catch (e) {
      }
      if (note.length > 0) {
        this.syncNote = note;
      }
      if (probe.length > 0) {
        this.syncProbe = probe;
      }
      for (let i = 0; i < titles.length; i++) {
        const t: string = titles[i];
        if (t.length > 0 && all.indexOf(t) < 0) {
          all.push(t);
        }
      }
      this.syncCount = all.length;
      this.syncPreview = all.slice(0, 5).join(' / ');
      if (all.length === 0) {
        // 一条都没读到：多半是列表还在渲染（或未登录），继续等下一轮
        this.curInfo = '正在读取账号购买记录…（第 ' + rounds + ' 次尝试）';
        await this.sleep(1500);
        continue;
      }
      if (hasMore) {
        this.curInfo = '已读取 ' + all.length + ' 条记录，继续加载…';
        stable = 0;
        lastCount = all.length;
        await this.sleep(1600);
        continue;
      }
      this.curInfo = '已读取 ' + all.length + ' 条记录';
      // 数量连续三轮不变才判定到底：滚动触发懒加载有网络延迟，等太短会“还没加载出来就收尾”
      if (all.length === lastCount) {
        stable++;
        if (stable >= 3) {
          break;
        }
      } else {
        stable = 0;
      }
      lastCount = all.length;
      await this.sleep(2000);
    }

    if (this.stopped) {
      return;
    }
    if (all.length === 0) {
      this.busy = false;
      this.curInfo = '未读取到购买记录：可先在下方网页登录账号后点“重新同步”；若已登录，请把下方“页面诊断”反馈给开发者';
      appendLog(getContext(this) as common.Context, '同步已拥有',
        '未读取到任何记录；页面诊断：' + this.syncNote + '；结构取样：' + this.syncProbe).catch(() => {
      });
      return;
    }
    try {
      await saveOwned(getContext(this) as common.Context, all);
      appendLog(getContext(this) as common.Context, '同步已拥有',
        '读取到 ' + all.length + ' 条记录；页面诊断：' + this.syncNote + '；结构取样：' + this.syncProbe).catch(() => {
      });
    } catch (e) {
    }
    this.busy = false;
    this.curInfo = '同步完成：已记录 ' + all.length + ' 条购买/领取记录，返回历史页即可看到“已领取”标记';
  }

  // 抓取账号「交易 → 购买」页的记录条目标题，并尝试点开底部“显示更多”继续加载。
  // 返回 JSON 字符串：{ titles, more, note }（note 为页面诊断，读不到数据时显示在页面上便于排查）
  private jsScrapeOwned(): string {
    const js: string =
      `(function(){
  try{
    function norm(x){ return (x==null?'':String(x)).replace(/[\\n\\r\\t\\u00a0\\u200b\\u2060]+/g,' ').replace(/ +/g,' ').trim(); }
    var titles=[], seen={};
    function push(v){ v=norm(v); if(v.length>=2 && v.length<=120 && !seen[v]){ seen[v]=1; titles.push(v); } }
    // 主抽取：交易记录每行的文本形如「日期 <日期> 说明 已购买 <游戏名> 价格 ¥0.00 商城 Epic Games Store」，
    // 所以直接按「状态词 … 价格」的文本模式抽游戏名，比按 DOM 层级猜结构稳得多（也不会抓到“商城”那种噪音）。
    try{
      var full=norm(document.body.innerText);
      var pats=[
        /(?:已购买|已获取|免费|已退款)\\s*(.{2,120}?)\\s*价格/g,
        /(?:Purchased|Refunded|Free)\\s*(.{2,120}?)\\s*Price/g
      ];
      for(var pi=0;pi<pats.length;pi++){
        var re=pats[pi], mm;
        while((mm=re.exec(full))!==null){
          var cap=mm[1];
          // 防串行：某行若没有“价格”，惰性匹配会跨到下一行，这里把跨行捕获丢掉
          if(cap.indexOf('说明')>=0||cap.indexOf('日期')>=0||cap.indexOf('商城')>=0||cap.indexOf('Description')>=0){ continue; }
          push(cap);
        }
      }
    }catch(e6){}
    if(titles.length===0){
      var as=document.querySelectorAll('a[href*="/p/"], a[href*="/product"], a[href*="/purchase"], a[href*="/account/transactions"], a[data-testid*="product"], a[data-testid*="purchase"], a[data-testid*="order"]');
      for(var i=0;i<as.length;i++){ push(as[i].textContent); }
    }
    if(titles.length===0){
      var bad=/(已购买|已退款|已取消|已过期|免费|购买|退款|日期|说明|金额|订单号|状态|订单|查看|详情|更多|收据|总计|合计|优惠|支付方式|退款政策|常见问题|账户|交易|奖励|商城)/;
      var rows=document.querySelectorAll('tr, li, [role="row"], [role="listitem"], [data-testid*="row"], [class*="row"], [class*="item"], [class*="order"]');
      for(var r=0;r<rows.length;r++){
        var e=rows[r];
        if(e.offsetParent===null){ continue; }
        var kids=e.querySelectorAll('*'), best='';
        for(var m=0;m<kids.length && m<80;m++){
          var k=kids[m];
          if(k.children.length!==0){ continue; }
          var tx=norm(k.textContent);
          if(tx.length<3||tx.length>120){ continue; }
          if(bad.test(tx)){ continue; }
          if(/^[-+$\\u20ac\\u00a3\\u00a5 0-9.,%]+$/.test(tx)){ continue; }
          if(/^\\d{4}[-\\/.]\\d{1,2}[-\\/.]\\d{1,2}/.test(tx)){ continue; }
          if(/^\\d{4}年\\d{1,2}月\\d{1,2}日/.test(tx)){ continue; }
          if(tx.length>best.length){ best=tx; }
        }
        if(best.length>0){ push(best); }
      }
    }
    // 触发“加载更多”：不依赖按钮文案，含“更多/下一页/more/next/查看全部”任一关键词就点；
    // 没有这类按钮就滚到底部，靠外层“条目数是否还在增长”判断无限滚动是否还有内容。
    var more=false;
    var bs=document.querySelectorAll('button, [role="button"], a');
    for(var j=0;j<bs.length;j++){
      var b=bs[j];
      if(b.offsetParent===null){ continue; }
      var t=norm(b.textContent).toLowerCase();
      if(t.length===0||t.length>24){ continue; }
      if(t.indexOf('更多')>=0||t.indexOf('more')>=0||t.indexOf('下一页')>=0||t.indexOf('next')>=0||t.indexOf('查看全部')>=0||t.indexOf('继续加载')>=0){
        b.click(); more=true; break;
      }
    }
    // 翻页箭头：页面上那 2 个“无文字按钮”就是上/下一页，且不在任何 pagination 类名容器里。
    // ① 先按图标语义（aria/title/class/SVG 内含 next|right|forward|下一）直接点；
    // ② 否则把无文字按钮按“最靠右”认定为下一页 —— 两个箭头是并排的、top 相同，
    //    早先用“最靠下”会恒选到左边那个（上一页），这正是“两页来回翻”的原因；
    //    最右那个若为禁用态，说明已到最后一页，直接停止点击。
    if(!more){
      var allBtn=document.querySelectorAll('button, [role="button"]');
      var items=[];
      for(var q2=0;q2<allBtn.length;q2++){
        var be=allBtn[q2];
        if(be.offsetParent===null){ continue; }
        var btxt=norm(be.textContent);
        var bpa='';
        try{
          bpa=(String(be.getAttribute('aria-label')||'')+' '+String(be.getAttribute('title')||'')+' '
            +String(be.className||'')+' '+String(be.innerHTML||'')).toLowerCase();
        }catch(e18){}
        if(bpa.indexOf('next')>=0||bpa.indexOf('right')>=0||bpa.indexOf('forward')>=0||bpa.indexOf('下一')>=0||btxt==='›'||btxt==='»'||btxt==='>'){
          be.click(); more=true; break;
        }
        if(btxt.length===0){
          var bd2=false;
          try{ bd2=(be.hasAttribute('disabled')===true||be.getAttribute('aria-disabled')==='true'); }catch(e19){}
          var bl2=0;
          try{ var br2=be.getBoundingClientRect(); bl2=(br2&&typeof br2.left==='number')?br2.left:0; }catch(e27){}
          items.push({ e: be, l: bl2, d: bd2 });
        }
      }
      if(!more){
        var rightmost=null;
        for(var q4=0;q4<items.length;q4++){
          if(rightmost===null||items[q4].l>=rightmost.l){ rightmost=items[q4]; }
        }
        if(rightmost!==null && rightmost.d!==true){
          rightmost.e.click(); more=true;
        }
      }
    }
    if(!more){
      // 滚动触发懒加载：页面级 + 所有可滚动容器都滚到底，再对最后一个元素 scrollIntoView 并补发 scroll 事件
      try{ window.scrollTo(0, document.body.scrollHeight); }catch(e1){}
      try{
        var sc=document.scrollingElement||document.documentElement;
        if(sc){ sc.scrollTop=sc.scrollHeight; }
      }catch(e2){}
      var els=document.querySelectorAll('div, main, section');
      for(var s=0;s<els.length;s++){
        var el=els[s];
        if(el.scrollHeight>el.clientHeight+40){ el.scrollTop=el.scrollHeight; }
      }
      try{
        var lastEls=document.querySelectorAll('div, tr, li');
        if(lastEls.length>0){ lastEls[lastEls.length-1].scrollIntoView(false); }
      }catch(e10){}
      try{ window.dispatchEvent(new Event('scroll')); }catch(e11){}
    }
    // 诊断：把页面上可见按钮的文案列出来（用于定位翻页控件到底叫什么），并取一段正文文本
    var bt=[];
    var allb=document.querySelectorAll('button, [role="button"]');
    for(var z=0;z<allb.length && bt.length<12;z++){
      if(allb[z].offsetParent===null){ continue; }
      var tx2=norm(allb[z].textContent);
      var ar2='';
      try{ ar2=String(allb[z].getAttribute('aria-label')||'').substring(0,18); }catch(e17){}
      if(tx2.length>0 && tx2.length<30){ if(bt.indexOf(tx2)<0){ bt.push(tx2); } }
      else if(tx2.length===0){ bt.push('∅'+(ar2?'@'+ar2:'无文字')); }
    }
    // 分页诊断：把分页容器及其内部每个元素的「标签.类名@aria-label"文字"」列出来，
    // 用于定位箭头图标到底是什么元素、以及“下一页”该怎么点
    var pg=[];
    var pgn=document.querySelectorAll('[class*="pagination"],[class*="pager"],[class*="paging"],[data-testid*="page"]');
    for(var y=0;y<pgn.length && pg.length<4;y++){
      var cont=pgn[y];
      var cn='';
      try{ cn=String(cont.className||'').substring(0,28); }catch(e7){}
      var chs=cont.querySelectorAll('*');
      var desc=[];
      for(var u2=0;u2<chs.length && desc.length<8;u2++){
        var ce=chs[u2];
        if(ce.offsetParent===null){ continue; }
        var ccl='';
        try{ ccl=String(ce.className||'').substring(0,20); }catch(e14){}
        var cal='';
        try{ cal=String(ce.getAttribute('aria-label')||'').substring(0,20); }catch(e15){}
        var ct='';
        try{ ct=norm(ce.textContent).substring(0,12); }catch(e16){}
        desc.push((ce.tagName||'?').toLowerCase()+(ccl?'.'+ccl:'')+(cal?'@'+cal:'')+(ct?'"'+ct+'"':''));
      }
      pg.push('['+cn+'] > '+(desc.length>0?desc.join(' , '):'空'));
    }
    // 无文字按钮诊断：那两个“无文字按钮”就是上/下一页箭头，列出 class / aria / 禁用态 / 图标片段
    var pbtn=[];
    var allb2=document.querySelectorAll('button, [role="button"]');
    for(var z2=0;z2<allb2.length && pbtn.length<6;z2++){
      var be2=allb2[z2];
      if(be2.offsetParent===null){ continue; }
      if(norm(be2.textContent).length>0){ continue; }
      var bc='', ba='', bh='', bd='', bl='';
      try{ bc=String(be2.className||'').substring(0,26); }catch(e21){}
      try{ ba=String(be2.getAttribute('aria-label')||'').substring(0,18); }catch(e22){}
      try{ bh=String(be2.innerHTML||'').replace(/ +/g,' ').substring(0,80); }catch(e23){}
      try{ bd=(be2.hasAttribute('disabled')?'D':'')+((be2.getAttribute('aria-disabled')==='true')?'d':''); }catch(e24){}
      try{ var br4=be2.getBoundingClientRect(); bl='~l'+Math.round((br4&&typeof br4.left==='number')?br4.left:0)+',t'+Math.round((br4&&typeof br4.top==='number')?br4.top:0); }catch(e28){}
      pbtn.push('.'+bc+'@'+ba+(bd?'#'+bd:'')+bl+'<'+bh+'>');
    }
    var txt=norm(document.body.innerText);
    var tail=txt.length>200?txt.substring(txt.length-200):txt;
    var note='host='+location.hostname+' | pwd='+(document.querySelector('input[type=password]')?'y':'n')
      +' | btns='+(bt.length>0?bt.join('/'):'-')
      +' | pbtn='+(pbtn.length>0?pbtn.join(' ; '):'-');
    // 结构取样：找到“已购买/已退款”状态文本所在的叶子节点，输出其祖先路径 + 该行完整文本，
    // 用于判断游戏名到底在不在这张表里、以及应该抓哪一层
    var probe='';
    try{
      var every=document.querySelectorAll('*'), tgt=null;
      for(var q=0;q<every.length;q++){
        var e2=every[q], own='';
        for(var w=0;w<e2.childNodes.length;w++){
          var nd=e2.childNodes[w];
          if(nd.nodeType===3){ own+=norm(nd.textContent); }
        }
        if(own.indexOf('已购买')>=0||own.indexOf('已退款')>=0){ tgt=e2; break; }
      }
      if(tgt){
        var chain=[], p2=tgt;
        while(p2 && p2.tagName && chain.length<8){
          var c2='';
          try{ c2=norm(p2.className).replace(/ +/g,'.').substring(0,26); }catch(e3){}
          chain.push(p2.tagName.toLowerCase()+(c2?'.'+c2:''));
          p2=p2.parentElement;
        }
        probe='path='+chain.join(' < ');
      } else {
        probe='未找到“已购买/已退款”状态节点';
      }
      probe=probe+' | pg='+(pg.length>0?pg.join(' ; '):'-')+' | tail='+tail;
    }catch(e5){ probe='ERR:'+String(e5); }
    return JSON.stringify({ titles:titles, more:more, note:note, probe:probe });
  }catch(err){ return JSON.stringify({ titles:[], more:false, note:'ERR:'+String(err) }); }
})()`;
    return js;
  }

  // ================= 界面 =================

  @Builder
  TopBar() {
    Row() {
      Text('‹ 返回')
        .fontSize(16)
        .fontColor(this.pal().COLOR_ACCENT)
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .onClick(() => {
          this.leave();
        })

      Blank()

      Text(this.mode === 'login' ? 'EPIC 登录'
        : (this.mode === 'sync' ? '同步已拥有'
          : (this.tasks.length > 0 ? '自动领取' : '免费游戏')))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().COLOR_TEXT)

      Blank()
    }
    .width('100%')
    .padding({
      top: this.getUIContext().px2vp(this.topInset) + 4,
      bottom: 4
    })
    .backgroundColor(this.pal().COLOR_BG)
  }

  @Builder
  InfoPanel() {
    Column({ space: 6 }) {
      Text(this.curInfo.length > 0 ? this.curInfo : '在此网页中完成操作后点下方“返回”')
        .fontSize(13)
        .fontColor(this.pal().COLOR_TEXT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.failTitles.length > 0 && !this.busy && !this.loginPaused) {
        Text('未成功：' + this.failTitles.join('、') + '，可返回后点击卡片重试')
          .fontSize(12)
          .fontColor(this.pal().COLOR_WARN)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // 失败时把当时页面识别到的关键词/按钮/标题快照展示出来，便于判断是“其实已在库”还是页面异常
      if (this.failTitles.length > 0 && this.diagText.length > 0 && !this.busy && !this.loginPaused) {
        Text('当时页面：' + this.diagText)
          .fontSize(11)
          .fontColor(this.pal().COLOR_SUB)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // 判定轨迹日志：每款“领取成功 / 已在库跳过 / 未确认”各占一行，最新在最上，便于排查误跳过
      if (this.diagLog.length > 0) {
        Column({ space: 2 }) {
          ForEach(this.diagLog.slice(-8).reverse(), (line: string, index: number) => {
            Text(line)
              .fontSize(10)
              .fontColor(this.pal().COLOR_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (line: string, index: number) => index + ':' + line)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 2 })
        .padding(6)
        .backgroundColor(this.pal().COLOR_TRACK)
        .borderRadius(6)
      }

      if (this.mode === 'auto' && this.tasks.length > 0) {
        Row({ space: 14 }) {
          Text('成功 ' + this.okTitles.length)
            .fontSize(12)
            .fontColor(this.pal().COLOR_OK)
          if (this.skipOwned > 0) {
            Text('已库跳过 ' + this.skipOwned)
              .fontSize(12)
              .fontColor(this.pal().COLOR_SUB)
          }
          Text('失败 ' + this.failTitles.length)
            .fontSize(12)
            .fontColor(this.failTitles.length > 0 ? this.pal().COLOR_WARN : this.pal().COLOR_SUB)
          Blank()
          Text(this.busy ? '领取中…' : (this.loginPaused ? '已暂停，待登录' : '已结束'))
            .fontSize(12)
            .fontColor(this.busy ? this.pal().COLOR_SUB : (this.loginPaused ? this.pal().COLOR_WARN : this.pal().COLOR_OK))
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(this.pal().COLOR_BG)
    .border({ width: { bottom: 1 }, color: this.pal().COLOR_LINE })
  }

  @Builder
  BottomBar() {
    Column() {
      Row() {
        Text('↻ 刷新')
          .fontSize(14)
          .fontColor(this.pal().COLOR_SUB)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .onClick(() => {
            if (this.lastUrl.length > 0) {
              try {
                this.controller.loadUrl(this.lastUrl);
              } catch (e) {
              }
            }
          })

        Blank()

        Text(this.bottomLabel())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(150)
          .height(38)
          .backgroundColor(this.loginPaused ? this.pal().COLOR_OK : this.pal().COLOR_ACCENT)
          .borderRadius(19)
          .margin({ right: 16 })
          .onClick(() => {
            this.onBottomAction();
          })
      }
      .width('100%')
      .height(56)
    }
    .width('100%')
    .padding({ bottom: this.getUIContext().px2vp(this.bottomInset) })
    .backgroundColor(this.pal().COLOR_BG)
    .border({ width: { top: 1 }, color: this.pal().COLOR_LINE })
  }

  private bottomLabel(): string {
    if (this.mode === 'login') {
      return '登录完成，返回';
    }
    if (this.mode === 'sync') {
      if (this.busy) {
        return '停止并返回';
      }
      return this.syncCount > 0 ? '返回' : '重新同步';
    }
    if (this.loginPaused) {
      return '继续自动领取';
    }
    if (this.busy) {
      return '停止并返回';
    }
    return '返回';
  }

  private onBottomAction(): void {
    if (this.mode === 'login') {
      this.leave();
      return;
    }
    if (this.mode === 'sync') {
      if (this.busy || this.syncCount > 0) {
        this.leave();
        return;
      }
      // 没读到记录：多半是还没登录，重新走一次同步（会重新加载页面以取最新登录态）
      this.busy = true;
      this.stopped = false;
      this.syncCount = 0;
      this.curInfo = '正在重新读取账号购买记录…';
      this.runSync();
      return;
    }
    if (this.loginPaused) {
      this.resumeAuto();
      return;
    }
    this.leave();
  }

  build() {
    Column() {
      this.TopBar()

      if (this.mode === 'auto' && this.tasks.length > 0) {
        this.InfoPanel()
      } else {
        // 登录 / 浏览 / 同步模式：结果说明；同步模式下附「抓到条目预览 + 页面诊断」，便于核对与排查
        Column({ space: 4 }) {
          Text(this.curInfo.length > 0 ? this.curInfo : '请在下方网页中操作')
            .fontSize(13)
            .fontColor(this.pal().COLOR_SUB)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.mode === 'sync' && !this.busy) {
            if (this.syncPreview.length > 0) {
              Text('抓到条目（前 5 个）：' + this.syncPreview)
                .fontSize(10)
                .fontColor(this.pal().COLOR_SUB)
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            if (this.syncNote.length > 0) {
              Text('页面诊断：' + this.syncNote)
                .fontSize(10)
                .fontColor(this.pal().COLOR_WARN)
                .maxLines(5)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            if (this.syncProbe.length > 0) {
              Text('结构取样：' + this.syncProbe)
                .fontSize(10)
                .fontColor(this.pal().COLOR_WARN)
                .maxLines(6)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .border({ width: { bottom: 1 }, color: this.pal().COLOR_LINE })
      }

      Web({ src: this.urlInit, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .zoomAccess(false)
        .onPageEnd(() => {
          this.webEvent();
        })
        .onErrorReceive(() => {
          this.webEvent();
        })
        .onHttpErrorReceive(() => {
          this.webEvent();
        })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#FFFFFF')

      this.BottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().COLOR_BG)
  }
}
