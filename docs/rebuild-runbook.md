# Rebuild runbook

Goal: a teardown and rebuild gives a lab that is managed and talks out of
the box. Every fix lives in the builder. A change made by hand on a live VM
is lost at the next rebuild.

## Steps

1. `Remove-HomeLab` (tears down the VMs; see `docs/getting-started.md`).
2. `Install-HomeLab` with the same configuration. Each phase is idempotent.
   Phase `12-Validate` runs last and fails the run when a check fails.
3. Read the `12-Validate` lines in the log (`%ProgramData%\HomeLab\Logs`).
   Every check must show `OK`:
   WinRM, Console, ManagedClient, AdminServiceTrust, AdminServiceRest, CMPivot.

To run only the validation on a live lab, call `Install-HomeLab` with
`-SkipPhases` set to every phase except `12-Validate`.

## What the build does without manual steps

| Area | Builder step |
|---|---|
| Certificate authority | `Install-LabRootCA` (Enterprise Root CA on the domain controller) |
| Root trust on every domain member | The Enterprise CA publishes the root in Active Directory. Members install it during policy refresh. No GPO, no import. |
| Administration service certificate | `Set-LabWebServerTemplateAccess`, `Set-CMAdminServiceCertificate` (see `docs/admin-service-pki.md`) |
| Enhanced HTTP | `Enable-CMEnhancedHttp` |
| Domain join, client push, boundary, boundary group, discovery | `Join-LabDomain`, `Set-CMClientPush`, `New-CMBoundary`, `New-CMBoundaryGroup`, `Set-CMDiscovery` |
| Console on the site server | site setup (`AdminConsole=1`) |
| Console on client VMs | `Install-CMConsole` |
| Health proof | `Invoke-LabValidation` (phase `12-Validate`) |

## Not in the builder, by design

These settings depend on the person who runs the lab. They are not
general, so the builder does not set them.

- An interactive logon of the lab admin on a VM. A person logs on by hand,
  and a Windows update restart ends it.
- Windows evaluation licensing. Evaluation editions expire, and the
  re-arm count is limited. Use a new image or a license.
- Test-only WinRM listeners (HTTPS, relaxed channel binding) and
  `TrustedHosts` on a client.
- Owner-specific accounts and site settings (script approver, two-key
  approval, a worker mailbox). The lab owner keeps the script for them
  outside the builder.

## Measured time per phase

Source: `%ProgramData%\HomeLab\Logs\HomeLab-2026-07-17.log`, the run that
started 2026-07-17 10:07 with three VMs. It ran before the PKI and
validation phases existed. Phase 03 was an image cache miss.

| Phase | Measured |
|---|---|
| 01-Prereq | 1 s |
| 02-Network | 2 s |
| 03-Image | 9 min 39 s |
| 04-VM | 3 min 3 s |
| 05-Domain (DC promotion, AD CS) | 10 min 2 s |
| 05-Domain (parallel join) | 2 min 37 s |
| 07-CMPrereqs | 15 min 10 s |
| 06-Sql | 8 min 34 s |
| 08-CM | 20 min 56 s |
| 09-CMConfig | 17 s |
| 10-Tools | 17 s |
| Total | 1 h 10 min 39 s |

Phases 09 (now with the PKI steps) and 12 have no full-run measurement yet.
Record them here after the first rebuild that includes them.
