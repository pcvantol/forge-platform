"""Strict, read-only decoding of Engineering Platform OI-3 V1 observations.

The Engineering Platform owns the operational-installation resolver and emits
its OI-3 observations as JSON-shaped values.  Forge Platform may retain those
values as product evidence, but it must not reinterpret them as a runtime
selection, construct an EP command line, or turn them into an installation
engine.  This module therefore has no product imports, paths, subprocesses,
or adapter implementation: it validates data that an explicit future product
boundary has already supplied.

The EP wire artifact includes its recorded channel, while the only artifact
identity that crosses into Forge Platform correlation is the exact
``version/source_revision/digest`` triple.  Inline evidence and inventory
scope stay inline and are copied without being collapsed into invented
evidence-reference strings.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Mapping

from .component_operations import ArtifactCorrelation, ComponentOperationRequest


EP_OI3_CONTRACT_VERSION = "1.0"
EP_SERVER_COMPONENT = "engineering-platform-server"
EP_SERVER_ROLE = "server"
EP_OI3_SUPPORTED_KINDS = frozenset({"update"})

_READBACK_STATES = frozenset({"ABSENT", "ACTIVE", "UNHEALTHY", "UNKNOWN"})
_HEALTH_STATES = frozenset({"HEALTHY", "UNHEALTHY", "UNKNOWN"})
_INVENTORY_COVERAGE_STATES = frozenset({"MACHINE_WIDE", "PARTIAL", "UNKNOWN"})
_CONFLICT_STATES = frozenset({"NONE", "CONFLICTING", "UNKNOWN"})
_UPDATE_STATES = frozenset({"UPDATE_AVAILABLE", "UP_TO_DATE", "INCOMPATIBLE", "UNKNOWN"})

_READBACK_FIELDS = frozenset({
    "contract_version",
    "component",
    "installation_identity",
    "state",
    "selected_runtime_identity",
    "selected_executable_identity",
    "selected_server_identity",
    "selected_instance_identity",
    "artifact",
    "health_state",
    "inventory_coverage",
    "conflict_state",
    "inventory_scope",
    "single_operational_installation_verified",
    "evidence",
})
_ASSESSMENT_FIELDS = frozenset({
    "contract_version",
    "component",
    "installation_identity",
    "candidate",
    "state",
    "evidence",
})
_OBSERVED_ARTIFACT_FIELDS = frozenset({"version", "source_revision", "digest", "channel"})
_CORRELATION_FIELDS = frozenset({"version", "source_revision", "digest"})


class EPReadbackWireError(ValueError):
    """An EP OI-3 V1 payload cannot safely be consumed as product evidence."""


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise EPReadbackWireError(f"{label} must be a non-empty string")
    return value


def _optional_string(value: object, label: str) -> str | None:
    if value is None:
        return None
    return _require_string(value, label)


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise EPReadbackWireError(f"{label} must be a mapping")
    for key in value:
        if not isinstance(key, str):
            raise EPReadbackWireError(f"{label} keys must be strings")
    return value


def _exact_fields(value: object, expected: frozenset[str], label: str) -> Mapping[str, object]:
    mapping = _mapping(value, label)
    actual = frozenset(mapping)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        details: list[str] = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected {', '.join(unexpected)}")
        raise EPReadbackWireError(f"{label} fields are invalid ({'; '.join(details)})")
    return mapping


def _copy_json(value: object, label: str) -> object:
    """Validate and clone JSON-compatible product evidence without rewriting it."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not isfinite(value):
            raise EPReadbackWireError(f"{label} must contain finite JSON values")
        return value
    if isinstance(value, list):
        return [_copy_json(item, f"{label}[]") for item in value]
    if isinstance(value, Mapping):
        copied: dict[str, object] = {}
        for key, nested in value.items():
            if not isinstance(key, str):
                raise EPReadbackWireError(f"{label} keys must be strings")
            copied[key] = _copy_json(nested, f"{label}.{key}")
        return copied
    raise EPReadbackWireError(f"{label} must contain JSON-compatible values")


def _copy_mapping(value: object, label: str) -> Mapping[str, object]:
    mapping = _mapping(value, label)
    copied = _copy_json(mapping, label)
    if not isinstance(copied, Mapping):  # defensive: _mapping above guarantees this
        raise EPReadbackWireError(f"{label} must be a mapping")
    return copied


def _observed_artifact(value: object) -> tuple[ArtifactCorrelation | None, str | None]:
    if value is None:
        return None, None
    artifact = _exact_fields(value, _OBSERVED_ARTIFACT_FIELDS, "artifact")
    correlation = ArtifactCorrelation(
        _require_string(artifact["version"], "artifact.version"),
        _require_string(artifact["source_revision"], "artifact.source_revision"),
        _require_string(artifact["digest"], "artifact.digest"),
    )
    return correlation, _require_string(artifact["channel"], "artifact.channel")


def _candidate_correlation(value: object, label: str) -> ArtifactCorrelation:
    candidate = _exact_fields(value, _CORRELATION_FIELDS, label)
    return ArtifactCorrelation(
        _require_string(candidate["version"], f"{label}.version"),
        _require_string(candidate["source_revision"], f"{label}.source_revision"),
        _require_string(candidate["digest"], f"{label}.digest"),
    )


def _validate_wire_header(contract_version: object, component: object) -> tuple[str, str]:
    contract = _require_string(contract_version, "contract_version")
    if contract != EP_OI3_CONTRACT_VERSION:
        raise EPReadbackWireError(f"unsupported EP OI-3 contract version: {contract}")
    decoded_component = _require_string(component, "component")
    if decoded_component != EP_SERVER_COMPONENT:
        raise EPReadbackWireError(f"unsupported EP OI-3 component: {decoded_component}")
    return contract, decoded_component


@dataclass(frozen=True)
class EPInstallationReadback:
    """One strictly decoded EP operational-readback payload.

    ``artifact`` is deliberately an :class:`ArtifactCorrelation`, never a
    Forge Platform ``QualifiedArtifact``. ``artifact_channel`` is retained as
    EP-issued observation metadata and is not part of that correlation.
    """

    contract_version: str
    component: str
    installation_identity: str | None
    state: str
    selected_runtime_identity: str | None
    selected_executable_identity: str | None
    selected_server_identity: str | None
    selected_instance_identity: str | None
    artifact: ArtifactCorrelation | None
    artifact_channel: str | None
    health_state: str
    inventory_coverage: str
    conflict_state: str
    inventory_scope: Mapping[str, object]
    single_operational_installation_verified: bool
    evidence: Mapping[str, object]

    def __post_init__(self) -> None:
        _validate_wire_header(self.contract_version, self.component)
        _optional_string(self.installation_identity, "installation_identity")
        if self.state not in _READBACK_STATES:
            raise EPReadbackWireError(f"unsupported installation readback state: {self.state}")
        for label, identity in (
            ("selected_runtime_identity", self.selected_runtime_identity),
            ("selected_executable_identity", self.selected_executable_identity),
            ("selected_server_identity", self.selected_server_identity),
            ("selected_instance_identity", self.selected_instance_identity),
        ):
            _optional_string(identity, label)
        if self.artifact is not None and not isinstance(self.artifact, ArtifactCorrelation):
            raise EPReadbackWireError("artifact must be an artifact correlation")
        _optional_string(self.artifact_channel, "artifact_channel")
        if (self.artifact is None) != (self.artifact_channel is None):
            raise EPReadbackWireError("artifact and artifact_channel must be present together")
        if self.health_state not in _HEALTH_STATES:
            raise EPReadbackWireError(f"unsupported installation health state: {self.health_state}")
        if self.inventory_coverage not in _INVENTORY_COVERAGE_STATES:
            raise EPReadbackWireError(f"unsupported inventory coverage: {self.inventory_coverage}")
        if self.conflict_state not in _CONFLICT_STATES:
            raise EPReadbackWireError(f"unsupported conflict state: {self.conflict_state}")
        if not isinstance(self.single_operational_installation_verified, bool):
            raise EPReadbackWireError("single_operational_installation_verified must be a boolean")
        object.__setattr__(self, "inventory_scope", _copy_mapping(self.inventory_scope, "inventory_scope"))
        object.__setattr__(self, "evidence", _copy_mapping(self.evidence, "evidence"))

        selected = (
            self.selected_runtime_identity,
            self.selected_executable_identity,
            self.selected_server_identity,
            self.selected_instance_identity,
        )
        if self.state == "ACTIVE":
            _require_string(self.installation_identity, "active installation_identity")
            if self.health_state != "HEALTHY":
                raise EPReadbackWireError("active readback must have healthy state")
            if self.artifact is None or any(identity is None for identity in selected):
                raise EPReadbackWireError("active readback requires selected identities and artifact correlation")
        elif self.state == "UNHEALTHY":
            _require_string(self.installation_identity, "unhealthy installation_identity")
            if self.health_state != "UNHEALTHY":
                raise EPReadbackWireError("unhealthy readback must have unhealthy state")
            if (
                self.artifact is None
                or self.selected_runtime_identity is None
                or self.selected_executable_identity is None
                or self.selected_instance_identity is None
            ):
                raise EPReadbackWireError("unhealthy readback requires selected runtime, executable, instance, and artifact correlation")
        elif self.state == "ABSENT":
            _require_string(self.installation_identity, "absent installation_identity")
            if any(identity is not None for identity in selected) or self.artifact is not None:
                raise EPReadbackWireError("absent readback cannot select a runtime or artifact")
            if self.health_state != "UNKNOWN":
                raise EPReadbackWireError("absent readback must have unknown health")
        else:  # UNKNOWN
            if self.installation_identity is not None:
                raise EPReadbackWireError("unknown readback must be anonymous")
            if any(identity is not None for identity in selected) or self.artifact is not None:
                raise EPReadbackWireError("unknown readback cannot select a runtime or artifact")
            if self.health_state != "UNKNOWN":
                raise EPReadbackWireError("unknown readback must have unknown health")

        if self.single_operational_installation_verified and not self._machine_wide_no_conflict():
            raise EPReadbackWireError("single operational installation claim lacks healthy machine-wide no-conflict evidence")

    @property
    def installation_actionable(self) -> bool:
        """Whether this observation names a healthy EP-selected installation.

        This says nothing about authorizing an installation mutation. In
        particular, an anonymous ``UNKNOWN`` payload is retained for diagnosis
        but can never identify an operation target.
        """
        return (
            self.state == "ACTIVE"
            and self.health_state == "HEALTHY"
            and self.installation_identity is not None
        )

    def _machine_wide_no_conflict(self) -> bool:
        """Validate a product-issued uniqueness claim without manufacturing one."""
        return (
            self.state == "ACTIVE"
            and self.health_state == "HEALTHY"
            and self.inventory_coverage == "MACHINE_WIDE"
            and self.conflict_state == "NONE"
        )


@dataclass(frozen=True)
class EPUpdateAssessment:
    """One strictly decoded EP operational-update-assess payload."""

    contract_version: str
    component: str
    installation_identity: str | None
    candidate: ArtifactCorrelation
    state: str
    evidence: Mapping[str, object]

    def __post_init__(self) -> None:
        _validate_wire_header(self.contract_version, self.component)
        _optional_string(self.installation_identity, "installation_identity")
        if not isinstance(self.candidate, ArtifactCorrelation):
            raise EPReadbackWireError("candidate must be an artifact correlation")
        if self.state not in _UPDATE_STATES:
            raise EPReadbackWireError(f"unsupported update assessment state: {self.state}")
        if self.state != "UNKNOWN" and self.installation_identity is None:
            raise EPReadbackWireError("non-unknown update assessment requires an installation identity")
        object.__setattr__(self, "evidence", _copy_mapping(self.evidence, "evidence"))

    @property
    def update_actionable(self) -> bool:
        """Whether EP found this exact candidate available for an identified target."""
        return self.state == "UPDATE_AVAILABLE" and self.installation_identity is not None


def _validate_request(request: ComponentOperationRequest) -> None:
    """Bind only the EP OI-3 V1 request subset that the wire can prove.

    OI-3 has an exact-candidate update assessment only. It has no product
    request-extension input, so accepting even a harmless-looking extension
    would make an unbound caller selection appear product-approved.
    """
    if not isinstance(request, ComponentOperationRequest):
        raise EPReadbackWireError("EP OI-3 decoder requires a component operation request")
    if request.component != EP_SERVER_COMPONENT:
        raise EPReadbackWireError("EP OI-3 decoder only supports engineering-platform-server")
    if request.requested_role != EP_SERVER_ROLE:
        raise EPReadbackWireError("EP OI-3 decoder only supports the server role")
    if request.kind not in EP_OI3_SUPPORTED_KINDS:
        raise EPReadbackWireError("EP OI-3 decoder only supports update assessments")
    if request.product_request:
        raise EPReadbackWireError("EP OI-3 decoder does not support a product request extension")


def validate_readback_for_request(
    observation: EPInstallationReadback,
    request: ComponentOperationRequest,
) -> EPInstallationReadback:
    """Ensure a decoded observation cannot silently retarget an FP request.

    A legitimate anonymous ``UNKNOWN`` response remains a non-actionable
    diagnostic. A response that does name an installation must name the exact
    opaque identity in the coordinator request.
    """
    if not isinstance(observation, EPInstallationReadback):
        raise EPReadbackWireError("observation must be an EP installation readback")
    _validate_request(request)
    if (
        observation.installation_identity is not None
        and observation.installation_identity != request.installation_identity
    ):
        raise EPReadbackWireError("EP installation readback does not match the requested installation identity")
    return observation


def validate_assessment_for_request(
    assessment: EPUpdateAssessment,
    request: ComponentOperationRequest,
) -> EPUpdateAssessment:
    """Bind an EP candidate decision to the exact requested target and triple."""
    if not isinstance(assessment, EPUpdateAssessment):
        raise EPReadbackWireError("assessment must be an EP update assessment")
    _validate_request(request)
    if (
        assessment.installation_identity is not None
        and assessment.installation_identity != request.installation_identity
    ):
        raise EPReadbackWireError("EP update assessment does not match the requested installation identity")
    if assessment.candidate != request.artifact.correlation:
        raise EPReadbackWireError("EP update assessment does not match the requested artifact correlation")
    return assessment


def decode_installation_readback(
    payload: object,
    *,
    request: ComponentOperationRequest | None = None,
) -> EPInstallationReadback:
    """Decode one supplied ``operational-readback`` payload without I/O.

    Passing ``request`` only verifies correlation with an already-created FP
    request; it never supplies defaults, a runtime path, or a replacement
    installation identity.
    """
    wire = _exact_fields(payload, _READBACK_FIELDS, "EP installation readback")
    contract_version, component = _validate_wire_header(wire["contract_version"], wire["component"])
    artifact, channel = _observed_artifact(wire["artifact"])
    observation = EPInstallationReadback(
        contract_version=contract_version,
        component=component,
        installation_identity=_optional_string(wire["installation_identity"], "installation_identity"),
        state=_require_string(wire["state"], "state"),
        selected_runtime_identity=_optional_string(wire["selected_runtime_identity"], "selected_runtime_identity"),
        selected_executable_identity=_optional_string(wire["selected_executable_identity"], "selected_executable_identity"),
        selected_server_identity=_optional_string(wire["selected_server_identity"], "selected_server_identity"),
        selected_instance_identity=_optional_string(wire["selected_instance_identity"], "selected_instance_identity"),
        artifact=artifact,
        artifact_channel=channel,
        health_state=_require_string(wire["health_state"], "health_state"),
        inventory_coverage=_require_string(wire["inventory_coverage"], "inventory_coverage"),
        conflict_state=_require_string(wire["conflict_state"], "conflict_state"),
        inventory_scope=_copy_mapping(wire["inventory_scope"], "inventory_scope"),
        single_operational_installation_verified=wire["single_operational_installation_verified"],
        evidence=_copy_mapping(wire["evidence"], "evidence"),
    )
    return observation if request is None else validate_readback_for_request(observation, request)


def decode_update_assessment(
    payload: object,
    *,
    request: ComponentOperationRequest | None = None,
) -> EPUpdateAssessment:
    """Decode one supplied ``operational-update-assess`` payload without I/O."""
    wire = _exact_fields(payload, _ASSESSMENT_FIELDS, "EP update assessment")
    contract_version, component = _validate_wire_header(wire["contract_version"], wire["component"])
    assessment = EPUpdateAssessment(
        contract_version=contract_version,
        component=component,
        installation_identity=_optional_string(wire["installation_identity"], "installation_identity"),
        candidate=_candidate_correlation(wire["candidate"], "candidate"),
        state=_require_string(wire["state"], "state"),
        evidence=_copy_mapping(wire["evidence"], "evidence"),
    )
    return assessment if request is None else validate_assessment_for_request(assessment, request)
