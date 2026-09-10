"""Fail-closed selection of published component combinations.

The universal installer is one independently versioned product.  It must not
be rebuilt for every Forge, Workspace and Engineering Platform version tuple.
This module models the small, immutable selection index that a *verified*
catalog feed can bind to an exact SHA-256 payload.  It deliberately does not
download artifacts, verify signatures, choose a product runtime, or dispatch a
product operation.

The signature/transport boundary supplies :class:`CatalogPublicationBinding`
through :meth:`CatalogPublicationBinding.from_verified_composition_catalog`.
That method requires both the current signed installer catalog and its scoped
outer-catalog acceptance after the normal freshness, channel and anti-replay
checks. This module checks the next boundary: exact payload bytes, versioned
selection semantics, component-set equality, explicit upgrade routes, and
installer capability minimums. It therefore remains useful without creating a
second installer or a second product provisioner.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from hashlib import sha256
import json
import re
from typing import Mapping

from .universal_installer import (
    AcceptedCatalogIdentity,
    CatalogAcceptanceScope,
    DownloadIdentity,
    INSTALLER_CHANNELS,
    InstallerCapabilitySet,
    InstallerRequirement,
    SemanticVersion,
    UniversalInstallerError,
    canonical_rfc3339_utc_timestamp,
)
from .composition_identity import require_composition_identity


COMPONENT_COMBINATION_CATALOG_SCHEMA = "forge-platform.component-combination-catalog/v1"
"""The immutable payload schema selected from the signed installer catalog."""

CATALOG_COMPONENT_SELECTION_CAPABILITY = "catalog-component-set/v1"
"""Capability an installer must advertise before it can use this index."""

_COMPONENT_ID = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
MAXIMUM_COMPONENT_COMBINATION_CATALOG_BYTES = 512 * 1024
MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NESTING_DEPTH = 64
MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NODES = 16_384
MAXIMUM_COMPONENT_COMBINATION_CATALOG_UINT64 = (1 << 64) - 1


def _required(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is required")
    return value


def _mapping(value: object, expected: frozenset[str], label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != expected:
        raise ValueError(f"{label} fields are invalid")
    return value


def _positive_int(value: object, label: str) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value <= 0
        or value > MAXIMUM_COMPONENT_COMBINATION_CATALOG_UINT64
    ):
        raise ValueError(f"{label} must be a positive UInt64 integer")
    return value


def _strict_json_mapping(raw_bytes: bytes, label: str) -> Mapping[str, object]:
    if not isinstance(raw_bytes, bytes):
        raise ValueError(f"{label} bytes are required")
    if not raw_bytes or len(raw_bytes) > MAXIMUM_COMPONENT_COMBINATION_CATALOG_BYTES:
        raise UniversalInstallerError(f"{label} bytes exceed the native admission limit")

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-finite JSON value is not permitted: {value}")

    def reject_duplicate_pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, item in pairs:
            if not isinstance(key, str) or key in result:
                raise ValueError("catalog JSON has duplicate or invalid object keys")
            result[key] = item
        return result

    try:
        value = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as error:
        raise UniversalInstallerError(f"{label} is not valid strict JSON") from error
    if not isinstance(value, Mapping):
        raise UniversalInstallerError(f"{label} root must be an object")
    _require_bounded_json_structure(value, label=label)
    return value


def _require_bounded_json_structure(value: object, *, label: str) -> None:
    """Mirror the native strict reader's value and container budgets."""

    nodes = 0
    pending: list[tuple[object, int]] = [(value, 0)]
    while pending:
        current, parent_container_depth = pending.pop()
        nodes += 1
        if nodes > MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NODES:
            raise UniversalInstallerError(f"{label} exceeds the native JSON node limit")
        if isinstance(current, Mapping):
            depth = parent_container_depth + 1
            if depth > MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NESTING_DEPTH:
                raise UniversalInstallerError(f"{label} exceeds the native JSON nesting limit")
            pending.extend((child, depth) for child in current.values())
        elif isinstance(current, list):
            depth = parent_container_depth + 1
            if depth > MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NESTING_DEPTH:
                raise UniversalInstallerError(f"{label} exceeds the native JSON nesting limit")
            pending.extend((child, depth) for child in current)


def _capabilities(value: object, label: str, *, required: bool) -> frozenset[str]:
    if not isinstance(value, list) or (required and not value):
        raise ValueError(f"{label} must be a {'non-empty ' if required else ''}list")
    parsed = tuple(_required(item, label) for item in value)
    if len(parsed) != len(set(parsed)):
        raise ValueError(f"{label} must be unique")
    for capability in parsed:
        if _COMPONENT_ID.fullmatch(capability) is None:
            raise ValueError(f"{label} identity is invalid")
    return frozenset(parsed)


def _component_identity(value: object, label: str) -> str:
    identity = _required(value, label)
    if _COMPONENT_ID.fullmatch(identity) is None:
        raise ValueError(f"{label} is invalid")
    return identity


_CATALOG_PUBLICATION_BINDING_MARKER = object()


@dataclass(frozen=True, init=False)
class CatalogPublicationBinding:
    """Exact non-secret catalog identity issued by the upstream trust boundary.

    ``catalog`` must come from the current signed installer-catalog feed, not
    a filename, a mutable GitHub ``latest`` marker, or an arbitrary URL.  The
    cryptographic verification remains deliberately owned by that boundary;
    this type retains the exact scoped outer-catalog acceptance and freshness
    evidence that made the index locator eligible for selection.  A component
    index anchor therefore cannot be replayed across a same-channel trust or
    feed rotation.
    """

    outer_catalog_acceptance: AcceptedCatalogIdentity
    catalog: DownloadIdentity
    outer_published_at: datetime
    outer_expires_at: datetime

    def __init__(
        self,
        outer_catalog_acceptance: AcceptedCatalogIdentity,
        catalog: DownloadIdentity,
        outer_published_at: datetime,
        outer_expires_at: datetime,
        *,
        _marker: object = None,
    ) -> None:
        if _marker is not _CATALOG_PUBLICATION_BINDING_MARKER:
            raise TypeError("CatalogPublicationBinding must be derived from a verified CompositionCatalog")
        object.__setattr__(self, "outer_catalog_acceptance", outer_catalog_acceptance)
        object.__setattr__(self, "catalog", catalog)
        object.__setattr__(self, "outer_published_at", outer_published_at)
        object.__setattr__(self, "outer_expires_at", outer_expires_at)
        self.__post_init__()

    def __post_init__(self) -> None:
        if not isinstance(self.outer_catalog_acceptance, AcceptedCatalogIdentity):
            raise ValueError("published component catalog requires a scoped outer catalog acceptance")
        if not isinstance(self.catalog, DownloadIdentity):
            raise ValueError("published component catalog requires a digest-pinned identity")
        if (
            not isinstance(self.outer_published_at, datetime)
            or self.outer_published_at.tzinfo is None
            or not isinstance(self.outer_expires_at, datetime)
            or self.outer_expires_at.tzinfo is None
            or self.outer_expires_at <= self.outer_published_at
        ):
            raise ValueError("published component catalog requires valid outer catalog freshness evidence")

    @property
    def scope(self) -> CatalogAcceptanceScope:
        """Exact trust/channel/feed scope inherited from the outer catalog."""

        return self.outer_catalog_acceptance.scope

    @property
    def channel(self) -> str:
        """Compatibility projection; scope remains the authoritative identity."""

        return self.scope.channel

    @classmethod
    def from_verified_composition_catalog(
        cls,
        catalog: object,
        *,
        outer_catalog_acceptance: AcceptedCatalogIdentity,
    ) -> "CatalogPublicationBinding":
        """Derive the index binding only from a verified signed outer catalog.

        The production path cannot turn a filename, a mutable release URL, or
        an independently assembled digest into this binding.  The outer
        :class:`~forge_platform.universal_installer.CompositionCatalog` is
        constructed only by its signed-metadata parser and carries the locator
        inside the signed canonical payload.  Its acceptance must additionally
        be the scoped identity issued by the verified outer-catalog boundary.
        """

        from .universal_installer import CompositionCatalog

        if not isinstance(catalog, CompositionCatalog):
            raise ValueError("a verified CompositionCatalog is required for a component catalog binding")
        if not isinstance(catalog.component_combination_catalog, DownloadIdentity):
            raise UniversalInstallerError(
                "verified composition catalog does not declare a component-combination catalog locator"
            )
        if not isinstance(outer_catalog_acceptance, AcceptedCatalogIdentity):
            raise ValueError("a scoped accepted outer CompositionCatalog identity is required")
        if (
            outer_catalog_acceptance.scope.channel != catalog.channel
            or outer_catalog_acceptance.sequence != catalog.sequence
            or outer_catalog_acceptance.catalog_digest != catalog.catalog_digest
        ):
            raise UniversalInstallerError(
                "verified composition catalog does not match its scoped accepted outer provenance"
            )
        return cls(
            outer_catalog_acceptance,
            catalog.component_combination_catalog,
            catalog.published_at,
            catalog.expires_at,
            _marker=_CATALOG_PUBLICATION_BINDING_MARKER,
        )


@dataclass(frozen=True)
class ComponentCapabilityRequirement:
    """Capabilities that make one component type safe for this installer."""

    identity: str
    installer_capabilities: frozenset[str]

    def __post_init__(self) -> None:
        _component_identity(self.identity, "component identity")
        if not isinstance(self.installer_capabilities, frozenset) or not self.installer_capabilities:
            raise ValueError("component installer capabilities are required")
        for capability in self.installer_capabilities:
            if not isinstance(capability, str) or _COMPONENT_ID.fullmatch(capability) is None:
                raise ValueError("component installer capability identity is invalid")

    @classmethod
    def from_mapping(cls, value: object) -> "ComponentCapabilityRequirement":
        payload = _mapping(
            value,
            frozenset({"identity", "requires_capabilities"}),
            "catalog component",
        )
        return cls(
            _component_identity(payload["identity"], "catalog component identity"),
            _capabilities(payload["requires_capabilities"], "catalog component requires_capabilities", required=True),
        )


@dataclass(frozen=True)
class ComponentCombinationCatalogEntry:
    """One immutable, exact component combination offered by the catalog.

    ``selection_sequence`` is deliberately a numeric catalog decision, not a
    wheel timestamp, filename comparison, or product-version ordering.  A
    composition itself remains bound by its manifest digest and independently
    owned product artifact evidence.
    """

    composition_id: str
    selection_sequence: int
    channel: str
    manifest: DownloadIdentity
    components: tuple[ComponentCapabilityRequirement, ...]
    installer_requirement: InstallerRequirement
    upgrade_from: tuple[str, ...]

    def __post_init__(self) -> None:
        require_composition_identity(self.composition_id, "catalog composition_id")
        _positive_int(self.selection_sequence, "catalog selection_sequence")
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("catalog composition channel is unsupported")
        if not isinstance(self.manifest, DownloadIdentity):
            raise ValueError("catalog composition requires a digest-pinned manifest")
        if not isinstance(self.components, tuple) or not self.components:
            raise ValueError("catalog composition requires components")
        if any(not isinstance(component, ComponentCapabilityRequirement) for component in self.components):
            raise ValueError("catalog composition components are invalid")
        component_ids = tuple(component.identity for component in self.components)
        if len(component_ids) != len(set(component_ids)):
            raise ValueError("catalog composition component identities must be unique")
        if not isinstance(self.installer_requirement, InstallerRequirement):
            raise ValueError("catalog composition installer requirement is invalid")
        if CATALOG_COMPONENT_SELECTION_CAPABILITY not in self.installer_requirement.capabilities:
            raise ValueError("catalog composition must require the component-set selection capability")
        required_component_capabilities = frozenset().union(
            *(component.installer_capabilities for component in self.components)
        )
        if not required_component_capabilities <= self.installer_requirement.capabilities:
            raise ValueError("catalog composition component capabilities must be bound by requires_installer")
        if not isinstance(self.upgrade_from, tuple):
            raise ValueError("catalog composition upgrade_from is invalid")
        for identity in self.upgrade_from:
            require_composition_identity(identity, "catalog composition upgrade_from")
        if len(self.upgrade_from) != len(set(self.upgrade_from)):
            raise ValueError("catalog composition upgrade_from must be unique")
        if self.composition_id in self.upgrade_from:
            raise ValueError("catalog composition cannot upgrade from itself")

    @property
    def component_identities(self) -> frozenset[str]:
        return frozenset(component.identity for component in self.components)

    @classmethod
    def from_mapping(cls, value: object) -> "ComponentCombinationCatalogEntry":
        payload = _mapping(
            value,
            frozenset({
                "composition_id", "selection_sequence", "channel", "manifest",
                "components", "requires_installer", "upgrade_from",
            }),
            "component combination catalog entry",
        )
        manifest = _mapping(payload["manifest"], frozenset({"url", "digest"}), "catalog composition manifest")
        installer = _mapping(
            payload["requires_installer"],
            frozenset({"minimum_version", "capabilities"}),
            "catalog composition installer requirement",
        )
        components = payload["components"]
        if not isinstance(components, list):
            raise ValueError("catalog composition components must be a list")
        upgrade_from = payload["upgrade_from"]
        if not isinstance(upgrade_from, list):
            raise ValueError("catalog composition upgrade_from must be a list")
        return cls(
            composition_id=require_composition_identity(payload["composition_id"], "catalog composition_id"),
            selection_sequence=_positive_int(payload["selection_sequence"], "catalog selection_sequence"),
            channel=_required(payload["channel"], "catalog composition channel"),
            manifest=DownloadIdentity(
                _required(manifest["url"], "catalog composition manifest URL"),
                _required(manifest["digest"], "catalog composition manifest digest"),
            ),
            components=tuple(ComponentCapabilityRequirement.from_mapping(component) for component in components),
            installer_requirement=InstallerRequirement(
                SemanticVersion.parse(installer["minimum_version"], "catalog minimum installer version"),
                _capabilities(installer["capabilities"], "catalog installer capabilities", required=False),
            ),
            upgrade_from=tuple(
                require_composition_identity(item, "catalog composition upgrade_from")
                for item in upgrade_from
            ),
        )


@dataclass(frozen=True)
class ComponentCombinationCatalog:
    """A versioned, digest-bound index of product-composition choices.

    This is not a bundle per component tuple.  It is a compact, immutable
    catalog payload that points at separately immutable composition manifests.
    A new entry can expose a new combination without changing an installer
    binary, provided its capabilities are already present in that binary.
    """

    sequence: int
    channel: str
    published_at: datetime
    expires_at: datetime
    entries: tuple[ComponentCombinationCatalogEntry, ...]
    catalog_digest: str
    outer_catalog_acceptance: AcceptedCatalogIdentity
    outer_published_at: datetime
    outer_expires_at: datetime

    def __post_init__(self) -> None:
        _positive_int(self.sequence, "component combination catalog sequence")
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("component combination catalog channel is unsupported")
        if self.expires_at <= self.published_at:
            raise ValueError("component combination catalog must expire after publication")
        if not isinstance(self.entries, tuple) or not self.entries:
            raise ValueError("component combination catalog requires entries")
        if any(not isinstance(entry, ComponentCombinationCatalogEntry) for entry in self.entries):
            raise ValueError("component combination catalog entries are invalid")
        if any(entry.channel != self.channel for entry in self.entries):
            raise ValueError("component combination catalog entry channel must match the catalog channel")
        identities = tuple(entry.composition_id for entry in self.entries)
        if len(identities) != len(set(identities)):
            raise ValueError("component combination catalog contains duplicate composition identities")
        revisions = tuple((entry.component_identities, entry.selection_sequence) for entry in self.entries)
        if len(revisions) != len(set(revisions)):
            raise ValueError("component combination catalog has an ambiguous component-set selection sequence")
        if not isinstance(self.catalog_digest, str) or _DIGEST.fullmatch(self.catalog_digest) is None:
            raise ValueError("component combination catalog digest is invalid")
        if not isinstance(self.outer_catalog_acceptance, AcceptedCatalogIdentity):
            raise ValueError("component combination catalog requires scoped outer provenance")
        if self.outer_catalog_acceptance.scope.channel != self.channel:
            raise ValueError("component combination catalog outer provenance channel is invalid")
        if (
            not isinstance(self.outer_published_at, datetime)
            or self.outer_published_at.tzinfo is None
            or not isinstance(self.outer_expires_at, datetime)
            or self.outer_expires_at.tzinfo is None
            or self.outer_expires_at <= self.outer_published_at
        ):
            raise ValueError("component combination catalog outer freshness evidence is invalid")

    @classmethod
    def from_bound_bytes(
        cls,
        binding: CatalogPublicationBinding,
        raw_bytes: bytes,
    ) -> "ComponentCombinationCatalog":
        """Parse only bytes whose digest was bound by the trusted outer feed."""

        if not isinstance(binding, CatalogPublicationBinding):
            raise ValueError("trusted catalog publication binding is required")
        if not isinstance(raw_bytes, bytes):
            raise ValueError("component combination catalog bytes are required")
        actual_digest = "sha256:" + sha256(raw_bytes).hexdigest()
        if actual_digest != binding.catalog.digest:
            raise UniversalInstallerError("component combination catalog bytes do not match the trusted catalog digest")
        payload = _mapping(
            _strict_json_mapping(raw_bytes, "component combination catalog"),
            frozenset({"schema", "sequence", "channel", "published_at", "expires_at", "compositions"}),
            "component combination catalog",
        )
        if payload["schema"] != COMPONENT_COMBINATION_CATALOG_SCHEMA:
            raise UniversalInstallerError("component combination catalog schema is unsupported")
        compositions = payload["compositions"]
        if not isinstance(compositions, list):
            raise ValueError("component combination catalog compositions must be a list")
        catalog = cls(
            sequence=_positive_int(payload["sequence"], "component combination catalog sequence"),
            channel=_required(payload["channel"], "component combination catalog channel"),
            published_at=canonical_rfc3339_utc_timestamp(
                payload["published_at"], "component combination catalog published_at"
            ),
            expires_at=canonical_rfc3339_utc_timestamp(
                payload["expires_at"], "component combination catalog expires_at"
            ),
            entries=tuple(ComponentCombinationCatalogEntry.from_mapping(entry) for entry in compositions),
            catalog_digest=actual_digest,
            outer_catalog_acceptance=binding.outer_catalog_acceptance,
            outer_published_at=binding.outer_published_at,
            outer_expires_at=binding.outer_expires_at,
        )
        if catalog.channel != binding.channel:
            raise UniversalInstallerError("component combination catalog channel does not match its trusted binding")
        return catalog

    @classmethod
    def from_verified_composition_catalog_bytes(
        cls,
        catalog: object,
        raw_bytes: bytes,
        *,
        outer_catalog_acceptance: AcceptedCatalogIdentity,
    ) -> "ComponentCombinationCatalog":
        """Parse the index through the verified signed catalog boundary.

        This is the production-facing convenience path.  It avoids callers
        manually assembling a :class:`CatalogPublicationBinding` and ensures
        the index locator remains part of the signed outer catalog's canonical
        bytes.
        """

        return cls.from_bound_bytes(
            CatalogPublicationBinding.from_verified_composition_catalog(
                catalog,
                outer_catalog_acceptance=outer_catalog_acceptance,
            ),
            raw_bytes,
        )


@dataclass(frozen=True)
class AcceptedComponentCombinationCatalogIdentity:
    """Persisted anti-replay anchor after a verified terminal installation."""

    scope: CatalogAcceptanceScope
    sequence: int
    catalog_digest: str

    def __post_init__(self) -> None:
        if not isinstance(self.scope, CatalogAcceptanceScope):
            raise ValueError("accepted component combination catalog scope is invalid")
        _positive_int(self.sequence, "accepted component combination catalog sequence")
        if not isinstance(self.catalog_digest, str) or _DIGEST.fullmatch(self.catalog_digest) is None:
            raise ValueError("accepted component combination catalog digest is invalid")

    @property
    def channel(self) -> str:
        """Compatibility projection; trust and feed scope remain mandatory."""

        return self.scope.channel


@dataclass(frozen=True)
class CatalogInstallerContext:
    """Current scoped installer capability projection for this selector.

    Production callers construct this from the existing verified self-update
    context.  The scope is the exact release-trust configuration, channel and
    outer-catalog feed identity, so a same-channel trust/feed rotation cannot
    reuse a component-index anchor.  Keeping the projection explicit lets this
    source-level selector remain platform-neutral while ensuring it cannot
    confuse product version strings with installer capability evidence.
    """

    scope: CatalogAcceptanceScope
    capabilities: InstallerCapabilitySet

    def __post_init__(self) -> None:
        if not isinstance(self.scope, CatalogAcceptanceScope):
            raise ValueError("catalog installer context requires a scoped verified catalog identity")
        if not isinstance(self.capabilities, InstallerCapabilitySet):
            raise ValueError("catalog installer context requires installer capabilities")

    @property
    def channel(self) -> str:
        """Compatibility projection; scope remains the authoritative identity."""

        return self.scope.channel

    @classmethod
    def from_verified_installer_context(cls, installer_context: object) -> "CatalogInstallerContext":
        """Derive selector facts only from the verified self-update boundary."""

        from .universal_installer import VerifiedInstallerContext

        if not isinstance(installer_context, VerifiedInstallerContext):
            raise ValueError("verified installer context is required for component catalog selection")
        return cls(
            CatalogAcceptanceScope.from_verified_installer_context(installer_context),
            installer_context.capabilities,
        )


@dataclass(frozen=True)
class ComponentCombinationRequest:
    """An exact desired component set; supersets are never selected silently."""

    component_identities: frozenset[str]
    installed_composition_id: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.component_identities, frozenset) or not self.component_identities:
            raise ValueError("component combination request requires component identities")
        for identity in self.component_identities:
            _component_identity(identity, "requested component identity")
        if self.installed_composition_id is not None:
            require_composition_identity(self.installed_composition_id, "installed composition identity")


@dataclass(frozen=True)
class ComponentCombinationSelection:
    """A non-mutating catalog decision for the native wizard or coordinator."""

    state: str
    reason: str
    catalog_identity: AcceptedComponentCombinationCatalogIdentity
    entry: ComponentCombinationCatalogEntry | None
    unmet_installer_requirements: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.state not in {
            "SELECTED", "INSTALLER_UPDATE_REQUIRED", "UNAVAILABLE", "UPGRADE_ROUTE_BLOCKED",
        }:
            raise ValueError("component combination selection state is unsupported")
        _required(self.reason, "component combination selection reason")
        if not isinstance(self.catalog_identity, AcceptedComponentCombinationCatalogIdentity):
            raise ValueError("component combination selection requires catalog identity")
        if self.state in {"SELECTED", "INSTALLER_UPDATE_REQUIRED"} and not isinstance(
            self.entry, ComponentCombinationCatalogEntry
        ):
            raise ValueError("component combination selection state requires a catalog entry")
        if self.state in {"UNAVAILABLE", "UPGRADE_ROUTE_BLOCKED"} and self.entry is not None:
            raise ValueError("blocked component combination selection cannot retain a catalog entry")
        if self.state == "SELECTED" and self.unmet_installer_requirements:
            raise ValueError("selected component combination cannot have unmet installer requirements")
        if self.state == "INSTALLER_UPDATE_REQUIRED" and not self.unmet_installer_requirements:
            raise ValueError("installer update selection requires unmet installer requirements")

    @property
    def permits_composition_fetch(self) -> bool:
        """Only an exact selected entry may lead to manifest retrieval."""

        return self.state == "SELECTED"


def select_component_combination(
    catalog: ComponentCombinationCatalog,
    installer: CatalogInstallerContext,
    request: ComponentCombinationRequest,
    *,
    now: datetime,
    accepted_catalog: AcceptedComponentCombinationCatalogIdentity | None = None,
) -> ComponentCombinationSelection:
    """Select the newest exact, explicitly routable, capable combination.

    A higher catalog entry that the current installer cannot understand is not
    silently bypassed in favour of an older composition: the only safe outcome
    is ``INSTALLER_UPDATE_REQUIRED``.  Likewise, a component superset is never
    chosen merely because it happens to contain the requested roles.
    """

    if not isinstance(catalog, ComponentCombinationCatalog):
        raise ValueError("component combination catalog is required")
    if not isinstance(installer, CatalogInstallerContext):
        raise ValueError("catalog installer context is required")
    if not isinstance(request, ComponentCombinationRequest):
        raise ValueError("component combination request is required")
    if not isinstance(now, datetime) or now.tzinfo is None:
        raise ValueError("trusted current time is required")
    current_time = now.astimezone(timezone.utc)
    if catalog.outer_catalog_acceptance.scope != installer.scope:
        raise UniversalInstallerError(
            "component combination catalog scope does not match the current verified installer"
        )
    if catalog.channel != installer.channel:
        raise UniversalInstallerError("component combination catalog channel does not match the current installer")
    if (
        catalog.published_at > current_time
        or catalog.expires_at <= current_time
        or catalog.outer_published_at > current_time
        or catalog.outer_expires_at <= current_time
    ):
        raise UniversalInstallerError("component combination catalog is not currently valid")
    if accepted_catalog is not None:
        if not isinstance(accepted_catalog, AcceptedComponentCombinationCatalogIdentity):
            raise ValueError("accepted component combination catalog identity is invalid")
        if accepted_catalog.scope != installer.scope:
            raise UniversalInstallerError(
                "component combination catalog anchor scope does not match the current verified installer"
            )
        if accepted_catalog.channel != catalog.channel:
            raise UniversalInstallerError("component combination catalog channel regresses accepted local provenance")
        if catalog.sequence < accepted_catalog.sequence:
            raise UniversalInstallerError("component combination catalog sequence regresses accepted local provenance")
        if catalog.sequence == accepted_catalog.sequence and catalog.catalog_digest != accepted_catalog.catalog_digest:
            raise UniversalInstallerError("component combination catalog sequence maps to conflicting immutable bytes")
    catalog_identity = AcceptedComponentCombinationCatalogIdentity(
        installer.scope,
        catalog.sequence,
        catalog.catalog_digest,
    )
    matching_set = [
        entry for entry in catalog.entries
        if entry.component_identities == request.component_identities
    ]
    if not matching_set:
        return ComponentCombinationSelection(
            "UNAVAILABLE",
            "no published composition has exactly the requested component set",
            catalog_identity,
            None,
        )
    routable = [
        entry for entry in matching_set
        if request.installed_composition_id is None
        or entry.composition_id == request.installed_composition_id
        or request.installed_composition_id in entry.upgrade_from
    ]
    if not routable:
        return ComponentCombinationSelection(
            "UPGRADE_ROUTE_BLOCKED",
            "no published composition authorizes an upgrade from the installed composition",
            catalog_identity,
            None,
        )
    newest = max(routable, key=lambda entry: entry.selection_sequence)
    unmet = newest.installer_requirement.unmet_by(installer.capabilities)
    if unmet:
        return ComponentCombinationSelection(
            "INSTALLER_UPDATE_REQUIRED",
            "the newest compatible component combination requires a newer installer capability",
            catalog_identity,
            newest,
            unmet,
        )
    return ComponentCombinationSelection(
        "SELECTED",
        "the newest exact component combination is supported by the current installer",
        catalog_identity,
        newest,
    )
