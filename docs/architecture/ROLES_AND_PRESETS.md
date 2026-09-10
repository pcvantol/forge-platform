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

The platform-neutral managed-Python executor is distinct from product
provisioning. It prepares the exact approved runtime and one isolated venv per
selected product through a fixed privileged-adapter protocol; it never installs
the Forge, Workspace or EP artifact into that venv and never assumes ownership
of a product's service, data or migration lifecycle.
