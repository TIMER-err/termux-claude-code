# termux-claude-code

[English](README.md) · **简体中文**

在 Termux（Android，aarch64）环境下安装 [Claude Code](https://claude.com/claude-code)。

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh | bash
```

安装完成后，重新打开一个 shell 并执行 `claude`。亦可先克隆本仓库、审阅 `install.sh`
的内容后再执行 —— 对于任何需要通过管道传入 shell 的脚本，这都是更稳妥的做法。

## 背景

Anthropic 发布的 `linux-arm64` 构建是由 [Bun](https://bun.sh) 打包的可执行文件，链接
至 **glibc**。Android 使用的是 **bionic** libc，二者属于不同的 libc ABI，因此该二进制
在 Termux 下无法执行 —— 这并非缺少依赖所致，无法通过安装软件包解决。npm 包同样不能
规避此问题，其安装过程下载的仍是同一个二进制。

常见的变通方案是使用 **proot** 容器。该方案可以运行，但交互体验较差：**每次按键均有
数百毫秒的显示延迟**。需要指出的是，这并非 proot 的 syscall 拦截开销所致 —— 在容器内
执行命令与工具调用的性能均属正常，且在同一容器内改用本项目安装后，该延迟即告消失。
问题源于预打包的二进制本身，而非容器环境。

因此，本项目不运行该二进制文件，而是将其中的 JavaScript 重新提取出来，交由 Termux 原生
的 `bun` 执行：一个普通的 Android 进程，使用真实的 `$HOME`，占用 40 MB。若已在 proot
环境中工作，在其中安装本项目同样有效。

## 实现原理

1. 下载官方 `linux-arm64` 发布版，并对照 release manifest 校验 SHA-256。
2. 通过 `objcopy` 提取 ELF 中的 `.bun` 节 —— 即 Bun standalone 的 module-graph 数据块，
   以 `\n---- Bun! ----\n` 标记结尾。
3. 解析该数据块末尾的 module-graph 表，将每条记录还原为实际文件（约 1800 个：ESM
   chunk、skills、文档及原生模块）。
4. 将 Bun 的 `/$bunfs/root/` 虚拟文件系统路径改写为相对路径，并修补硬编码的 `/tmp`
   路径 —— Termux 的应用进程对该目录不具备写权限。
5. 在 `~/.local/bin/claude` 安装 wrapper 脚本，用于执行 `bun cli.js`。

### module-graph 格式

Claude Code 自 **2.1.2xx** 前后起改用 *code-split* 打包方式：不再包含单一的 `cli.js`，
而是约 1800 个独立 ESM chunk 及内嵌资源，由位于节末尾、长度为 52 字节的定长记录表进行
索引。

```
struct CompiledModuleGraphFile {   // 52 字节
    StringPointer name;            // {u32 offset, u32 length}
    StringPointer contents;
    StringPointer sourcemap;
    StringPointer bytecode;
    /* loader / encoding / module_format 标志位 */
};
```

其中所有偏移量均相对于数据块起始位置 **加 8**；入口点为名称是 `/$bunfs/root/cli` 的
模块。

供从旧版脚本迁移者参考：2.1.2xx 之前的做法 —— 定位
`file:///$bunfs/root/src/entrypoints/cli.js` 标记并在首个 NUL 处截断 —— 在新格式下会
定位到一个约 1 KB 的辅助 chunk，所得 `cli.js` 可正常解析，但运行时会立即返回。

### 运行时选择：Bun 而非 Node

在 Node 上运行几乎可行：为 `globalThis.Bun` 提供 shim，将 `import.meta.require` 替换为
`createRequire`，并把 `Bun.zstdDecompress*` 映射至 `node:zlib`。但执行 `--help` 时会因
`ERR_REQUIRE_CYCLE_MODULE` 失败 —— 该 bundle 以同步方式穿越循环依赖加载 ESM chunk，
Bun 允许此行为，而 `require(esm)` 不允许。Termux 已直接提供 `bun` 软件包
（`pkg install bun`），可原样运行该 bundle，故采用 Bun。

## 用法

```
install.sh [install|uninstall] [选项]
```

未指定动作时默认为 `install`。脚本不包含任何交互式提示，可安全地通过管道执行。

| 选项 | 等价环境变量 | 说明 |
| --- | --- | --- |
| `-r, --release VERSION` | `CLAUDE_RELEASE_VERSION` | 指定版本，而非解析 `latest`。 |
| `-b, --binary PATH` | `CLAUDE_LOCAL_BINARY` | 使用已下载的二进制文件。 |
| `-f, --force` | `FORCE_INSTALL_CC=1` | 版本一致时亦强制重新安装。 |
| `-h, --help` | — | 输出选项列表并退出。 |

升级方式为重新执行 `install`：当已安装版本与目标版本一致时，将跳过 205 MB 的下载。
如需通过一键安装命令传递参数，请使用 `bash -s --`：

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh \
  | bash -s -- --force
```

## 卸载

```bash
bash install.sh uninstall
```

该命令将删除 `~/.local/bin/claude` 与 `~/.local/lib/claude-code/`。`~/.claude` 中的登录
凭据与配置将予以保留；安装过程写入 shell 配置文件的内容块同样保留（其标记分别为
`# >>> cc-termux PATH >>>` 与 `# >>> claude-code-termux-tmpdir >>>`），如需清除请手动
删除。

## 附注

- 依赖项，缺失时将通过 `pkg` 自动安装：`curl` · `ripgrep` · `which` · `python` ·
  `binutils` · `bun` · `ca-certificates`。安装过程需约 250 MB 可用空间，安装完成后
  占用 40 MB。
- wrapper 脚本将 `TMPDIR` 与 `CLAUDE_*TMPDIR` 指向 `$PREFIX/tmp`，设置
  `USE_BUILTIN_RIPGREP=0`（内置的 `rg` 不包含在解包所得的 module graph 中），将 TLS
  证书路径指向 `$PREFIX/etc/tls/cert.pem`，并禁用自动更新 —— 否则更新程序会以无法运行
  的二进制文件覆盖当前安装。
- 解包过程依赖 Bun 内部的 standalone 格式，因此对版本敏感。若上游变更记录布局，脚本将
  直接报错退出，而不会产生损坏的安装结果。
- bundle 中引用的少量 Bun API（`Bun.serve`、`Bun.Terminal`、`Bun.SQL`）来自 Anthropic
  的 Bun 分支，均位于可选功能之后，常规 CLI 调用路径不会触及。
- Claude Code 为专有软件，受
  [Anthropic 商业条款](https://code.claude.com/docs/en/legal-and-compliance)约束。
  本仓库不包含任何 Anthropic 代码，仅提供一个脚本，用于下载官方发布版并在本地为其官方
  未支持的平台重新打包。
