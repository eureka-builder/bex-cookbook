# Security

## Report a vulnerability

Report it privately through GitHub: the repo's **Security** tab, then **Report a vulnerability**. Do not open a
public issue for a security problem.

Include the recipe, the file, what an attacker can do and the steps to reproduce it. We answer within a few
working days.

## Scope

- The contracts in each recipe, for example `backrun/contracts/src/`.
- The clients in each recipe, for example the `backrun/` bot, where it handles keys, requests or funds.

Out of scope: the builder itself, third-party contracts the recipes call (Uniswap and others), and losses from
running a recipe with your own settings. The recipes are unaudited, experimental demos.

There is no bug bounty.
