name: Dependency audit
on:
  schedule:
    - cron: "23 7 * * 1"
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: audit-${{ github.ref }}
  cancel-in-progress: true
jobs:
  audit:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    env:
      MIX_ENV: dev
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false
      - uses: jdx/mise-action@5228313ee0372e111a38da051671ca30fc5a96db # v3
      - uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ env.MIX_ENV }}-${{ hashFiles('mise.toml', 'mix.lock') }}
      - run: mix deps.get --check-locked
      - run: mise run audit
