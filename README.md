# Burrow

The MacBook notch is a burrow, and your coding agents live in it.

Each agent — Claude Code, Codex, OpenCode, Antigravity — has a small pixel pet that peeks out from behind the notch while it works. A pet with news steps out. One that needs you gets a night light at its feet. A turn that failed leaves an ember by the pet, and a finished one a spark, until you look.

<p align="center"><img src="docs/notch.png" width="560" alt="Four pets beside the notch, each with a health bar under its feet"></p>

Under each pet runs a thin health bar: how much of that agent's weekly quota is left. It is green while there is plenty, orange under 30%, red under 15%. Claude's comes from Claude Desktop's own usage file, Codex's and Antigravity's from their own servers with their own logins, and OpenCode's from its DeepSeek and OpenRouter balances. Burrow checks every 15 minutes; an agent it can't read gets no bar.

Hover the notch and the pets fly into the den: one block per agent, every conversation in two lines — its title, and what it is doing right now. Under each pet's name is the quota it has left, or OpenCode's balances in yuan and dollars.

<p align="center"><img src="docs/den.png" width="440" alt="The den"></p>

When an agent asks to run a command, the card shows the command in the biggest type, marks the dangerous words, and says in one plain line what it will do. Allow it once, or deny it.

<p align="center"><img src="docs/approval.png" width="440" alt="An approval card"></p>

The gear turns the den over. Its back is all the settings there are: which agents are connected, the sounds, opening at login, and shortcuts.

<p align="center"><img src="docs/settings.png" width="440" alt="The back of the den: settings"></p>

## Build

macOS 14 or later, Xcode installed.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh
```

The app is `.build/release/Burrow.app`; move it to `/Applications`. Without Xcode, the `build` workflow builds the same app on GitHub Actions and keeps it as the `Burrow` artifact for a week. Burrow adds its hooks to the agents it finds; you can reconnect or unplug each one on the back of the den.

## Credits

- Burrow began as a fork of [CodeIsland](https://github.com/wxtsky/CodeIsland) by wxtsky (MIT).
- The pixel pets are drawn after [claude-desktop-buddy](https://github.com/anthropics/claude-desktop-buddy) (MIT).
- Claude Code, Codex, OpenCode and Antigravity, and their icons, belong to their owners. Burrow is not affiliated with any of them.

## 中文

刘海是一个洞，你的编程 agent 住在里面。Claude Code、Codex、OpenCode、Antigravity 各有一只像素小宠物，干活时从刘海后面探出头；有消息的走出来，需要你的脚下亮一盏夜灯。每只宠物脚下有一根细血条，是这家 agent 本周额度还剩多少：够用是绿的，不到 30% 变橙，不到 15% 变红；OpenCode 看的是 DeepSeek 和 OpenRouter 的余额。鼠标移到刘海上，小窝打开，每个对话两行：标题和它正在做什么；宠物名字下面写着还剩多少。批准卡把命令写得最大，危险的词标红，下面一行说清它要做什么。点齿轮，小窝翻到背面，就是全部设置。

构建见上面的 Build，MIT 许可。

## License

MIT — see [LICENSE](LICENSE).
