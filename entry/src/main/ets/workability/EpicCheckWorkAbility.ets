// EpicCheckWorkAbility.ets —— 后台“新免费检测”任务。
// 由用户开启首页“新免费提醒”开关后，通过 workScheduler.startWork 注册；
// 系统按周期与电量/网络等条件在后台拉起本 Extension，拉取 EPIC 接口，
// 若发现“现在免费”里有已见名单之外的新增游戏，则发系统通知。

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import {
  readSeen,
  saveSeen,
  freshTitles,
  mergeSeen,
  parseFree,
  requestFreeText,
  publishFreeNotice,
  GameItem
} from '../common/EpicFree';

const DOMAIN: number = 0x0000;
const TAG: string = 'EpicCheckWork';

export default class EpicCheckWorkAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStart workId=%{public}d', work.workId);
    // 系统每次拉起都执行一轮检测；不 await，避免阻塞调度回调
    this.doCheck();
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStop workId=%{public}d', work.workId);
  }

  // 单轮检测：读名单 → 拉接口 → 解析 → 对新增发通知 → 更新名单
  private async doCheck(): Promise<void> {
    try {
      const ctx: common.Context = this.context;
      const seen: string[] = await readSeen(ctx);
      const text: string = await requestFreeText();
      const lists = parseFree(text);
      if (lists === null) {
        hilog.warn(DOMAIN, TAG, 'payload invalid, skip');
        return;
      }
      const nowArr: GameItem[] = lists.nowArr;
      if (nowArr.length === 0) {
        return;
      }
      // 从未建档（例如新装后先触发的是后台任务）只存档、不打扰；
      // 已有名单后，仅对真正新增的免费游戏发通知
      if (seen.length > 0) {
        const fresh: string[] = freshTitles(nowArr, seen);
        if (fresh.length > 0) {
          await publishFreeNotice(fresh, false);
          hilog.info(DOMAIN, TAG, 'notify new free, count=%{public}d', fresh.length);
        }
      }
      const merged: string[] = mergeSeen(seen, nowArr);
      if (merged.length !== seen.length) {
        await saveSeen(ctx, merged);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'doCheck failed: %{public}s', JSON.stringify(e));
    }
  }
}
