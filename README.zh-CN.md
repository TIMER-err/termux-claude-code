# termux-claude-code

[English](README.md) · **简体中文**

在 Termux（Android，aarch64）上安装 [Claude Code](https://claude.com/claude-code)。

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh | bash
```

装完开一个新 shell，运行 `claude` 即可。也可以先克隆仓库把 `install.sh` 读一遍再执行
—— 对任何要管道进 shell 的东西，这都是更好的习惯。

## 为什么需要

Anthropic 的 `linux-arm64` 构建是用 [Bun](https://bun.sh) 打包的可执行文件，链接的是
**glibc**。Android 用的是 **bionic**，所以它在 Termux 下根本无法执行 —— 这是两套不同
的 libc ABI，不是缺个依赖。npm 包也绕不过去，它下载的还是同一个二进制。

常见的绕法是上 **proot** 容器，确实能跑起来，但打字很难受：**每敲一个字符要几百毫秒
才显示出来**。这并不是 proot 的 syscall 拦截造成的 —— 在容器里跑命令、跑 tool call
都很正常，而且在同一个容器里改用**本项目**安装，延迟就消失了。问题出在那个打包好的
二进制上，不在容器。

所以本项目不去运行那个二进制，而是把 JavaScript 从里面重新拆出来，交给 Termux 原生的
`bun` 运行：一个普通的 Android 进程，用你真正的 `$HOME`，40 MB。如果你本来就住在
proot 里，装在那边一样好用。

## 工作原理

1. 下载官方 `linux-arm64` 发布版，对照 release manifest 校验 SHA-256。
2. 用 `objcopy` 抽出 ELF 里的 `.bun` 段 —— 即 Bun standalone 的 module-graph 数据块，
   以 `\n---- Bun! ----\n` 标记收尾。
3. 解析该数据块末尾的 module-graph 表，把每条记录还原成真实文件（约 1800 个：ESM
   chunk、skills、文档、原生模块）。
4. 把 Bun 的 `/$bunfs/root/` 虚拟文件系统路径改写为相对路径，并 patch 掉硬编码的
   `/tmp` —— Termux 的 app 进程对它没有写权限。
5. 在 `~/.local/bin/claude` 安装一个 wrapper，执行 `bun cli.js`。

### module-graph 格式

Claude Code 在 **2.1.2xx** 前后换成了 *code-split* 打包：不再有单个 `cli.js`，而是约
1800 个 ESM chunk 加内嵌资源，由段末 52 字节定长记录组成的表来索引。

```
struct CompiledModuleGraphFile {   // 52 字节
    StringPointer name;            // {u32 offset, u32 length}
    StringPointer contents;
    StringPointer sourcemap;
    StringPointer bytecode;
    /* loader / encoding / module_format 标志位 */
};
```

所有偏移都相对于数据块起始位置 **加 8**；入口点是名为 `/$bunfs/root/cli` 的模块。

从旧脚本移植过来的话注意：2.1.2xx 之前那套做法 —— 找到
`file:///$bunfs/root/src/entrypoints/cli.js` 标记、在第一个 NUL 处截断 —— 现在会落在
一个约 1 KB 的辅助 chunk 上，产物是一个能正常解析、但一运行就立即返回的 `cli.js`。

### 为什么用 Bun 而不是 Node

跑在 Node 上*差一点*就能成：shim 掉 `globalThis.Bun`，把 `import.meta.require` 换成
`createRequire`，再把 `Bun.zstdDecompress*` 映射到 `node:zlib`。但 `--help` 会挂在
`ERR_REQUIRE_CYCLE_MODULE` 上 —— bundle 会以同步方式穿过循环依赖加载 ESM chunk，Bun
容忍这种做法，`require(esm)` 不容忍。而 Termux 直接有 `bun` 包（`pkg install bun`），
能原封不动地跑这个 bundle。

## 用法

```
install.sh [install|uninstall] [选项]
```

不带动作时默认为 `install`；脚本不会有任何提问，可以放心管道执行。

| 选项 | 等价环境变量 | 作用 |
| --- | --- | --- |
| `-r, --release VERSION` | `CLAUDE_RELEASE_VERSION` | 指定版本，而不是解析 `latest`。 |
| `-b, --binary PATH` | `CLAUDE_LOCAL_BINARY` | 使用已经下载好的二进制。 |
| `-f, --force` | `FORCE_INSTALL_CC=1` | 同版本也强制重装。 |
| `-h, --help` | — | 打印选项列表并退出。 |

升级就是重新跑一遍 `install`：版本一致时会跳过那 205 MB 的下载。要通过一键命令传参，
用 `bash -s --`：

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh \
  | bash -s -- --force
```

## 卸载

```bash
bash install.sh uninstall
```

会删除 `~/.local/bin/claude` 和 `~/.local/lib/claude-code/`。`~/.claude` 里的登录状态
和设置会保留，安装时写进 shell rc 文件的那些配置块也会保留（marker 为
`# >>> cc-termux PATH >>>` 和 `# >>> claude-code-termux-tmpdir >>>`）—— 想清掉的话手动
删即可。

## 说明

- 依赖，缺失时会用 `pkg` 自动安装：`curl` · `ripgrep` · `which` · `python` ·
  `binutils` · `bun` · `ca-certificates`。安装过程需要约 250 MB 空闲空间，装完占 40 MB。
- wrapper 会把 `TMPDIR`/`CLAUDE_*TMPDIR` 指到 `$PREFIX/tmp`，设置
  `USE_BUILTIN_RIPGREP=0`（内置的 `rg` 不在解包出的 graph 里），把 TLS 证书指向
  `$PREFIX/etc/tls/cert.pem`，并关闭自动更新 —— 否则它会把当前安装替换成那个跑不起来
  的二进制。
- 解包读的是 Bun 内部的 standalone 格式，因此对版本敏感。上游若改变记录布局，脚本会
  直接报错退出，而不是装出一个坏掉的版本。
- bundle 里引用的少数几个 Bun API（`Bun.serve`、`Bun.Terminal`、`Bun.SQL`）来自
  Anthropic 自己的 Bun 分支，都在可选功能后面，正常 CLI 路径不会走到。
- Claude Code 是专有软件，受
  [Anthropic 商业条款](https://code.claude.com/docs/en/legal-and-compliance)约束。
  本仓库不含任何 Anthropic 代码 —— 只有一个脚本，负责下载官方发布版并在本地为一个官方
  不支持的平台重新打包。
