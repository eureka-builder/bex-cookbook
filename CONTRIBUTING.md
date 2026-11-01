# Contributing

Fixes and new recipes are welcome.

## How changes land

1. Fork the repo and make the change on a branch.
2. Run the checks of each recipe you change. Each recipe's README and `AGENTS.md` list them, and CI runs them on
   every PR.
3. Open a pull request. Say what changed, why, and paste the check results.

Each PR is squash-merged into one commit on `main`.

## Sign-off

Every commit needs a sign-off line, which states that you wrote the change or have the right to submit it under
the repo's license (the [Developer Certificate of Origin](https://developercertificate.org/)):

```sh
git commit -s
```

## Add a recipe

- Put it in a new top-level folder, named for the use case, for example `liquidations/`.
- Make it self-contained: its own README, contracts, client and checks. Run every command from its folder.
- Add a CI job for it in `.github/workflows/ci.yml` and a row to the recipe table in the top-level `README.md`.
- Start its README with what it does, then a quickstart that ends in a dry run with `bex_simulate`.

## Questions

Ask in the builder's Telegram group, [t.me/EurekaBuilder](https://t.me/EurekaBuilder). Use issues for bugs.
