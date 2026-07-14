# Contribute

`main` is protected: PRs only, 1 approving review, all required checks
green, and **cryptographically signed commits required** (GPG or SSH; see
[GitHub's signing guide](https://docs.github.com/en/authentication/managing-commit-signature-verification)).
Squash-merges via the GitHub UI/CLI are signed automatically by GitHub,
so the main constraint applies to any direct pushes — those will be
rejected unless your local commits are signed.

## Set up SSH commit signing locally

This matches the bootstrap's recommended path in
`templates/common/SETUP.md.tmpl` Section 3g:

```sh
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub  # or your key
git config --global commit.gpgsign true
```

Then add the **same public key** to GitHub as a *signing key* (Settings
→ SSH and GPG keys → New SSH key → Key type: **Signing**). It's a
separate registration from authentication keys, even when the key file
is the same.

## Where new documentation goes

Docs follow the [Diátaxis](https://diataxis.fr/) split — tutorials, how-to,
reference, explanation. Place new pages by reader intent and link them from the
[docs MOC](../index.md). A dedicated authoring guide (placement rules) is
delivered by child (g) of epic
[#744](https://github.com/timo-jakob/timos-claude-code-plugins/issues/744).
