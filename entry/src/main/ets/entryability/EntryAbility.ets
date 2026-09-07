import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import {
  THEME_FOLLOW,
  readThemePref,
  systemDarkOf,
  applyColorMode,
  modeIsDark,
  paintWindow
} from '../common/Theme';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWin: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 先记录“系统真实色模式”（必须在 setColorMode 覆盖前取值，之后 AppStorage 始终保持系统值，
    // “跟随系统”模式用它判断真实明暗；固定浅/深模式不受系统后续切换影响）。
    const sysDark: boolean = systemDarkOf(this.context);
    AppStorage.setOrCreate<boolean>('sysDark', sysDark);
    // 读取用户选择的外观模式并同步给系统：赶在首帧渲染前让资源/系统材质落在正确的色模式上
    const mode: number = readThemePref(this.context);
    AppStorage.setOrCreate<number>('themeMode', mode);
    applyColorMode(this.context, mode);
    hilog.info(DOMAIN, 'testTag', 'Ability onCreate, themeMode=%{public}d sysDark=%{public}s', mode, sysDark);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 注意：必须在 loadContent 成功之后操作主窗口。
      // 过早调用 getMainWindowSync 会因窗口未就绪而抛异常，导致沉浸式设置全部失效。
      this.applyImmersive(windowStage);
    });
  }

  // 系统切换深浅色（仅“跟随系统”模式下需要响应）：刷新 AppStorage 驱动页面重绘，并重刷系统栏外观
  onConfigurationUpdate(newConfig: Configuration): void {
    const mode: number = AppStorage.get<number>('themeMode') !== undefined ?
      (AppStorage.get<number>('themeMode') as number) : THEME_FOLLOW;
    if (mode === THEME_FOLLOW) {
      AppStorage.setOrCreate<boolean>('sysDark',
        newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      this.refreshChrome();
    }
  }

  // 当前页面取色用的“有效深色态”：固定模式看选择，跟随模式看系统
  private effDark(): boolean {
    const mode: number = AppStorage.get<number>('themeMode') !== undefined ?
      (AppStorage.get<number>('themeMode') as number) : THEME_FOLLOW;
    const sysDark: boolean = AppStorage.get<boolean>('sysDark') !== undefined ?
      (AppStorage.get<boolean>('sysDark') as boolean) : systemDarkOf(this.context);
    return modeIsDark(mode, sysDark);
  }

  private refreshChrome(): void {
    if (this.mainWin !== null) {
      paintWindow(this.mainWin, this.effDark());
    }
  }

  // 方案：窗口全屏布局，但保留系统栏显示（顶部时间栏、底部导航/手势条）。
  // 系统栏做成“透明 + 随主题的图标色”悬浮在页面之上，视觉连续不露色块；
  // 页面再按 safeTop/safeBottom 避让，让内容不与时间栏/手势条重叠。
  private applyImmersive(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.mainWin = win;
      // 窗口底色与页面一致，避免全屏切换瞬间边缘露色
      paintWindow(win, this.effDark());
      // 顺序关键：先全屏、再设定系统栏透明样式，全部生效后才刷新避让区缓存，
      // 否则会缓存到“系统栏样式尚未应用”时的高度，导致页面避让不准。
      win.setWindowLayoutFullScreen(true)
        .then(() => {
          // 全屏后再刷一次系统栏（paintWindow 已在全屏前设置过，全屏后属性保持，此处仅为稳妥重刷）
          paintWindow(win, this.effDark());
          // 此刻系统栏样式已确定，刷新避让高度供页面做 padding
          this.cacheSafeAreas(win);
        })
        .catch((err: Error) => {
          hilog.warn(DOMAIN, 'testTag', 'Set immersive failed: %{public}s', err.message);
          // 即使个别接口失败也刷新一次缓存，保证页面拿到的值尽量贴近实际
          this.cacheSafeAreas(win);
        });
      // 摄像头挖孔/导航区尺寸变化时（横竖屏切换等）同步刷新避让缓存
      win.on('avoidAreaChange', () => {
        this.cacheSafeAreas(win);
      });
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'Apply immersive failed: %{public}s', JSON.stringify(e));
    }
  }

  // 把“顶部摄像头挖孔/状态栏避让区”与“底部导航区/手势指示条”高度（px）存入 AppStorage，
  // 供页面用 px2vp 转成 vp 后做避让 padding（数值为 0 说明对应区域已隐藏/不存在）
  private cacheSafeAreas(win: window.Window): void {
    try {
      const cutout: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      // 顶部取摄像头挖孔与系统状态栏两者中的较大值
      const topH: number = Math.max(cutout.topRect.height, system.topRect.height);
      AppStorage.setOrCreate<number>('safeTop', topH);
      // 底部取三键导航区与手势指示条两者中的较大值（系统栏隐藏时二者为 0）
      const navInd: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottomH: number = Math.max(navInd.bottomRect.height, system.bottomRect.height);
      AppStorage.setOrCreate<number>('safeBottom', bottomH);
      hilog.info(DOMAIN, 'testTag', 'AvoidArea top=%{public}d bottom=%{public}d',
        topH, bottomH);
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'Query avoid area failed');
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
