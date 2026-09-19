version: 2
updates:
  - package-ecosystem: mix
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
    groups:
      mix:
        patterns: ["*"]
    commit-message:
      prefix: chore
      include: scope
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
    groups:
      actions:
        patterns: ["*"]
    commit-message:
      prefix: ci
