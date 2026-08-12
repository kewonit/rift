# Security policy

Do not include connection metadata, policy contents, signing keys, provisioning profiles, or notarization credentials in a public report. Report suspected vulnerabilities privately to the repository owner with the affected version, macOS build, redacted reproduction steps, and whether filtering was enabled. There is currently no published security bounty or release SLA.

Abyss is fail-open when no compatible validated policy is available. A root attacker is outside the integrity claim. Same-user database tampering after a sandbox/DAC compromise may alter editable configuration, but should not directly write the extension's root-owned durable policy cache.
