# FIXTURE — a SOFTENED deployment position. Never loaded as documentation.
#
# This file exists to prove that the escape-hatch detector in
# tests/deployment-position.bats actually discriminates. A negative assertion
# ("the real section contains none of these") is worthless unless something
# somewhere demonstrates the needles can match at all — otherwise a
# mis-transcribed needle is a permanent pass, and the guard rots into a blind
# spot exactly when it is needed.
#
# tests/webui-positions.bats commits fixtures for the same reason. Each
# paragraph below is a plausible way someone would weaken the mutable-tag rule
# while believing they were being reasonable; the detector must fire on every
# one of them.

### Deployment — GitOps promotion and immutable references (SOFTENED FIXTURE)

An infrastructure-repo manifest references a service image by an immutable
`<image>:<semver>` tag. Mutable tags are build conveniences.

A manifest may reference `latest` while a service is still being stabilised,
except in the production overlay, where the full semver is required.

For a preview environment a `sha-…` pin may be deployed directly, since the
environment is torn down afterwards and nothing durable depends on it.

In non-production namespaces a branch tag is temporarily acceptable, and teams
may name one in a manifest until the release cadence settles.

Pinning the full semver is required everywhere except for the staging overlay,
where whatever the last green build produced is good enough.
