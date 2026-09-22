package com.vrushabh.hrcompliance.model;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;

public record ActionPlan(
        String eventId,
        String eventType,
        LocalDate effectiveDate,
        List<Action> actions) {

    /** Only safe on a node that has already passed schema validation. */
    public static ActionPlan from(JsonNode node) {
        List<Action> actions = new ArrayList<>();
        node.get("actions").forEach(action -> actions.add(Action.from(action)));

        return new ActionPlan(
                node.get("eventId").asText(),
                node.get("eventType").asText(),
                LocalDate.parse(node.get("effectiveDate").asText()),
                List.copyOf(actions));
    }
}
