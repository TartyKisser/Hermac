# 将 Hermac 发布到 GitHub

这份指南面向第一次发布本项目的维护者。发布目录是桌面上的 **`Hermac-release`**；它可以作为仓库名 **`Hermac`** 的项目根目录，文件夹名称不必和 GitHub 仓库名称一致。

README 已准备为英文首页与简体中文版本，并带有无个人信息的矢量品牌图。许可证为 **MIT**，署名 **Hermac contributors**。

以下命令由你在终端中执行。准备工作没有创建远程仓库、提交代码、登录 GitHub 或上传文件。

## 1. 确认使用发布目录

```sh
cd "$HOME/Desktop/Hermac-release"
pwd
ls -la
```

应看到 `Hermac/`、`HermacTests/`、`Tests/`、`Hermac.xcodeproj/`、`README.md`、`README.zh-CN.md`、`LICENSE` 和 `.gitignore`。

原开发目录中的构建产物、日志、历史验证记录和设计参考图不属于这个发布副本。后续构建会生成本地文件；`.gitignore` 已排除常见构建输出、数据库、环境配置及证书文件。不要把原开发目录整个覆盖回来。

## 2. 初始化 Git，并使用公开署名

```sh
git --version
git init -b main
```

先到 **GitHub → Settings → Emails**，启用 **Keep my email addresses private**，复制 GitHub 为你显示的 `noreply` 提交邮箱。建议同时启用阻止命令行提交泄露私人邮箱的选项（若页面提供）。

将下面的占位符替换为你的**公开昵称**和刚复制的**完整 noreply 邮箱**，再执行：

```sh
git config user.name "YOUR_PUBLIC_NAME"
git config user.email "YOUR_GITHUB_NOREPLY_EMAIL"
git config --get user.name
git config --get user.email
```

这些是**当前仓库级**设置，不会改变其他项目。Git 提交会公开作者姓名与邮箱；不要直接沿用全局配置中的私人身份。修改配置不会追溯修改已有提交。[GitHub 官方说明](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address)

## 3. 检查即将提交的文件

```sh
git add .
git status --short
git diff --cached --stat
git diff --cached --check
git diff --cached --name-only
```

检查文件列表：应只有源码、测试、Xcode 共享配置、图标和公开文档。不要包含 `.env`、私钥、会话数据库、个人截图、构建日志或编译产物。若首次提交前有误加入的路径，用 `git rm -r --cached -- 路径` 仅取消跟踪，并保留本地文件；已有提交的仓库也可用 `git restore --staged 路径` 撤出暂存区。

需要自己验证构建时，参考 [TESTING.md](TESTING.md)。普通单元测试不调用真实模型；两个可选 smoke 脚本会访问本机 Hermes，行为不同。

确认后提交：

```sh
git commit -m "Initial open-source release"
git log -1 --format=fuller
```

核对最后一条输出中的作者和提交者是你愿意公开的身份。还没推送时，如需修正身份，先改仓库级配置，再执行 `git commit --amend --reset-author --no-edit`。

## 4. 创建 GitHub 仓库并推送

下面两种方式**选一种**。

### 方式 A：GitHub CLI（推荐）

如果尚未安装 `gh`，按 [GitHub CLI 官方安装说明](https://cli.github.com/) 安装；已使用 Homebrew 时可执行 `brew install gh`。

```sh
gh --version
gh auth login --hostname github.com --git-protocol https --web
gh auth status
gh auth setup-git
```

在浏览器中完成你自己的 GitHub 登录与授权。确认 `gh auth status` 显示的是你希望发布项目的账号。

下一条命令会**创建公开仓库并上传当前提交**。准备公开后再执行：

```sh
gh repo create Hermac --public --source=. --remote=origin \
  --description "Native macOS client for Hermes Agent — SwiftUI, Liquid Glass, quick chat and translation." \
  --push
gh repo view --web
```

若该账号已存在名为 `Hermac` 的仓库，请使用新名称，或采用方式 B 连接一个已有的空仓库。发布到组织时，将名称改为 `YOUR_ORGANIZATION/Hermac`。[`gh repo create` 官方参数](https://cli.github.com/manual/gh_repo_create)

### 方式 B：网页创建 + Git 推送

1. 在 GitHub 点击 **New repository**。
2. 选择正确的 Owner，仓库名填写 `Hermac`。
3. Description 使用下方推荐文案，Visibility 选择 **Public**。
4. **不要再初始化 README、.gitignore 或许可证**，因为本地已经准备好。
5. 点击 **Create repository**，复制页面提供的 HTTPS 或 SSH 仓库地址。

将地址替换为刚复制的真实仓库地址：

```sh
git remote add origin https://github.com/YOUR_USERNAME/Hermac.git
git remote -v
git push -u origin main
```

使用 GitHub CLI 的 `gh auth setup-git`、你已配置的 Git 凭证管理器或 SSH 进行认证。不要把 Token 写进仓库 URL、源码或提交。GitHub 账号密码不是 HTTPS Git 推送的认证方式。完整流程见 [GitHub 官方指南](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)。

## 5. 让项目更容易被找到

在仓库首页右侧 **About → 齿轮** 中设置：

**Description**

```text
Native macOS client for Hermes Agent — SwiftUI, Liquid Glass, quick chat, screenshot context and translation.
```

**推荐 Topics**（按实际功能选用）：

```text
hermes-agent  macos  swift  swiftui  appkit  liquid-glass
ai-assistant  ai-agent  desktop-app  global-hotkey
chat-client  translation  markdown  screen-capture
```

GitHub Topics 有助于按用途、平台和语言发现仓库。使用小写与连字符；这些标签描述真实功能，不代表项目已有对应官方认证。[Topics 官方说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics)

发布后检查：

- README 顶部品牌图、徽章、中文切换和相对链接是否正常。
- GitHub 能否识别 MIT 许可证与 Swift 为主要语言。
- Requirements 和源码构建步骤是否清楚；当前没有公证安装包，不要填写不存在的下载链接。
- 如添加截图，使用合成会话，检查菜单栏、路径、账户、消息和图片元数据后再上传。当前品牌图为矢量插画，不含真实屏幕内容。

可选：验证首个版本后创建 `v0.5.2` 标签与 GitHub Release，并注明是源码版本。不要直接上传原开发目录中的 `.app` 或 dSYM；它们可能嵌入本机路径，且不等于已签名公证的分发包。

## 6. 后续更新

在这个发布目录中开发或同步**审查过的源码**，然后：

```sh
git status --short
git diff
git add .
git diff --cached --stat
git commit -m "Describe the change"
git push
```

若另外保留私人开发目录，同步时继续只复制源码与公开资产，并把个人应用标识转换为发布副本的中性标识。发布副本已经更换 Bundle ID，与原本地安装的应用身份不同；不要把它无意中当作原应用的原位更新。
