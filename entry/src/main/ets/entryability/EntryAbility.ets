import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;
// 与首页背景一致的深色，避免状态栏/导航条露出黑边
const BAR_COLOR: string = '#0E1520';
const BAR_CONTENT_COLOR: string = '#F2F5FA';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
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

  // 方案：窗口全屏布局，但保留系统栏显示（顶部时间栏、底部导航/手势条）。
  // 系统栏做成“透明 + 浅色图标”悬浮在深色页面之上，视觉连续不露黑；
  // 页面再按 safeTop/safeBottom 避让，让内容不与时间栏/手势条重叠。
  private applyImmersive(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      // 窗口底色与页面一致，避免全屏切换瞬间边缘露黑
      win.setWindowBackgroundColor(BAR_COLOR);
      // 顺序关键：先全屏、再设定系统栏透明浅色样式，全部生效后才刷新避让区缓存，
      // 否则会缓存到“系统栏样式尚未应用”时的高度，导致页面避让不准。
      win.setWindowLayoutFullScreen(true)
        .then(() => win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: BAR_CONTENT_COLOR,
          navigationBarContentColor: BAR_CONTENT_COLOR
        }))
        .then(() => {
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