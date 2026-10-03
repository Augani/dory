#!/usr/bin/env python3
"""Independently bind a Dory window capture to one accelerated renderer frame."""

from __future__ import annotations

from typing import Any


class TraceChainError(ValueError):
    pass


IDENTITY_FIELDS = (
    "resourceID", "displayResourceGeneration", "rendererResourceGeneration",
    "deviceGeneration", "frameSequence",
)
SURFACE_FIELDS = ("width", "height", "stride", "format")


def positive(value: Any) -> bool:
    return type(value) is int and value > 0


def verify(events: list[dict[str, Any]], capture: dict[str, Any]) -> dict[str, int]:
    if capture.get("transport") not in ("sharedMemory", "sharedTexture"):
        raise TraceChainError("capture transport is not an accelerated renderer lease")
    machine = capture.get("machineID")
    operation = capture.get("operationID")
    display_generation = capture.get("displayResourceGeneration")
    completion_id = capture.get("metalCommandBufferCompletionID")
    if not isinstance(machine, str) or not machine or not isinstance(operation, str) \
            or not operation or not positive(display_generation) or not positive(completion_id):
        raise TraceChainError("capture lacks its machine/operation/frame identity")

    # A completion ID identifies one app Metal command buffer within this operation. Looking
    # only at the claimed display generation would let two frames reuse that ID and select the
    # convenient one for an otherwise self-consistent capture receipt.
    completions = [event for event in events
                   if event.get("stage") == "metalPresentationCompleted"
                   and isinstance(event.get("context"), dict)
                   and event["context"].get("machineID") == machine
                   and event["context"].get("operationID") == operation
                   and event.get("scanoutID") == 0
                   and event.get("metalCommandBufferCompletionID") == completion_id]
    if len(completions) != 1:
        raise TraceChainError("trace must contain exactly one matching Metal completion")
    completed = completions[0]
    if completed.get("displayResourceGeneration") != display_generation:
        raise TraceChainError("Metal completion has the wrong display generation")
    context = completed["context"]
    if not positive(context.get("workerGeneration")):
        raise TraceChainError("Metal completion lacks worker generation")
    if any(not positive(completed.get(field)) for field in IDENTITY_FIELDS):
        raise TraceChainError("Metal completion lacks renderer resource/frame identity")
    if any(not positive(completed.get(field)) for field in SURFACE_FIELDS):
        raise TraceChainError("Metal completion lacks surface identity")

    def same_frame(event: dict[str, Any], stage: str) -> bool:
        event_context = event.get("context")
        return (event.get("stage") == stage and isinstance(event_context, dict)
                and event_context == context
                and all(event.get(field) == completed[field] for field in IDENTITY_FIELDS)
                and all(event.get(field) == completed[field] for field in SURFACE_FIELDS)
                and event.get("contextID") == completed.get("contextID")
                and event.get("fenceID") == completed.get("fenceID")
                and (event.get("scanoutID") == 0 if stage in (
                    "hostSubmissionAccepted", "hostSubmissionRejected")
                     else event.get("scanoutID") in (None, 0)))

    accepted = [event for event in events if same_frame(event, "hostSubmissionAccepted")]
    rejected = [event for event in events if same_frame(event, "hostSubmissionRejected")]
    published = [event for event in events if same_frame(event, "scanoutPublished")]
    if len(accepted) != 1 or len(published) != 1 or rejected:
        raise TraceChainError("accelerated frame lacks one matching scanout and host submission")
    published_event, accepted_event = published[0], accepted[0]
    for event in (published_event, accepted_event, completed):
        if not positive(event.get("sequence")) or not positive(event.get("monotonicNanoseconds")):
            raise TraceChainError("accelerated trace event lacks ordered timing identity")
    if not (published_event["sequence"] < accepted_event["sequence"]
            < completed["sequence"]
            and published_event["monotonicNanoseconds"]
            <= accepted_event["monotonicNanoseconds"]
            <= completed["monotonicNanoseconds"]):
        raise TraceChainError("accelerated scanout/submission/completion order is invalid")
    return {
        "workerGeneration": context["workerGeneration"],
        "resourceID": completed["resourceID"],
        "rendererResourceGeneration": completed["rendererResourceGeneration"],
        "deviceGeneration": completed["deviceGeneration"],
        "graphicsFrameSequence": completed["frameSequence"],
        "graphicsSurfaceWidth": completed["width"],
        "graphicsSurfaceHeight": completed["height"],
        "scanoutPublishedTraceSequence": published_event["sequence"],
        "hostSubmissionTraceSequence": accepted_event["sequence"],
        "graphicsTraceSequence": completed["sequence"],
    }
