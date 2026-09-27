# deploy/

This directory is a **socket**: it is where this constellation's deployment
manifests will live, and it is deliberately empty today.

Deployment manifests are never written by hand here. They are **rendered** from
the deploy-specs each member image publishes, by renderers that
`development-composition` will ship:

- docker compose — [#719](https://github.com/timo-jakob/timos-claude-code-plugins/issues/719)
- Kubernetes — [#720](https://github.com/timo-jakob/timos-claude-code-plugins/issues/720)

Until one of them lands, every environment in `.claude-workspace.yaml` declares
`deploy_target: none`, and `scripts/promote.zsh` records what it promoted
(`promotion-<env>.json`) without deploying it:

- a merge to `main` promotes `staging` and says *nothing deployed* in its log
  and job summary;
- a manual `production` dispatch writes its record and then **fails**, because
  there is nothing to deploy with.

No run reports a deploy that did not happen.
