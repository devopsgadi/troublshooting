# K8s Troubleshooting Kit (read-only)

| File | What |
| --- | --- |
| `k8s_profile.sh` | Bash profile: multi-cluster (Rancher PCI/non-PCI, AKS, on-prem), read-only guard, emerID sessions, troubleshooting commands |
| `01-setup.md` / `.docx` | Workstation setup: tools, Rancher, Azure, clusters, namespaces, emerID, access check |
| `02-runbook.md` / `.docx` | Troubleshooting runbook: what to run, when, where |

Quick start:

```bash
cp k8s_profile.sh ~/.k8s_profile
echo '[ -f ~/.k8s_profile ] && source ~/.k8s_profile' >> ~/.bashrc
exec bash && khelp
```
