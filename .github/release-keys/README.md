# Release signing keys

Public OpenPGP keys (`*.asc`) of the maintainers who sign release tags.
`.github/workflows/release-verify.yml` refuses any `v*` tag that is not
signed by one of them.

These files are **not** a trust root for users. `claude-dockerized update`
only accepts releases signed by a key that the user pinned locally with:

```bash
claude-dockerized update --trust-key maintainer.asc   # shows the fingerprint, asks to confirm
```

Compare the fingerprint against one published through a second channel (for
example the project README on the web, a release announcement or a keyserver)
before confirming.

To add a key:

```bash
gpg --armor --export <FINGERPRINT> > .github/release-keys/<name>.asc
```

To cut a release:

```bash
git tag -s vX.Y.Z -m "claude-dockerized vX.Y.Z"
git push origin vX.Y.Z
```
