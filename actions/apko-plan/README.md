# Melange runner profiles

The planner emits `runner_profile` for each Melange matrix entry. The
`melange-build.yaml` reusable workflow accepts it as `runner-profile` and validates
it together with `arch` before scheduling the build. The default profile is
`standard`.

| Profile | Architecture | Runner |
| --- | --- | --- |
| `standard` | `x86_64` | `ubuntu-24.04` |
| `standard` | `aarch64` | `ubuntu-24.04-arm` |
| `large` | `x86_64` | `oplabs-ubuntu-x86` |
| `large` | `aarch64` | `oplabs-ubuntu-arm` |

The `large` profile uses organization-managed GitHub-hosted larger runners.
Unknown profiles and architectures fail validation. Runner labels are not inputs
to this version of the reusable workflow. Runner-group access policies are
unchanged; this validation does not restrict direct jobs or older workflow versions.

## Migrating a caller

1. Remove top-level `default_runners` and `melange.<stack>.runners` from the catalog.
   The new planner rejects these keys, including empty values.
2. Set `melange.<stack>.runner_profile` to `large` for stacks that previously used
   the `oplabs` runners. Omit the field or use `standard` for standard Ubuntu
   runners. An explicit null, empty, or unsupported profile is rejected.
3. Replace the Melange call's `runner: ${{ matrix.runner }}` with
   `runner-profile: ${{ matrix.runner_profile }}`.
4. Update the planner action and Melange reusable workflow to the same reviewed
   Factory commit in the same change. Keep publishing and smoke workflow pins
   unchanged.

Smoke matrix entries still contain `runner`, and `smoke_runners` configuration is
unchanged. Do not change the smoke workflow's `runner` input during this migration.

Older SHA-pinned callers keep their existing behavior. To roll back a caller,
revert its catalog, planner pin, Melange workflow pin, and input change together.

## Tests

Run `actions/apko-plan/apko-plan.test.sh` with Bash 4.3+ and jq available, then
`python3 -m unittest discover -s actions/apko-plan -p 'test_*.py' -v`.
The Python tests execute the selector embedded in the workflow itself.
