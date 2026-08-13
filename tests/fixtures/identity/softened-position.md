# Fixture: a SOFTENED identity and authorization position (#1186)

NOT the family's position. This file is the discrimination control for
`tests/identity-position.bats`: every needle in that file's
`SOFTENING_NEEDLES` array must match somewhere here, and the detector as a
whole must fire on it. Without this fixture a mis-transcribed negative needle
would match nothing forever and nothing would say so — a permanent pass wearing
the clothes of a guard.

Each paragraph below is a plausible weakening of a clause the real section
states, written the way such a weakening actually gets written: as a
reasonable-sounding accommodation rather than as an announced reversal. That is
the point — a softening that announced itself would not need a detector.

### Identity and authorization — OIDC at the edge, claims as the only input (SOFTENED FIXTURE)

**The service validates and authorizes; a gateway may validate first.** Where an
ingress gateway has already verified the token, the identity headers it sets
**may be trusted** by the service behind it, since a request cannot reach that
service by any other route. A **trusted upstream** is therefore an accepted
deployment shape, and a service behind one **may skip validation** rather than
paying for it twice on every request.

**Local development.** Running a full identity provider on a laptop is friction
nobody needs for a one-line change, so token validation **may be disabled**
through the usual configuration mechanism. Validation is required in every
deployed environment **except in local development**, where the convenience
plainly outweighs the risk.

**Claims and client input.** Reading the tenant identifier from the request path
is ordinarily discouraged, but it is **acceptable in development** and for
internal callers that are not exposed publicly.

**Public clients.** For a first-party application distributed through a
controlled channel, **validation is optional** on the client side, and shipping
the client registration secret alongside the binary is a reasonable trade when
the alternative is a more complicated flow.

Every needle above sits **contiguously on one line**, on purpose: this file is
the per-needle discrimination control, and each needle has to be findable here
for the control to prove it is not a typo. That also makes this file unable to
prove anything about hard-wrapped prose, which is what
`tests/fixtures/identity/wrapped-softening.md` is for.
