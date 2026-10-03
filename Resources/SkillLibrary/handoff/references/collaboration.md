# 任务交接规范

版本：0919v1。摘自本机 general-collaboration-habits 0915v2，仅将个人目录依赖改为接收方现有项目规则。

## File Placement

- Before writing, resolve ownership from the current request and project entry, not the conversation's working directory alone. Follow the user's destination and project-specific rules; domain-specific project rules keep their own workflow. Ask only if ownership remains ambiguous.
- Keep established project roots, including those outside AgentHub. This workflow does not authorize migration or a second writable copy. Old defaults such as `Documents/Codex/`, `AgentHub/Codex/` and their global `HANDOFF.md` are historical lookup clues, not automatic destinations.
- For a new formal project, follow the recipient's current workspace and project rules. Resolve the owner and destination before creating files; do not assume the original author's directory structure.
- Reuse the existing README or manifest to distinguish accepted deliverables from active candidates. A newer date or successful local check does not by itself establish acceptance. Preserve the accepted result while working on a candidate.
- Required handoff dependencies must be durable. Before handing off, save irreplaceable inputs and recovery-critical runtime files in the project; an only copy in `/tmp` or a cache is insufficient.
- Reuse the project's current folders. Keep inputs, working/QA files and deliverables distinguishable; add a purpose-named subfolder only when needed. Avoid empty scaffolding or a new directory for every run.
- Give new files short names that identify their content and purpose. Follow project conventions; otherwise use `<主题>-<用途>-MMDDvN.ext` for versioned deliverables and stable descriptive names for handoffs and entry files, with the version inside. Preserve user-specified names and original input filenames.
- Organize only the requested task and files. Before moving or renaming, check target-name collisions and known references; update affected links and verify access. Do not treat organization as permission to delete files or merge suspected duplicates.

## Cross-Session Handoff

- For a requested handoff or an authorized long-task checkpoint, resolve placement first. Pure conversation needs no file unless requested.
- Read and reuse the existing task handoff. For a new one, follow the user's filename and project policy, otherwise use a short content-based name such as `handoffs/<task>-HANDOFF.md`. Keep each task's filename stable and link it from the existing project entry; preserve other tasks' state.
- Keep only recovery context: task and authorization; project/worktree; deliverable and candidate paths; completed work with dated evidence; blockers; smallest next action; specific pitfalls. Mark proposals and unverified claims accordingly.
- Update the stable handoff with `MMDDvN` for substantive changes. Dated snapshots are for requested archives or milestones. Link to detailed history; do not create full-text mirrors, duplicate global rules or extra start-note files by default.
- Before delivery, read back the handoff, verify required paths and links, and confirm other task entries were preserved. Return its absolute link and, when useful, one copyable continuation instruction in the reply.
- On resumption, verify task identity and current files. Inspect the worktree before code edits and refresh changing evidence before live actions. Historical plans, process details or permissions do not establish current completion or expand authorization; local checks alone do not prove acceptance or publication.
