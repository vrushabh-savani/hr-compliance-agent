package com.vrushabh.hrcompliance.model;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.LocalDate;

public record Action(
        String actionType,
        LocalDate deadline,
        int deadlineRuleDays,
        String sourceClause,
        String sourceDocument,
        double confidence) {

    /** Only safe on a node that has already passed schema validation. */
    public static Action from(JsonNode node) {
        return new Action(
                node.get("actionType").asText(),
                LocalDate.parse(node.get("deadline").asText()),
                node.get("deadlineRuleDays").asInt(),
                node.get("sourceClause").asText(),
                node.get("sourceDocument").asText(),
                node.get("confidence").asDouble());
    }
}
