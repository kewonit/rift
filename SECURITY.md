# Security policy

## Report a vulnerability

Report suspected vulnerabilities privately to the repository owner. Include the
affected version, macOS build, redacted reproduction steps, and whether
filtering was enabled. Do not include connection metadata, policy contents,
signing keys, provisioning profiles, or notarization credentials in a public
report.

The project publishes no security bounty or release SLA.

## Security boundaries

Rift fails open when no compatible, validated policy is available. The integrity
claim does not cover a root attacker. After a sandbox or discretionary access
control (DAC) compromise, same-user code can change editable configuration. It
must not directly write the extension's root-owned durable policy cache.
