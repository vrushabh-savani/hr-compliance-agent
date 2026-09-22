package com.vrushabh.hrcompliance.model;

import java.util.List;

public record Rejection(
        String eventId,
        boolean valid,
        List<String> errors) {
}
