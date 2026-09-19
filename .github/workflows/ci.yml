name: CI
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    env:
      MIX_ENV: test
      PGHOST: localhost
      PGPORT: "5432"
      PGUSER: postgres
      PGPASSWORD: postgres
    services:
      postgres:
        image: postgres:18
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
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
      - run: mise run check
