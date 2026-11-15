# tnet releases

tnet 的**发布产物镜像**。源码仓库是私有的，这里只放可以公开分发的产物：

- 各平台的 garble 混淆二进制（`tnet-<os>-<arch>-<version>.gz` / `.zip`）
- `SHA256SUMS`，覆盖同一个 release 里的每个文件

**没有源码**：这个仓里没有 tnet 的代码、没有源码 tarball/zip，也没有构建脚本。安装脚本
`install.sh` 只用于把产物装到机器上。

> 本仓由 tnet 仓库的 CI 自动同步，手工提交会被覆盖。问题请回到私有仓库跟踪。

## 安装

产物公开，**不需要 GitHub 账号、token 或登录**：

```bash
# 最新版本（装到 /usr/local/bin/tnet，需要 root）
sudo bash <(curl -fsSL https://github.com/dolfly/tnet-releases/raw/main/install.sh) --install

# 指定版本
sudo bash <(curl -fsSL https://github.com/dolfly/tnet-releases/raw/main/install.sh) --install v3.3.3

# 交互选择版本
sudo bash <(curl -fsSL https://github.com/dolfly/tnet-releases/raw/main/install.sh)
```

脚本按 `uname -s`/`uname -m` 选产物，下载后先比对 `SHA256SUMS` 再安装；校验不通过不会落盘。
非 root 或想装到别处时用 `TNET_DEST`：

```bash
TNET_DEST="$HOME/.local/bin" bash install.sh --install v3.3.3
```

## 手工下载与校验

```bash
tag=v3.3.3
curl -fsSLO "https://github.com/dolfly/tnet-releases/releases/download/${tag}/SHA256SUMS"
curl -fsSLO "https://github.com/dolfly/tnet-releases/releases/download/${tag}/tnet-linux-amd64-3.3.3.gz"
sha256sum -c --ignore-missing SHA256SUMS   # 只需要其中一个产物时可以这样校验
gzip -dc tnet-linux-amd64-3.3.3.gz > tnet && chmod +x tnet && ./tnet -V
```

## 容器镜像

```
ghcr.io/dolfly/tnet:3.3.3   (= :3.3, :3, :latest)
```

镜像与 release 附件同源（garble + `-trimpath`，构建阶段过纯净度门禁）。镜像是**公开**
package，`docker pull ghcr.io/dolfly/tnet:3.3.3` 不需要登录。

## 平台

| 平台 | 产物 |
| --- | --- |
| linux/amd64 | `tnet-linux-amd64-<ver>.gz` |
| linux/arm64 | `tnet-linux-armv8-<ver>.gz` |
| linux/armv7 | `tnet-linux-armv7-<ver>.gz` |
| linux/386 | `tnet-linux-386-<ver>.gz` |
| darwin/amd64 · darwin/arm64 | `tnet-darwin-{amd64,arm64}-<ver>.gz` |
| windows/amd64 · windows/arm64 | `tnet-windows-{amd64,arm64}-<ver>.zip` |

## 升级提示

- **v3.3.3 是断裂式升级**：gRPC 隧道服务名改版（旧客户端打新 hub 直接握手失败），hub 与所有节点必须
  **同版本**，新旧不能混跑。升级窗口内先停节点、换二进制、再起。
- 回滚就是装回上一版产物（`install.sh --install <旧 tag>`），配置目录 `/etc/tnet` 不需要回滚。
