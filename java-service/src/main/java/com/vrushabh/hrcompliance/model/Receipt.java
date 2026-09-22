package com.vrushabh.hrcompliance.model;

import java.time.Instant;
import java.util.List;

public record Receipt(
        String eventId,
        String receiptId,
        Instant receivedAt,
        int executed,
        int needsReview,
        List<String> executionLog,
        List<String> reviewQueue) {
}
