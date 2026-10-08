# gitleaks reads this file from the repository root. The default rules stay in force.
[extend]
useDefault = true

# Phoenix signs development and test sessions with these keys. Production reads SECRET_KEY_BASE.
[[allowlists]]
description = "Development and test secret_key_base"
condition = "AND"
paths = ['''^config/(dev|test)\.exs$''']
regexTarget = "line"
regexes = ['''^\s*secret_key_base: "''']
