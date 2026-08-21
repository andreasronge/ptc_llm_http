# Releasing `ptc_llm_http`

Hex publication is a separate, explicit maintainer action. Ordinary pushes,
pull requests, and tags never publish a package.

The GitHub environment `hex-publish` must allow deployments only from `main`,
require maintainer approval, and hold an environment secret named
`HEX_API_KEY`. The key needs only Hex `api:write` permission. Do not store it as
a repository secret or in a local file. The workflow exposes it only to the Hex
dry-run and publish steps.

## Dry run

From a clean release candidate merged to `main`, select **Publish PtcLlmHttp to
Hex** in GitHub Actions and run it from `main` with:

- `version`: the exact version in `mix.exs`; and
- `mode`: `dry-run`.

Approve the protected environment deployment. The workflow requires the
requested version to match `mix.exs`, runs `mix full_check`, and asks Hex to
authenticate and validate the package without publishing it.

## Publish

Do not publish until the PtcRunner path-dependency smoke tests have passed and
release approval is explicit. Update `mix.exs` and `CHANGELOG.md` on a branch,
merge the release candidate to `main`, and rerun the dry run there. Create and
push the immutable `vVERSION` tag from that exact `main` commit.

Run **Publish PtcLlmHttp to Hex** from `main` with:

- `version`: the exact version without the `v` prefix; and
- `mode`: `publish`.

The protected job fetches the corresponding remote `vVERSION` tag and rejects
a version mismatch or a tag that does not name the dispatched `main` commit.
It then reruns the complete release gate and Hex dry run before the publish
step becomes reachable. Review the run, approve the environment deployment,
and verify the package, documentation, changelog, and tag after publication.

Do not dispatch publish mode, create a release tag, or approve the protected
deployment without explicit user confirmation.
