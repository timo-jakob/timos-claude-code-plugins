# e2e/

This directory is a **socket**: it is where this constellation's end-to-end
tests will live, and it is deliberately empty today.

The harness that fills it — standing up the pinned member images together and
checking them against each other's published contracts, as the gate on an
image-tag bump — arrives with the deploy renderers:

- docker compose — [#719](https://github.com/timo-jakob/timos-claude-code-plugins/issues/719)
- Kubernetes — [#720](https://github.com/timo-jakob/timos-claude-code-plugins/issues/720)

Do not add tests here by hand before then: there is no rendered environment for
them to run against.
