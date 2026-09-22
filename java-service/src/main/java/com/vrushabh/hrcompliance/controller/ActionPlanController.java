package com.vrushabh.hrcompliance.controller;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.vrushabh.hrcompliance.model.ActionPlan;
import com.vrushabh.hrcompliance.model.Receipt;
import com.vrushabh.hrcompliance.model.Rejection;
import com.vrushabh.hrcompliance.service.ActionExecutor;
import com.vrushabh.hrcompliance.service.ActionPlanValidator;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/action-plans")
public class ActionPlanController {

    private final ActionPlanValidator validator;
    private final ActionExecutor executor;

    public ActionPlanController(ActionPlanValidator validator, ActionExecutor executor) {
        this.validator = validator;
        this.executor = executor;
    }

    @PostMapping
    public ResponseEntity<Object> submit(@RequestBody String body) {
        JsonNode plan;
        try {
            plan = validator.parse(body);
        } catch (JsonProcessingException e) {
            return ResponseEntity.badRequest().body(
                    new Rejection("unknown", false, List.of("malformed JSON: " + e.getOriginalMessage())));
        }

        String eventId = plan.path("eventId").asText("unknown");

        List<String> errors = validator.validate(plan);
        if (!errors.isEmpty()) {
            return ResponseEntity.badRequest().body(new Rejection(eventId, false, errors));
        }

        Receipt receipt = executor.execute(ActionPlan.from(plan));
        return ResponseEntity.status(HttpStatus.CREATED).body(receipt);
    }

    @GetMapping
    public List<Receipt> history() {
        return executor.history();
    }
}
