# Codex OpenFast

Codex 桌面端 Fast Mode 补丁工具，用于强制开启 fast mode UI 可见性。

## 快速使用

```bash
# 应用补丁
./scripts/patch_codex_fast_mode.sh apply

# 查看状态
./scripts/patch_codex_fast_mode.sh status

# 从备份恢复
./scripts/patch_codex_fast_mode.sh restore
```

## 命令说明

| 命令 | 说明 |
|------|------|
| `backup` | 创建 app.asar + Info.plist 备份（不修改文件） |
| `apply` | 备份 → 打补丁 → 更新 hash → 重签名 |
| `restore [dir]` | 从备份恢复（默认使用最新备份） |
| `status` | 检查完整性状态和补丁标记 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CODEX_APP_PATH` | `/Applications/Codex.app` | Codex 应用路径 |
| `CODEX_SIGN_IDENTITY` | `-` | 签名身份（`-` 为 ad-hoc） |

## 补丁版本

- **force-fast-ui-v2**: 强制 fast mode UI 可见，移除 auth gating，保留原生 serviceTier 请求流程

## 工作原理

1. 解包 `app.asar`
2. 定位 `general-settings-*.js` 中的 auth gate 函数
3. 将 `function X(e){return e===\`chatgpt\`}` 替换为 `function X(e){return!0}`
4. 重新打包并更新 `Info.plist` 中的 `ElectronAsarIntegrity` hash
5. 重签名应用

## 注意事项

- 每次 Codex 更新后需要重新执行 `apply`
- 备份存储在 `~/.codex/patches/codex-fast-mode/backup-*`
- 需要 `npx`、`rg`、`node`、`codesign` 命令


## 论坛支持

- [LinuxDo 论坛](https://linux.do)