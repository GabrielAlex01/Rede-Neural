from __future__ import annotations

from typing import Any


ACTION_NAMES = ("IDLE", "CHASE", "ATTACK", "FLEE")
FALLBACK_REASONS = ("backend_offline", "waiting_for_mysql")
COUNTERS = (
    "opportunities",
    "sql_decisions",
    "invalid_sql_responses",
    "sent_to_engine",
    "applied",
    "rejected",
    "fallback",
)
MAX_COUNTER = 9_007_199_254_740_991


class InvalidActionMetrics(ValueError):
    """A snapshot is malformed or would make session counters go backwards."""


def _counter(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= MAX_COUNTER:
        raise InvalidActionMetrics("contador de ações inválido")
    return value


def validate_action_metrics(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {*COUNTERS, "actions", "fallback_reasons"}:
        raise InvalidActionMetrics("formato de métricas de ações inválido")

    metrics = {name: _counter(value[name]) for name in COUNTERS}
    actions = value["actions"]
    reasons = value["fallback_reasons"]
    if not isinstance(actions, dict) or set(actions) != set(ACTION_NAMES):
        raise InvalidActionMetrics("contagem por ação inválida")
    if not isinstance(reasons, dict) or set(reasons) != set(FALLBACK_REASONS):
        raise InvalidActionMetrics("contagem de fallback inválida")

    metrics["actions"] = {}
    for action in ACTION_NAMES:
        action_metrics = actions[action]
        if not isinstance(action_metrics, dict) or set(action_metrics) != {
            "selected", "sent_to_engine", "applied", "rejected"
        }:
            raise InvalidActionMetrics("métricas por ação inválidas")
        metrics["actions"][action] = {
            name: _counter(action_metrics[name])
            for name in ("selected", "sent_to_engine", "applied", "rejected")
        }

    metrics["fallback_reasons"] = {
        reason: _counter(reasons[reason]) for reason in FALLBACK_REASONS
    }

    if sum(item["selected"] for item in metrics["actions"].values()) != metrics["sql_decisions"]:
        raise InvalidActionMetrics("decisões SQL não correspondem às ações selecionadas")
    if sum(item["sent_to_engine"] for item in metrics["actions"].values()) != metrics["sent_to_engine"]:
        raise InvalidActionMetrics("ações entregues não correspondem ao total")
    if sum(item["applied"] for item in metrics["actions"].values()) != metrics["applied"]:
        raise InvalidActionMetrics("ações aplicadas não correspondem ao total")
    if sum(item["rejected"] for item in metrics["actions"].values()) != metrics["rejected"]:
        raise InvalidActionMetrics("ações rejeitadas não correspondem ao total")
    if sum(metrics["fallback_reasons"].values()) != metrics["fallback"]:
        raise InvalidActionMetrics("motivos de fallback não correspondem ao total")
    if metrics["applied"] + metrics["rejected"] > metrics["sent_to_engine"]:
        raise InvalidActionMetrics("mais resultados que ações entregues ao engine")
    if metrics["sent_to_engine"] + metrics["fallback"] > metrics["opportunities"]:
        raise InvalidActionMetrics("mais resultados que oportunidades de decisão")

    return metrics


def _counter_values(metrics: dict[str, Any]) -> list[int]:
    values = [metrics[name] for name in COUNTERS]
    for action in ACTION_NAMES:
        values.extend(metrics["actions"][action].values())
    values.extend(metrics["fallback_reasons"].values())
    return values


def is_monotonic_snapshot(current: dict[str, Any], previous: dict[str, Any] | None) -> bool:
    if previous is None:
        return True
    return all(new_value >= old_value for new_value, old_value in zip(
        _counter_values(current), _counter_values(previous), strict=True
    ))


def format_action_metrics(metrics: dict[str, Any]) -> str:
    unresolved = max(0, metrics["sent_to_engine"] - metrics["applied"] - metrics["rejected"])
    per_action = ", ".join(
        f"{action}[SQL={metrics['actions'][action]['selected']}, "
        f"engine={metrics['actions'][action]['sent_to_engine']}, "
        f"aplicada={metrics['actions'][action]['applied']}, "
        f"rejeitada={metrics['actions'][action]['rejected']}]"
        for action in ACTION_NAMES
    )
    return (
        f"SQL={metrics['sql_decisions']} enviados={metrics['sent_to_engine']} "
        f"aplicados={metrics['applied']} rejeitados={metrics['rejected']} "
        f"fallback_original_ai={metrics['fallback']} sem_retorno={unresolved}; "
        f"por_acao: {per_action}"
    )
