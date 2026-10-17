# 食用说明
一加内核开源地址：[OnePlusOSS](https://github.com/OnePlusOSS/kernel_manifest)

# 原始项目
[MKSU-SKN](https://github.com/ShirkNeko/KernelSU)

# 产物
一加自家 GKI 内核 + 内联（builtin）SukiSU Ultra + SUSFS + KPM，打包为 AnyKernel3 刷机包。
不是 Google 通用 GKI 镜像，不能跨机型刷。

# 上游一致性

这套 workflow 全部依赖上游（`SukiSU-Ultra` 的 `builtin` 分支、`susfs4ksu` 的补丁、`patch_linux`），
上游一改，构建仍可能"成功"，但打出来的内核会**安静地丢掉 root 或隐藏功能**。为此有三层保障：

| 层 | 位置 | 作用 |
|---|---|---|
| 版本锚点 | `config/upstream.env` | 唯一的版本事实来源：分支、可选 commit pin、补丁工具哈希 |
| 构建期断言 | 各 workflow 内的 `Preflight` / `断言` 步骤 | 检出分支不含 SUSFS Kconfig、补丁没打上、SUSFS 分支不存在时**直接失败** |
| 定期巡检 | `.github/workflows/upstream-watch.yml` | 每周一自动比对上游，Kconfig 符号 / 补丁耦合 / 工具哈希任一变化即红灯 |

本地随时可以手动体检：

```bash
bash scripts/upstream-preflight.sh                        # 默认 android16 / 6.12
bash scripts/upstream-preflight.sh --android android15 --kernel 6.6
bash scripts/upstream-preflight.sh --print-pins           # 打印当前上游 commit / 哈希
```

## 升级上游的流程

1. 跑 `bash scripts/upstream-preflight.sh --print-pins`，拿到新的 `KSU_PIN` / `SUSFS_PIN` / `PATCH_LINUX_SHA256`
2. 写回 `config/upstream.env`（`KSU_PIN` 留空 = 跟随分支 HEAD，会漂移；建议填 commit）
3. 再跑一次 `bash scripts/upstream-preflight.sh`，确认全绿
4. 提交；如果想验证真机效果，再手动触发一次构建

> `KSU_PIN` 一旦填上就不会自动跟进上游，这是刻意的：先升级验证，再推动 pin，避免半夜构建突然换了内核。

## SUSFS 分支可用组合

`susfs4ksu` 只提供这几组，`CPU`/`ANDROID_VERSION`/`KERNEL_VERSION` 选到其它组合会在预检阶段直接失败：

```
android12-5.10  android13-5.10  android13-5.15  android14-5.15
android14-6.1   android15-6.6   android16-6.12
```

## 手工核对上游是否"还适合 SukiSU"

```bash
# 1. builtin 分支是否还带 SUSFS 集成
curl -fsSL https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/builtin/kernel/Kconfig | grep -c "config KSU_SUSFS"

# 2. 补丁依赖的 KSU 符号是否还在
grep -oE '\b(__)?ksu_[a-z0-9_]+' <susfs补丁> | sort -u
```
