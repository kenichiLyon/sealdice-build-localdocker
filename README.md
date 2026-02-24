# sealdice-build-localdocker

可用于本地 Docker 构建 `sealdice-core` 相关镜像与多平台二进制产物（含可选 Android APK）的工具集。

参考[sealdice-build](https://github.com/SealDice/sealdice-build)项目，目标是希望通过 Docker 快速构建出测试使用的二进制产物。

本项目采用 MIT 许可。


## 环境要求

- Docker 19.03+
- Docker Compose 1.27+
- 可用磁盘空间 >= 12 GB

注意：

- Windows 需要支持 Docker Desktop 并开启 WSL 2 后端。

## 目录结构

- `Dockerfile` / `Dockerfile.full`：运行镜像构建。
- `Dockerfile.artifact`：多平台产物构建镜像。
- `docker-compose.yml`：常规运行与可选 `artifact`/`full` profile。
- `docker-compose.artifact.yml`：仅产物构建服务。
- `docker/`：所有脚本入口（构建、清理、entrypoint）。
- `.env.docker.example`：公开可分享的参数模板。

## 快速开始

0. clone 本项目到本地，并准备好 sealdice-core 项目代码:

```bash
git clone https://github.com/SealDice/sealdice-build-localdocker.git
cd sealdice-build-localdocker
git clone https://github.com/SealDice/sealdice-core.git
```

注意:

- `sealdice-core` 项目编译依赖 `sealdice-ui` 项目的 `pre-release` 的产物，因此需要自行按 `sealdice-core` 项目首页的说明放好 `static` 目录下的对应前端文件，本项目默认假设 `sealdice-ui` 项目的 `pre-release` 产物已经按要求放在了 `sealdice-core` 项目的 `static` 目录下。

- `sealdice-core` 项目的代码应当放在本项目的根目录下，即 `sealdice-build-localdocker/sealdice-core`。

1. 复制环境模板：

```bash
cp .env.docker.example .env
```

2. 使用一键脚本构建多平台产物（默认不含 Android）：

- Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File docker/build-and-clean.ps1
```

- Windows CMD:

```cmd
docker\build-and-clean.cmd
```

- Linux / macOS:

```bash
bash docker/build-and-clean.sh
```

3. 构建结果位于 `dist/pkg`。

### Android 专用构建（拆分）

Android 构建（`android/arm64` + 可选 APK）已拆分为独立服务，避免常规产物构建拉取 JDK/Android SDK/NDK。

- 使用 `docker-compose.yml`：

```bash
docker compose --profile artifact-android run --rm artifact-builder-android
```

- 使用 `docker-compose.artifact.yml`：

```bash
docker compose -f docker-compose.artifact.yml --profile android run --rm artifact-builder-android
```

## 构建后清理建议

为避免构建容器与缓存长期占用磁盘，建议构建完成后执行清理。

- 推荐：直接使用一键脚本（默认会构建后清理）
  - `docker/build-and-clean.ps1`
  - `docker/build-and-clean.cmd`
  - `docker/build-and-clean.sh`
- 若手动运行 `docker compose run`，建议带 `--rm` 参数，确保一次性容器自动删除。
- 若需要进一步回收空间，可额外执行：

```bash
docker image rm -f sealdice-core-artifact:local
docker image rm -f sealdice-core-artifact-android:local
docker builder prune -af
```

说明：如果希望保留镜像或构建缓存，可在一键脚本中使用 `--keep-image` / `--keep-builder-cache`。

### 仅清理（不构建）

如果你只想清理历史构建残留，可直接执行：

- Windows PowerShell:

```powershell
docker image rm -f sealdice-core-artifact:local
docker image rm -f sealdice-core-artifact-android:local
docker builder prune -af
```

- Windows CMD:

```cmd
docker image rm -f sealdice-core-artifact:local
docker image rm -f sealdice-core-artifact-android:local
docker builder prune -af
```

- Linux / macOS:

```bash
docker image rm -f sealdice-core-artifact:local
docker image rm -f sealdice-core-artifact-android:local
docker builder prune -af
```

### （可选）构建 docker 版 sealdice-core 镜像

环境准备的步骤与前面相同，需要放好 sealdice-core 项目的代码。

之后，按照如下命令找到自己所用的平台进行镜像的构建。

- Windows PowerShell:

```powershell
docker-compose --profile full up --build
```

- Windows CMD:

```cmd
docker-compose --profile full up --build
```

- Linux / macOS:

```bash
docker-compose --profile full up --build
```
构建完成后，本地镜像列表中会出现 `sealdice-core-full` 镜像。

## 常用参数

可在 `.env` 中设置：

- `ARTIFACT_TARGETS`：目标平台列表
- `ARTIFACT_ANDROID_TARGETS`：Android 专用服务目标列表（默认 `android/arm64`）
- `GITHUB_PROXY`：GitHub 下载代理前缀
- `GITHUB_PROXY_FALLBACKS`：GitHub 下载代理候选（空格分隔，失败时自动回退尝试）
- `ARTIFACT_GITHUB_PROXY_FALLBACKS`：构建脚本内 GitHub 候选代理（影响 builtins/仓库归档下载）
- `ARTIFACT_ANDROID_APK_ENABLE=1`：开启 APK 构建
- `ARTIFACT_ANDROID_CORE_CGO=0`：关闭 Android NDK，使用纯 Go 方式构建 `android/arm64` core（更省空间）
- `ARTIFACT_CLEANUP_MODE`：`none` / `pkg` / `all`

说明：`Dockerfile.artifact` 会根据目标与开关按需安装交叉编译依赖；非 Android 服务默认不包含 Android 工具链。

## 命名与目录约定

- `artifact`：统一用于产物构建服务、镜像与脚本默认参数命名。
- `dist/`：统一为构建输出根目录（`pkg/`、`raw/`、`summary.txt` 等）。
- 首次执行时如果 `dist/` 不存在，Docker Compose 会自动创建。


## 公开仓库建议

- 不要提交 `.env`（包含本机/网络偏好）。
- 不要提交 `dist/`、`tmp/`、`output/` 产物目录。
- 提交前建议执行一次 dry-run 检查脚本参数：

```bash
bash docker/build-and-clean.sh --dry-run
```
