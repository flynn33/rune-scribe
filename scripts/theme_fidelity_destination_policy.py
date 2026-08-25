#!/usr/bin/env python3
"""Fixed Simulator destination policy for Theme fidelity evidence."""

from __future__ import annotations

from typing import Any


SELECTION_POLICY = "theme-fidelity-simulator-destination-v1"

DESTINATION_TARGETS = {
    "iphone": {
        "targetModelName": "iPhone 17 Pro",
        "targetModelClass": "iphone-17-pro",
    },
    "ipad": {
        "targetModelName": "iPad Pro 13-inch",
        "targetModelClass": "ipad-pro-13-inch",
    },
}


def _policy(
    role: str,
    model_name: str,
    model_class: str,
    width: int,
    height: int,
    scale: int,
    substitution: bool,
    preference_rank: int,
) -> dict[str, Any]:
    return {
        "role": role,
        "expectedModelName": model_name,
        "selectedModelClass": model_class,
        "expectedPixelDimensions": {"width": width, "height": height},
        "expectedScale": scale,
        "substitution": {
            "used": substitution,
            "reason": "target-model-class-not-booted" if substitution else None,
            "preferenceRank": preference_rank,
        },
    }


DEVICE_TYPE_POLICIES = {
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro": _policy(
        "iphone", "iPhone 17 Pro", "iphone-17-pro", 1206, 2622, 3, False, 0
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro": _policy(
        "iphone", "iPhone 16 Pro", "iphone-pro-substitute", 1206, 2622, 3, True, 100
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro": _policy(
        "iphone", "iPhone 15 Pro", "iphone-pro-substitute", 1179, 2556, 3, True, 110
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro": _policy(
        "iphone", "iPhone 14 Pro", "iphone-pro-substitute", 1179, 2556, 3, True, 120
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro": _policy(
        "iphone", "iPhone 13 Pro", "iphone-pro-substitute", 1170, 2532, 3, True, 130
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPhone-12-Pro": _policy(
        "iphone", "iPhone 12 Pro", "iphone-pro-substitute", 1170, 2532, 3, True, 140
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro": _policy(
        "iphone", "iPhone 11 Pro", "iphone-pro-substitute", 1125, 2436, 3, True, 150
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB": _policy(
        "ipad", "iPad Pro 13-inch (M5)", "ipad-pro-13-inch", 2064, 2752, 2, False, 0
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB": _policy(
        "ipad", "iPad Pro 13-inch (M5) (16GB)", "ipad-pro-13-inch", 2064, 2752, 2, False, 1
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB": _policy(
        "ipad", "iPad Pro 13-inch (M4)", "ipad-pro-13-inch", 2064, 2752, 2, False, 2
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB": _policy(
        "ipad", "iPad Pro 13-inch (M4) (16GB)", "ipad-pro-13-inch", 2064, 2752, 2, False, 3
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-8GB": _policy(
        "ipad", "iPad Pro (12.9-inch) (6th generation)", "ipad-pro-12.9-inch-substitute", 2048, 2732, 2, True, 100
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-16GB": _policy(
        "ipad", "iPad Pro (12.9-inch) (6th generation) (16GB)", "ipad-pro-12.9-inch-substitute", 2048, 2732, 2, True, 101
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-5th-generation": _policy(
        "ipad", "iPad Pro (12.9-inch) (5th generation)", "ipad-pro-12.9-inch-substitute", 2048, 2732, 2, True, 110
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro--12-9-inch---4th-generation-": _policy(
        "ipad", "iPad Pro (12.9-inch) (4th generation)", "ipad-pro-12.9-inch-substitute", 2048, 2732, 2, True, 120
    ),
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro--12-9-inch---3rd-generation-": _policy(
        "ipad", "iPad Pro (12.9-inch) (3rd generation)", "ipad-pro-12.9-inch-substitute", 2048, 2732, 2, True, 130
    ),
}


class DestinationPolicyError(ValueError):
    pass


def policy_for_device_type(identifier: str, role: str | None = None) -> dict[str, Any]:
    policy = DEVICE_TYPE_POLICIES.get(identifier)
    if policy is None or (role is not None and policy["role"] != role):
        destination = role or "Theme fidelity"
        raise DestinationPolicyError(
            f"{destination} Simulator device type is not an approved target or substitute: {identifier}"
        )
    return policy


def build_selection(
    role: str,
    device: dict[str, Any],
    device_type: dict[str, Any],
) -> dict[str, Any]:
    identifier = str(device.get("deviceTypeIdentifier", ""))
    policy = policy_for_device_type(identifier, role)
    target = DESTINATION_TARGETS[role]
    if device_type.get("identifier") != identifier:
        raise DestinationPolicyError(f"{role} Simulator lacks exact device-type catalog provenance")
    if device_type.get("name") != policy["expectedModelName"]:
        raise DestinationPolicyError(
            f"{role} Simulator model catalog name {device_type.get('name')!r} differs from "
            f"policy {policy['expectedModelName']!r}"
        )
    dimensions = device_type.get("pixelDimensions")
    scale = device_type.get("scale")
    if dimensions != policy["expectedPixelDimensions"] or scale != policy["expectedScale"]:
        raise DestinationPolicyError(
            f"{role} Simulator device profile dimensions/scale differ from the fixed destination policy"
        )
    udid = device.get("udid")
    simulator_name = device.get("name")
    if not isinstance(udid, str) or not udid or not isinstance(simulator_name, str) or not simulator_name:
        raise DestinationPolicyError(f"{role} Simulator identity is incomplete")
    return {
        "selectionPolicy": SELECTION_POLICY,
        "role": role,
        "udid": udid,
        "simulatorName": simulator_name,
        "deviceTypeIdentifier": identifier,
        **target,
        "expectedModelName": policy["expectedModelName"],
        "selectedModelClass": policy["selectedModelClass"],
        "expectedPixelDimensions": dict(policy["expectedPixelDimensions"]),
        "expectedScale": policy["expectedScale"],
        "substitution": dict(policy["substitution"]),
    }


def validate_selection(
    selection: Any,
    role: str,
    expected_device_id: str | None = None,
    expected_model_name: str | None = None,
) -> dict[str, Any]:
    required_keys = {
        "selectionPolicy",
        "role",
        "udid",
        "simulatorName",
        "deviceTypeIdentifier",
        "targetModelName",
        "targetModelClass",
        "expectedModelName",
        "selectedModelClass",
        "expectedPixelDimensions",
        "expectedScale",
        "substitution",
    }
    if not isinstance(selection, dict) or set(selection) != required_keys:
        raise DestinationPolicyError(f"{role} Simulator selection schema is invalid")
    if selection["selectionPolicy"] != SELECTION_POLICY or selection["role"] != role:
        raise DestinationPolicyError(f"{role} Simulator selection policy/role is invalid")
    target = DESTINATION_TARGETS[role]
    if any(selection.get(key) != value for key, value in target.items()):
        raise DestinationPolicyError(f"{role} Simulator target model class is invalid")
    identifier = selection.get("deviceTypeIdentifier")
    if not isinstance(identifier, str):
        raise DestinationPolicyError(f"{role} Simulator device type is invalid")
    policy = policy_for_device_type(identifier, role)
    exact_policy = {
        "expectedModelName": policy["expectedModelName"],
        "selectedModelClass": policy["selectedModelClass"],
        "expectedPixelDimensions": policy["expectedPixelDimensions"],
        "expectedScale": policy["expectedScale"],
        "substitution": policy["substitution"],
    }
    if any(selection.get(key) != value for key, value in exact_policy.items()):
        raise DestinationPolicyError(f"{role} Simulator selected model provenance is invalid")
    for key in ("udid", "simulatorName"):
        if not isinstance(selection.get(key), str) or not selection[key]:
            raise DestinationPolicyError(f"{role} Simulator selection {key} is invalid")
    if expected_device_id is not None and selection["udid"] != expected_device_id:
        raise DestinationPolicyError(f"{role} Simulator selection device ID differs from expected")
    if expected_model_name is not None and selection["expectedModelName"] != expected_model_name:
        raise DestinationPolicyError(f"{role} Simulator selection model name differs from expected")
    return selection
