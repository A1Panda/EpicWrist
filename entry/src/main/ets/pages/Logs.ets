// Logs.ets —— 运行日志查看页。
// 展示应用持久化日志（最新在上），支持“复制全部”（写系统剪贴板，便于粘贴发给开发者）与“清空”。

import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { LogEntry, readLogs, clearLogs, formatLog } from '../common/Log';
import { THEME_FOLLOW, AppPal, appPal } from '../common/Theme';

// 外观模式：0=跟随系统 1=固定浅色 2=固定深色；页面取色统一走 pal()（浅/深共用一套键名）

@Entry
@Component
struct Logs {
  @State list: LogEntry[] = [];
  @StorageProp('safeTop') topInset: number = 0;
  @StorageLink('themeMode') themeMode: number = THEME_FOLLOW;
  @StorageProp('sysDark') sysDark: boolean = false;

  // 深浅色当前有效取色板：由外观模式 + 系统真实明暗共同决定
  private pal(): AppPal {
    return appPal(this.themeMode, this.sysDark);
  }

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    readLogs(getContext(this) as common.Context).then((arr: LogEntry[]) => {
      this.list = arr;
    }).catch(() => {
      this.list = [];
    });
  }

  // 复制全部日志到系统剪贴板（最新在上），供粘贴发给开发者
  private copyAll(): void {
    let text: string = '';
    for (let i = this.list.length - 1; i >= 0; i--) {
      text = text + formatLog(this.list[i]) + '\n';
    }
    if (text.length === 0) {
      promptAction.showToast({ message: '暂无日志' });
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '已复制 ' + this.list.length + ' 条日志' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private clearAll(): void {
    clearLogs(getContext(this) as common.Context).then(() => {
      this.list = [];
      promptAction.showToast({ message: '日志已清空' });
    }).catch(() => {
    });
  }

  build() {
    Column() {
      // 顶栏：返回 + 标题 + 复制 + 清空
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor(this.pal().COLOR_ACCENT)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .onClick(() => {
            router.back();
          })

        Blank()

        Text('运行日志')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().COLOR_TEXT)

        Blank()

        Text('复制')
          .fontSize(14)
          .fontColor(this.pal().COLOR_ACCENT)
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.copyAll();
          })

        Text('清空')
          .fontSize(14)
          .fontColor(this.pal().COLOR_WARN)
          .padding({ left: 8, right: 16, top: 10, bottom: 10 })
          .onClick(() => {
            this.clearAll();
          })
      }
      .width('100%')
      .padding({ top: this.getUIContext().px2vp(this.topInset) + 4, bottom: 4 })
      .backgroundColor(this.pal().COLOR_BG)
      .border({ width: { bottom: 1 }, color: this.pal().COLOR_LINE })

      if (this.list.length === 0) {
        Column() {
          Text('暂无日志')
            .fontSize(13)
            .fontColor(this.pal().COLOR_SUB)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 4 }) {
            ForEach(this.list.slice().reverse(), (e: LogEntry) => {
              Text(formatLog(e))
                .fontSize(11)
                .fontColor(this.pal().COLOR_LOG)
                .width('100%')
            }, (e: LogEntry, index: number) => index + '_' + e.t)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().COLOR_BG)
  }
}
