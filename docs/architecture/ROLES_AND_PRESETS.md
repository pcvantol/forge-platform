# Installable roles and presets

Roles are independently installable; one machine may host any compatible combination.

| Class | Components |
| --- | --- |
| Server | Forge Runtime; Workspace Server; Engineering Platform Server |
| Local | Engineering Platform Project Agent; Workspace Client |

## Conceptual presets

| Preset | Components |
| --- | --- |
| Complete Forge Platform | Forge Runtime, Workspace Server, EP Server, EP Project Agent, Workspace Client |
| Server | Forge Runtime, Workspace Server, EP Server |
| Developer Workstation | EP Project Agent, Workspace Client |
| Custom | Any compatible component combination |

The native Universal Installer source shell presents these profiles through a
signed composition rather than hard-coding versions. A selected composition
may require managed Git, the exact catalog-approved Python runtime and
user-scoped Codex/GitHub CLI provider validation before it can proceed. The
server components use a product-owned system-domain `LaunchDaemon` contract;
an EP Project Agent and user provider credentials remain user/host scoped. The
shell does not itself install or mutate a product until a qualified product
provisioner adapter exists.
