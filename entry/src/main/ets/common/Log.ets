// Log.ets —— 应用运行日志的持久化读写。
// 关键流程（免费列表拉取、手机限免、自动领取判定）会往里追加带时间戳的日志，
// 用户可在“设置 → 运行日志”里查看、复制发给开发者排查，或一键清空。
// 日志复用与其它状态同一份 preferences（epic_free_state），最多保留 LOG_MAX 条。

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { FREE_STORE } from './EpicFree';

// 日志存档键与最多保留条数
const LOG_KEY: string = 'appLogs';
const LOG_MAX: number = 500;

// 单条日志：t=毫秒时间戳，tag=来源标签，msg=内容
export interface LogEntry {
  t: number;
  tag: string;
  msg: string;
}

// 追加一条日志（写失败静默忽略，不阻断主流程）
export async function appendLog(context: common.Context, tag: string, msg: string): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(LOG_KEY, '[]') as string;
    let arr: LogEntry[] = [];
    try {
      const parsed = JSON.parse(raw) as LogEntry[];
      arr = parsed instanceof Array ? parsed : [];
    } catch (e) {
      arr = [];
    }
    const entry: LogEntry = { t: Date.now(), tag: tag, msg: msg };
    arr.push(entry);
    if (arr.length > LOG_MAX) {
      arr.splice(0, arr.length - LOG_MAX);
    }
    p.putSync(LOG_KEY, JSON.stringify(arr));
    await p.flush();
  } catch (e) {
    // 写日志失败不影响主流程
  }
}

// 读取全部日志（按写入时间正序）
export async function readLogs(context: common.Context): Promise<LogEntry[]> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    const raw = p.getSync(LOG_KEY, '[]') as string;
    const arr = JSON.parse(raw) as LogEntry[];
    return arr instanceof Array ? arr : [];
  } catch (e) {
    return [];
  }
}

// 清空全部日志
export async function clearLogs(context: common.Context): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, { name: FREE_STORE });
    p.putSync(LOG_KEY, '[]');
    await p.flush();
  } catch (e) {
  }
}

// 把一条日志格式化为可读文本：MM-DD HH:mm:ss [tag] msg
export function formatLog(e: LogEntry): string {
  const d = new Date(e.t);
  const two = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' ' +
    two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds()) +
    ' [' + e.tag + '] ' + e.msg;
}
