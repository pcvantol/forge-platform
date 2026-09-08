# Component-manifest contract

A Forge Platform component manifest declares a tested release composition of independently published product artifacts. It does not build producer artifacts, infer them from source checkouts, or embed production endpoint choices in source control.

## Evidence-gated manifest finalization

A final manifest entry may be created only after the producing product has published the installable artifact and exposed the evidence required to identify and qualify those exact bytes.

A source merge or Git SHA alone is not an installable artifact. The manifest pins the artifact digest and separately records source provenance.

For each platform release and component, the manifest must identify at least:

- Forge Platform release version;
- component identity and version;
- source repository/revision provenance;
- artifact URI/name or qualified acquisition reference;
- artifact digest, normally SHA-256 over the installable bytes;
- signature and provenance evidence where supported;
- qualification/release evidence reference;
- supported operating systems and architectures;
- protocol compatibility; and
- required and optional component dependencies.

Credentials are never embedded in the manifest. Artifact acquisition resolves credentials through the qualified installation/release boundary.

## Cross-repository dependency boundary

Forge owns engineering planning and may model a hard dependency from a Forge Platform Action to a producer Action. Forge Platform owns only the composition artifact that results.

Example:

```text
EP-A5 publish qualified EP Server + Project Agent artifacts
  output evidence:
    server wheel identity + SHA-256 + source revision
    agent wheel identity + SHA-256 + source revision
    qualification/provenance refs

FP-A2 implement Agent installer role
  may proceed independently while EP product work continues

FP-A3 finalize component manifest
  depends_on = [EP-A5, FP-A2]
```

`FP-A3` must not be considered complete until the exact published producer artifacts exist. This permits useful parallel implementation without allowing the composition manifest to guess future versions, Git revisions or checksums.

The same rule applies to Forge Server, Workspace Server, Workspace Client, Engineering Platform Server and Engineering Platform Project Agent artifacts.

## Manifest versus engineering Action graph

The component manifest records a qualified release composition. It is not Forge's Living Mission Graph and does not carry the engineering execution DAG that produced the release. Action dependency and replanning authority remain Forge-owned; execution/admission evidence remains EP-owned.

The accompanying [JSON Schema](../../schemas/component-manifest.schema.json) is a structural contract, not a production manifest. It must preserve the distinction between source revision and artifact identity/digest.
