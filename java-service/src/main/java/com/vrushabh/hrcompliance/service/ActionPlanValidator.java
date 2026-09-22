package com.vrushabh.hrcompliance.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.networknt.schema.JsonSchema;
import com.networknt.schema.JsonSchemaFactory;
import com.networknt.schema.SpecVersion;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStream;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;

@Service
public class ActionPlanValidator {

    private final JsonSchema schema;

    // Jackson 2, required by networknt. Spring Boot 4 serializes responses with Jackson 3, so this
    // mapper is deliberately kept inside the validation path and never exposed as a bean.
    private final ObjectMapper json = new ObjectMapper();

    public ActionPlanValidator() throws IOException {
        try (InputStream in = new ClassPathResource("action-plan-schema.json").getInputStream()) {
            this.schema = JsonSchemaFactory
                    .getInstance(SpecVersion.VersionFlag.V202012)
                    .getSchema(in);
        }
    }

    public JsonNode parse(String body) throws JsonProcessingException {
        return json.readTree(body);
    }

    public List<String> validate(JsonNode plan) {
        List<String> errors = new ArrayList<>();

        schema.validate(plan).forEach(m -> errors.add(m.getMessage()));

        // Semantic checks below index into the tree directly, so they are only safe once the
        // structure is known good.
        if (!errors.isEmpty()) {
            return errors;
        }

        LocalDate effectiveDate = parseDate(plan.get("effectiveDate").asText(), "effectiveDate", errors);
        if (effectiveDate == null) {
            return errors;
        }

        JsonNode actions = plan.get("actions");
        for (int i = 0; i < actions.size(); i++) {
            validateAction(actions.get(i), i, effectiveDate, errors);
        }

        return errors;
    }

    private void validateAction(JsonNode action, int index, LocalDate effectiveDate, List<String> errors) {
        String path = "actions[" + index + "]";

        LocalDate deadline = parseDate(action.get("deadline").asText(), path + ".deadline", errors);
        if (deadline == null) {
            return;
        }

        int ruleDays = action.get("deadlineRuleDays").asInt();
        LocalDate expected = effectiveDate.plusDays(ruleDays);

        if (deadline.isBefore(effectiveDate)) {
            errors.add("%s.deadline: %s is before effectiveDate %s (a %d-day rule gives %s)"
                    .formatted(path, deadline, effectiveDate, ruleDays, expected));
        } else if (!deadline.equals(expected)) {
            errors.add("%s.deadline: %s does not equal effectiveDate %s + %d days (expected %s)"
                    .formatted(path, deadline, effectiveDate, ruleDays, expected));
        }
    }

    private LocalDate parseDate(String value, String path, List<String> errors) {
        try {
            return LocalDate.parse(value);
        } catch (DateTimeParseException e) {
            errors.add("%s: '%s' is not a valid calendar date".formatted(path, value));
            return null;
        }
    }
}
