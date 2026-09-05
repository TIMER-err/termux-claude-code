# termux-claude-code

[English](README.md) · **简体中文**

在 Termux（Android，aarch64）上安装 [Claude Code](https://claude.com/claude-code)。

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh | bash
```

装完开一个新 shell，运行 `claude` 即可。

也可以先克隆下来把脚本读一遍再执行 —— 对任何要管道进 shell 的东西，这都是更好的习惯：

```bash
git clone https://github.com/TIMER-err/termux-claude-code.git
bash termux-claude-code/install.sh
```

## 为什么需要这个项目

Anthropic 提供了 `linux-arm64` 构建，但它是用 [Bun](https://bun.sh) 打包的单文件
可执行程序，链接的是 **glibc**。Android 用的是 **bionic** libc，所以这个二进制在
Termux 下根本无法执行 —— 这不是缺个依赖、`pkg install` 一下就能解决的问题，而是
两套不同的 libc ABI。npm 包也绕不过去：`@anthropic-ai/claude-code` 没有任何依赖，
只有一个 `postinstall` 脚本，去下载的还是同一个平台二进制。

常见的绕法是上 **proot** 容器 —— `proot-distro install ubuntu`，然后在里面对着真正
的 glibc 装 Claude Code。这条路确实能跑起来，但实际用起来很难受：**每敲一个字符，
都要几百毫秒才显示出来。** 打一句 prompt 的手感，像是在一条很差的 SSH 链路上打字。

这一点值得说清楚，因为最容易想到的那个解释是错的。`proot` 是基于 ptrace 的用户态
chroot，于是人们会想当然地认为是它的 syscall 拦截拖垮了一切 —— 但在容器里跑命令
其实完全可以接受。tool call、`rg`、`git`、子进程，都没问题。这个延迟只出现在二进制
自身的交互式输入路径上。

证据是：在**同一个** proot 容器里改用**本项目**安装，延迟就消失了。同样的容器、
同样的 ptrace 开销，输入却是跟手的。所以容器本身从来就不是真正的问题所在 ——
问题出在那个打包好的二进制上。

不过本项目这两条路都不走。它不去运行那个二进制，也不需要容器：而是把 JavaScript 从
可执行文件里重新拆出来，交给 `bun` 运行。在纯 Termux 环境下，它就是一个普通的
Android 进程，用你真正的 `$HOME`，安装体积 40 MB —— 而不是多出一个要单独更新、
文件系统还和你自己那套分开的 Linux rootfs。而如果你本来就住在 proot 里，装在那边
一样好用。

## 工作原理

1. 下载官方 `linux-arm64` 发布版，并对照 release manifest 校验 SHA-256。
2. 用 `objcopy` 把 ELF 里的 `.bun` 段抽出来 —— 这就是 Bun standalone 的 module-graph
   数据块，以 `\n---- Bun! ----\n` 结尾标记收尾。
3. 解析该数据块末尾的 module-graph 表，把每一条记录还原成真实文件（约 1800 个：
   ESM chunk、skills、文档、原生模块）。
4. 把 Bun 的 `/$bunfs/root/` 虚拟文件系统路径改写成真实的相对路径。
5. patch 掉硬编码的 `/tmp` 路径 —— Termux 的 app 进程对 `/tmp` 没有写权限。
6. 在 `~/.local/bin/claude` 安装一个 wrapper，用正确的环境变量执行 `bun cli.js`。

### module-graph 格式

Claude Code 在 **2.1.2xx** 前后换成了 *code-split* 打包。`.bun` 段里不再是一个大
`cli.js`，而是约 1800 个独立的 ESM chunk 加上内嵌资源，由段末一张 52 字节定长记录
的表来索引：

```
struct CompiledModuleGraphFile {   // 52 字节
    StringPointer name;            // {u32 offset, u32 length}
    StringPointer contents;
    StringPointer sourcemap;
    StringPointer bytecode;
    /* loader / encoding / module_format 标志位 */
};
```

所有 `StringPointer` 的偏移都是相对于数据块起始位置 **加 8**。入口点是名为
`/$bunfs/root/cli` 的模块。

> **给从旧脚本移植过来的人提个醒。** 2.1.2xx 之前的做法 —— 找到
> `file:///$bunfs/root/src/entrypoints/cli.js` 这个标记，取它之后的数据，在第一个
> NUL 处截断 —— 在新格式下会**悄无声息地失败**。那个标记如今只是残留在一张字符串
> 表里，离任何代码都有约 78 MB 远，读出来的长度前缀是垃圾值，而兜底的 NUL 扫描会
> 落在一个约 1 KB 的辅助 chunk 上。最终产物是一个能正常解析、但一运行就**立即
> 返回**的 `cli.js`。

### 为什么用 Bun 而不是 Node

把解包后的 bundle 跑在 Node 上*差一点*就能成：shim 掉 `globalThis.Bun`，把
`import.meta.require` 改写成 `createRequire`，再把 `Bun.zstdDecompress*` 映射到
`node:zlib`。这样 `claude --version` 是能用的。但 `--help` 会挂在
`ERR_REQUIRE_CYCLE_MODULE` 上 —— 打包器生成的 `import.meta.require()` 会以同步方式
穿过循环依赖加载 ESM chunk，Bun 容忍这种做法，Node 的 `require(esm)` 不容忍。要修
就得静态改写 300 多处调用点，还得指望改变求值顺序不会引发别的问题。

而 Termux 直接有 `bun` 的软件包（`pkg install bun`），能原封不动地跑这个 bundle ——
不用 shim，不用 `npm install`，磁盘上还小约 8 MB。所以：用 Bun。

## 依赖

缺失时会通过 `pkg` 自动安装：

`curl` · `ripgrep` · `which` · `python` · `binutils` · `bun` · `ca-certificates`

安装过程大约需要 250 MB 空闲空间（205 MB 下载、约 128 MB 的段数据、40 MB 最终产物）。
安装后的目录树为 **40 MB**。

## 选项

`bash install.sh [install|uninstall] [选项]` —— 不写动作时默认为 `install`。

| 选项 | 等价环境变量 | 作用 |
| --- | --- | --- |
| `-r, --release VERSION` | `CLAUDE_RELEASE_VERSION` | 指定版本，而不是解析 `latest`。 |
| `-b, --binary PATH` | `CLAUDE_LOCAL_BINARY` | 使用已经下载好的二进制，不再联网获取。 |
| `-f, --force` | `FORCE_INSTALL_CC=1` | 即使版本标记已匹配也强制重装。 |
| `-h, --help` | — | 打印同样的这份列表并退出。 |

想通过 curl 一键命令传选项，用 `bash -s --`：

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh \
  | bash -s -- --force
```

205 MB 的下载是整个流程里最慢、也最容易失败的一步。如果中途断了，重试时 `curl -C -`
会续传；也可以自己先下好再把路径传进去：

```bash
bash install.sh --binary ~/Download/claude
```

## 卸载

```bash
bash install.sh uninstall
```

会删除 `~/.local/bin/claude` 和 `~/.local/lib/claude-code`。`~/.claude` 里的登录凭据
和设置、以及写进 shell rc 文件的那些配置块，都会原样保留。

## 目录结构

```
~/.local/bin/claude          wrapper 脚本
~/.local/lib/claude-code/    解包出的 module graph（cli.js + 约 1800 个文件）
```

wrapper 会把 `TMPDIR`/`CLAUDE_CODE_TMPDIR`/`CLAUDE_TMPDIR` 指到 `$PREFIX/tmp` 下，
强制 `USE_BUILTIN_RIPGREP=0`（内置的 `rg` 不在解包出的 graph 里，所以改用 Termux 自己
装的），关闭自动更新 —— 否则它会把当前安装替换成那个根本跑不起来的二进制 —— 并把
TLS 证书指向 `$PREFIX/etc/tls/cert.pem`。

## 注意事项

- **自动更新是被迫关闭的。** 要升级请重新跑一遍 `install.sh`。
- **解包过程对版本敏感。** 它读的是 Bun 内部的 standalone 格式。上游 Bun 升级可能会
  改变记录布局；遇到这种情况脚本会直接报错退出，而不是装出一个坏掉的版本。
- bundle 里引用的少数几个 Bun API（`Bun.serve`、`Bun.Terminal`、`Bun.SQL`）来自
  Anthropic 自己的 Bun 分支。它们都在可选功能后面，正常的 CLI 使用路径不会走到。
- Claude Code 是专有软件，受
  [Anthropic 商业条款](https://code.claude.com/docs/en/legal-and-compliance)约束。
  本仓库不包含任何 Anthropic 代码 —— 只有一个脚本，负责下载官方发布版，并在本地为一个
  官方并不支持的平台重新打包。
