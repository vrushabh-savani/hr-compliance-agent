package com.vrushabh.hrcompliance.service;

import com.vrushabh.hrcompliance.model.Action;
import com.vrushabh.hrcompliance.model.ActionPlan;
import com.vrushabh.hrcompliance.model.Receipt;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;

@Service
public class ActionExecutor {

    /** Below this, an action is valid but too uncertain to fire without a human looking at it. */
    public static final double CONFIDENCE_THRESHOLD = 0.7;

    private static final Logger log = LoggerFactory.getLogger(ActionExecutor.class);

    private final List<Receipt> receipts = new CopyOnWriteArrayList<>();

    public Receipt execute(ActionPlan plan) {
        List<String> executionLog = new ArrayList<>();
        List<String> reviewQueue = new ArrayList<>();

        for (Action action : plan.actions()) {
            String description = describe(action, plan.eventId());

            if (action.confidence() >= CONFIDENCE_THRESHOLD) {
                log.info("EXECUTE {}", description);
                executionLog.add(description);
            } else {
                String queued = "%s [confidence %.2f below %.2f]"
                        .formatted(description, action.confidence(), CONFIDENCE_THRESHOLD);
                log.warn("REVIEW  {}", queued);
                reviewQueue.add(queued);
            }
        }

        Receipt receipt = new Receipt(
                plan.eventId(),
                "RCP-" + UUID.randomUUID().toString().substring(0, 6),
                Instant.now(),
                executionLog.size(),
                reviewQueue.size(),
                executionLog,
                reviewQueue);

        receipts.add(receipt);

        if (plan.actions().isEmpty()) {
            log.info("No actions for {} — retrieved policy text did not cover the event", plan.eventId());
        }

        return receipt;
    }

    public List<Receipt> history() {
        return List.copyOf(receipts);
    }

    private String describe(Action action, String eventId) {
        String verb = switch (action.actionType()) {
            case "send_continuation_notice" -> "send benefits continuation notice";
            case "end_benefits" -> "end benefits coverage";
            case "issue_final_paycheck" -> "issue final paycheque";
            case "request_asset_return" -> "request return of company assets";
            case "notify_manager" -> "notify the direct manager";
            case "flag_leave_request" -> "flag leave request for HR review";
            case "schedule_return_to_work_check" -> "schedule return-to-work check";
            case "open_benefits_enrollment" -> "open benefits enrolment";
            case "schedule_benefits_review" -> "schedule benefits review";
            default -> throw new IllegalStateException(
                    "Unvalidated actionType reached the executor: " + action.actionType());
        };

        return "Would %s for %s by %s (%s)"
                .formatted(verb, eventId, action.deadline(), action.sourceDocument());
    }
}
