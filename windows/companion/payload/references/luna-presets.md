# 模型、强度与执行档位

当前 Windows Companion 默认使用已连接账号在 App 中保存的有效 model/effort 和调度策略。`reserve` 与 `run` 支持仅对本次任务生效的 `--model <当前可用模型ID>`、`--effort <该模型支持的值>`、`--tier <default|fast>` 覆盖；参数省略时继承保存值，不修改永久偏好。模型必须在当前账号 catalog 中，effort 必须适用于所选模型，tier 与模型/计划不兼容时失败关闭。仅覆盖 model 时沿用保存的有效 effort。预检、预约、批准及最终启动检查仍绑定当前设置与 revision；期间变更必须重新准备，不能悄悄使用旧值。

账号选择使用 App 持久化的稳定 A–Z dispatch code 或数字 profile ID，二者互斥；这不是 Mac 的账号/档位别名。单次覆盖必须在 `reserve` 与对应 `run` 中逐项保持相同，包含是否省略参数。App 以当前 catalog、保存设置、official plan 和 revision 重新验证有效组合；不要添加未验证模型名、新档位或静默回退。

用户明确指定的参数优先；若当前入口表达不了，就报告确切限制并停止该次启动。在已授权范围内补齐并验证后再执行，不静默改用保存偏好，也不改永久设置来冒充单次覆盖。
