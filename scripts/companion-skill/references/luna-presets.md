# Custom execution presets (0926v2)

`--subagent-mode` accepts `standard`, `sol_luna`, or `luna_direct`. A missing value is `standard`. The original saved model and reasoning effort remain in the preference in every mode; the effective invocation is derived without overwriting them. Service tier/Fast, sandbox, approval, identity, quota, and occupancy behavior remain independent.

The built-in defaults are: `standard` uses the original saved model/effort and disables native subagents; `sol_luna` derives GPT-6-Sol/high and enables one GPT-6-Luna/max worker at a time; `luna_direct` derives GPT-6-Luna/max and disables native subagents. “Direct” means no separate planning model, not zero reasoning. Custom values may change any slot's main and worker models without changing its stable ID. Disabled modes pass `agents.enabled=false` and `features.multi_agent_v2=false`; enabled modes pass both as true and set the child-thread ceiling to one. This is a working convention and configured ceiling, not an unbypassable whole-tree security policy; `fork_context=true` is prohibited because it bypasses role configuration.

The model catalog includes `gpt-6-sol` (through `ultra`) and `gpt-6-luna` (through `max`). Existing GPT-5.6 model IDs and explicit custom presets remain valid and are not rewritten. Slots without an explicit custom override follow the built-in defaults of the installed version.

`customPresets` may contain at most the three stable slot IDs. Each value has optional display-only `name` plus required `useSavedModel`, `model`, `reasoningEffort`, `subagentsEnabled`, `subagentModel`, and `subagentReasoningEffort`. Missing slots use built-in defaults. Names are trimmed, non-empty when present, at most 64 UTF-8 bytes, contain no control characters, and never enter the model prompt. Unknown fields, unsupported models/efforts, or Fast-incompatible effective models fail closed.

Any slot with `subagentsEnabled=true` uses the internal `next_preset_worker` contract. Its role TOML is generated from the validated effective child model/effort and frozen into a private task-specific ordinary file. `run` requires a fresh capability report whose `supportedSubagentModes`, `cliSHA256`, and `workerRoleSHA256` match the selected slot and generated role. Missing/stale/mismatched evidence or CLI lacking verified support blocks launch; there is no fallback.

The runner prefixes the frozen brief with a static collaboration policy. It does not replace `developer_instructions`, user config, sandbox, or approval settings. Receipts expose the original brief, static policy, and effective input hashes, plus requested child model/effort/role and a separate nullable observed field. Until real CLI JSON supplies trustworthy child model/effort/parent/status evidence, observed remains null and the result must not claim that the configured worker actually ran.

Example additions to both `plan` and `run`:

```sh
--subagent-mode sol_luna
```

Explicit `--model` / `--effort` retain existing override behavior only when the selected preset has `useSavedModel=true`; otherwise they must equal the derived values. Conflicts are rejected.
