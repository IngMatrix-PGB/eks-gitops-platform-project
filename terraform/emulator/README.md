# Emulator fixtures

Variable values for running each Terraform root module against the local
AWS emulator (`scripts/terraform/emulator.sh`, ADR-0018). One file per
root, named after the root's path with `/` replaced by `-`.

`__EMULATOR_ACCOUNT_<n>__` becomes a twelve-digit account ID at runtime:
`n = 0` is the emulator's own account, any other `n` is `n` zero-padded.
No twelve-digit literal is committed (`check-forbidden-terms`).

These values are fabricated. Nothing here names a real account, person or
resource.
