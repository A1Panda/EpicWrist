// Theme.ets —— 深浅色主题中枢。
// 职责：
//  - 双端色板：深色保留应用原有“近黑玻璃”观感；浅色为冷白灰玻璃观感，同一套键名两套取值；
//  - 模式语义：0=跟随系统 / 1=固定浅色 / 2=固定深色（选择持久化在 epic_free_state 的 themeMode）；
//  - 生效方式：应用级 setColorMode 切换系统材质/系统栏跟随模式，AppStorage('themeMode') 驱动页面取色；
//  - 外观栏跟随当前有效模式：深色=浅色图标，浅色=深色图标（window 系统栏属性显式设置）。

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';

export const THEME_FOLLOW: number = 0;
export const THEME_LIGHT: number = 1;
export const THEME_DARK: number = 2;
const THEME_KEY: string = 'themeMode';
const STORE: string = 'epic_free_state';

// 页面用色键：深/浅各给一套，取色一律走 appPal(mode, sysDark) 之后的三态解析。
export interface AppPal {
  COLOR_BG: string;
  COLOR_CARD: string;
  // 长列表卡片（免费/历史）专用“不透明纯色”底：不依赖实时背景模糊，避免逐卡模糊的性能开销
  COLOR_CARD_SOLID: string;
  COLOR_HAIR: string;
  COLOR_IMG_BG: string;
  COLOR_IMG_FG: string;
  COLOR_BADGE: string;
  COLOR_TEXT: string;
  COLOR_SUB: string;
  COLOR_ACCENT: string;
  COLOR_OK: string;
  COLOR_WARN: string;
  COLOR_STALE: string;
  COLOR_LINE: string;
  COLOR_TRACK: string;
  COLOR_LOG: string;
}

// 系统栏外观键：bar=窗口/系统栏底色，content=系统栏图标与文字颜色
export class ChromePal {
  bar: string;
  content: string;

  constructor(bar: string, content: string) {
    this.bar = bar;
    this.content = content;
  }
}

// 深色 = 应用既有近黑冷底 + 白 5%~19% 极透玻璃（保持原来的观感数值不变）
export const PAL_DARK: AppPal = {
  COLOR_BG: '#05070D',
  COLOR_CARD: '#0DFFFFFF',
  COLOR_CARD_SOLID: '#12161F',
  COLOR_HAIR: '#30FFFFFF',
  COLOR_IMG_BG: '#111722',
  COLOR_IMG_FG: '#5A6570',
  COLOR_BADGE: '#33FFFFFF',
  COLOR_TEXT: '#FFFFFF',
  COLOR_SUB: '#8E8E93',
  COLOR_ACCENT: '#0A59F7',
  COLOR_OK: '#34C759',
  COLOR_WARN: '#FF9500',
  COLOR_STALE: '#F5A623',
  COLOR_LINE: '#2C2C2E',
  COLOR_TRACK: '#101010',
  COLOR_LOG: '#C7C7CC'
};

// 浅色 = 冷白灰页面 + 白色磨砂卡 + 黑 8%~15% 细描边，文字用冷深灰
export const PAL_LIGHT: AppPal = {
  COLOR_BG: '#F1F3F6',
  COLOR_CARD: '#F0FFFFFF',
  COLOR_CARD_SOLID: '#FFFFFF',
  COLOR_HAIR: '#24000000',
  COLOR_IMG_BG: '#E3E8EF',
  COLOR_IMG_FG: '#4B5563',
  COLOR_BADGE: '#15000000',
  COLOR_TEXT: '#191C22',
  COLOR_SUB: '#6B7076',
  COLOR_ACCENT: '#0A59F7',
  COLOR_OK: '#1F9D55',
  COLOR_WARN: '#C06A00',
  COLOR_STALE: '#A96A00',
  COLOR_LINE: '#E3E5EA',
  COLOR_TRACK: '#12000000',
  COLOR_LOG: '#565C62'
};

// 三态 → 是否深色：跟随系统时以“系统真实色模式”为准
export function modeIsDark(mode: number, sysDark: boolean): boolean {
  if (mode === THEME_LIGHT) {
    return false;
  }
  if (mode === THEME_DARK) {
    return true;
  }
  return sysDark;
}

export function appPal(mode: number, sysDark: boolean): AppPal {
  return modeIsDark(mode, sysDark) ? PAL_DARK : PAL_LIGHT;
}

// 系统当前真实色模式（暗=深色页、亮=浅色页）。
// 用 resourceManager 读取设备真实配置，避免应用级 setColorMode 覆盖后 config 被改写的问题；
// 页面/Ability 任一带 Context 都能调用（Context 上都带 resourceManager）。
export function systemDarkOf(ctx: common.Context): boolean {
  try {
    const cfg = ctx.resourceManager.getConfigurationSync();
    return cfg.colorMode === resourceManager.ColorMode.DARK;
  } catch (e) {
    return false;
  }
}

// 读取持久化外观模式（EntryAbility 启动时同步读，赶在首帧渲染前定色模式）
export function readThemePref(ctx: common.Context): number {
  try {
    const p = preferences.getPreferencesSync(ctx, { name: STORE });
    const v = p.getSync(THEME_KEY, THEME_FOLLOW) as number;
    if (v === THEME_LIGHT || v === THEME_DARK || v === THEME_FOLLOW) {
      return v;
    }
  } catch (e) {
  }
  return THEME_FOLLOW;
}

export function saveThemePref(ctx: common.Context, mode: number): void {
  try {
    const p = preferences.getPreferencesSync(ctx, { name: STORE });
    p.putSync(THEME_KEY, mode);
    p.flush().catch(() => {
    });
  } catch (e) {
  }
}

// 把应用色模式同步给系统：固定浅/深、或 NOT_SET=恢复跟随系统
export function applyColorMode(ctx: common.Context, mode: number): void {
  try {
    const app = ctx.getApplicationContext();
    if (mode === THEME_LIGHT) {
      app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else if (mode === THEME_DARK) {
      app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else {
      app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
  } catch (e) {
  }
}

// 系统栏外观：深色页面用浅色图标、浅色页面用深色图标；窗口底色与页面一致避免露边
export function chromeColors(dark: boolean): ChromePal {
  if (dark) {
    return new ChromePal('#0E1520', '#F2F5FA');
  }
  return new ChromePal('#F1F3F6', '#0E1218');
}

export function paintWindow(win: window.Window, dark: boolean): void {
  try {
    const c = chromeColors(dark);
    win.setWindowBackgroundColor(c.bar);
    win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: c.content,
      navigationBarContentColor: c.content
    }).then(() => {
    }).catch(() => {
    });
  } catch (e) {
  }
}

// 设置页切换入口：持久化 → 更新 AppStorage（触发页面重绘）→ 系统色模式 → 外观栏重刷
export function applyModeAndRefreshChrome(ctx: common.Context, mode: number): void {
  saveThemePref(ctx, mode);
  AppStorage.setOrCreate<number>('themeMode', mode);
  applyColorMode(ctx, mode);
  // 跟随系统时判断“系统真实明暗”：先用 EntryAbility 持续维护的 sysDark，缺失时现场查询
  const sysDark: boolean = AppStorage.get<boolean>('sysDark') !== undefined ?
    (AppStorage.get<boolean>('sysDark') as boolean) : systemDarkOf(ctx);
  const dark: boolean = modeIsDark(mode, sysDark);
  try {
    window.getLastWindow(ctx).then((win: window.Window) => {
      paintWindow(win, dark);
    }).catch(() => {
    });
  } catch (e) {
  }
}
