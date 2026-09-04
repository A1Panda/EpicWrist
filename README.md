# EPIC 喜加一（EpicWrist）

基于 HarmonyOS NEXT（ArkTS）开发的手机应用，用于查看与领取 EPIC 商店每周免费游戏（喜加一），并沉淀一份"历年送过哪些游戏"的历史记录。

## 功能

- **每周免费列表**：自动抓取 EPIC 官方接口，按"现在免费 / 即将免费"分区展示。
- **领取**：两种方式可切换
  - 跳转领取：点击卡片用系统浏览器打开官方领取页；
  - 自动领取：应用内登录 EPIC 后，点悬浮按钮批量代领（成功后标记"已领取"）。
- **后台提醒**：定时后台任务检测新免费游戏并推送通知。
- **加入日历**：把"即将免费"的开领日写为系统日历全天日程并提醒。
- **历史记录**：展示本应用检测到的每期免费，并合并第三方历史源补全自 2018 年起历年全量记录；按月分组、滑动加载更多。
- **历史封面**：第三方历史源不带封面，应用会优先从行内 Steam 链接解析 appid 取 CDN 封面；仍有缺图时按标题到 Steam 商店搜索补图（EPIC 内容接口兜底），结果持久缓存。
- **智感握持**：开启后，"开始自动领取"按钮跟随左右手握持自动落到右下/左下角。

## 界面

| Tab | 内容 |
| --- | --- |
| 游戏 | 现在免费 / 即将免费卡片，右上角手动刷新 |
| 历史 | 按月分组的历史列表，滑到底部加载更多 |
| 设置 | 新免费提醒、加入日历、领取方式、智感握持 |

## 数据来源

- **每周免费**：EPIC 商店官方 storefront 接口（当前与即将档期）。
- **历年历史**：第三方开源数据源 [josephmate/EpicFreeGamesList](https://github.com/josephmate/EpicFreeGamesList)（每周四自动更新），覆盖 2018-12 起每一期。
- **历史封面**：Steam CDN（`cdn.cloudflare.steamstatic.com`）横版 header 图；解析失败的条目运行时按标题走 Steam 商店搜索接口补图。
- 本地数据（已领取名单、历史、封面缓存、设置）均存于 preferences。

## 工程结构

```
entry/src/main/ets
├── common/
│   ├── EpicFree.ets       # 抓取/解析 EPIC 免费列表、通知与日历写入等
│   └── FreeHistory.ets    # 本地历史、第三方历史合并、封面解析与补图缓存
├── entryability/          # 入口 Ability
├── entrybackupability/    # 备份能力
├── pages/
│   ├── Index.ets          # 主页面：游戏 / 历史 / 设置 三 Tab
│   └── Claim.ets          # 领取会话页：网页登录与批量自动领取
└── workability/           # 定时后台检测任务（新免费提醒）
```

## 构建

使用 DevEco Studio（HarmonyOS NEXT SDK）。命令行构建：

```powershell
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio\sdk'
& 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p product=default --no-daemon
```

产物位于 `entry/build` 下。

## 权限

- `ohos.permission.INTERNET`：拉取免费列表、历史与封面。
- `ohos.permission.DETECT_GESTURE`：智感握持感知左右手。
- `ohos.permission.WRITE_CALENDAR` / `READ_CALENDAR`：把免费档期写入系统日历（首次开启时向用户申请）。

## 免责声明

本项目仅用于学习交流，非官方产品。自动领取依赖网页自动化，请勿滥用；EPIC 账号与游戏均归 EPIC Games 所有。第三方历史数据版权归原数据源作者。
